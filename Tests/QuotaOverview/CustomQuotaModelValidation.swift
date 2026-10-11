import Foundation

@main struct CustomQuotaModelValidation {
    static func main() throws {
        var failures = [String]()
        func check(_ value: Bool, _ message: String) {
            if !value { failures.append(message); print("FAIL: \(message)") }
        }
        check((try? CustomQuotaEndpoint.prepare("https://api.example.com/v1/balance"))?.host == "api.example.com",
              "An explicitly supplied HTTPS balance API must be usable without a vendor-specific code change")
        for bad in ["http://api.example.com/balance", "https://name:pass@api.example.com/balance",
                    "https://api.example.com/balance?api_key=private", "https://api.example.com/balance#token",
                    "https://127.0.0.1/balance", "https://[::1]/balance", "https://localhost/balance",
                    "https://api.example.com:8443/balance", "https://api.example.com/v1/chat/completions",
                    "https://api.example.com/account/delete", "file:///private/tmp/balance"] {
            check((try? CustomQuotaEndpoint.prepare(bad)) == nil, "Unsafe or non-quota endpoints cannot receive a Key")
        }
        let payload = try CustomQuotaPayload.decode(Data(#"{"data":{"total":100.5,"used":"25.75","zero":0,"fraction":0.63,"reset":"2026-10-15T02:00:00Z","flags":true,"secret":"not-a-real-token"}}"#.utf8))
        let mapping = CustomQuotaMapping(remainingPath: "/data/total", subtractPath: "/data/used", resetPath: "/data/reset", unit: .usd)
        check(try payload.snapshot(mapping: mapping, at: Date(timeIntervalSince1970: 1000)).amount == Decimal(string: "74.75"),
              "Remaining balance is computed from actual selected response fields, not a typed balance")
        check(payload.fields.count == 5 && payload.numberFields.count == 4,
              "Only bounded numeric/date leaves leave the response; booleans and secrets cannot become quota fields")
        let zero = try payload.snapshot(mapping: .init(remainingPath: "/data/zero", unit: .percent), at: .now)
        check(zero.amount == 0, "A genuine zero is valid and cannot be mistaken for a missing value")
        let ratio = try payload.snapshot(mapping: .init(remainingPath: "/data/fraction", unit: .ratio), at: .now)
        check(ratio.amount == 63, "A user-declared 0-to-1 ratio is displayed as a percent, never as money")
        for text in ["{}", "[]", #"{"error":{"code":401}}"#, #"{"success":false,"balance":50}"#,
                     #"{"balance":null}"#, #"{"balance":"3.2oops"}"#, #"{"balance":true}"#] {
            check((try? CustomQuotaPayload.decode(Data(text.utf8))) == nil,
                  "Errors and absent/malformed fields cannot become a successful balance")
        }
        for mapping in [CustomQuotaMapping(remainingPath: "/data/missing", unit: .usd),
                        .init(remainingPath: "/data/total", unit: .percent),
                        .init(remainingPath: "/data/total", subtractPath: "/data/total", unit: .usd),
                        .init(remainingPath: "/data/total", resetPath: "/data/secret", unit: .usd)] {
            check((try? payload.snapshot(mapping: mapping, at: .now)) == nil,
                  "Missing paths, impossible units, fake-zero subtraction and invented reset clocks are rejected")
        }
        let escaped = try CustomQuotaPayload.decode(Data(#"{"data/balance":{"a~b":"12.40"}}"#.utf8))
        check(try escaped.snapshot(mapping: .init(remainingPath: "/data~1balance/a~0b", unit: .cny), at: .now).amount == Decimal(string: "12.40"),
              "JSON pointer escaping preserves field identity instead of confusing slash/dot keys")
        let request = try CustomQuotaEndpoint.request(endpoint: "https://api.example.com/balance", auth: .bearer, key: "fixture-not-real")
        check(request.httpMethod == "GET" && request.httpBody == nil
              && request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-not-real"
              && request.value(forHTTPHeaderField: "Cookie") == nil,
              "Custom credentials are sent only through the selected header of the explicit readonly request")
        check((try? CustomQuotaEndpoint.request(endpoint: "https://api.example.com/balance", auth: .bearer, key: "x\r\ny")) == nil,
              "A pasted key cannot inject another HTTP header")
        try CustomQuotaHTTPClient.validate(request)
        var cookie = request; cookie.setValue("fixture", forHTTPHeaderField: "Cookie")
        var post = request; post.httpMethod = "POST"
        var body = request; body.httpBody = Data("fixture".utf8)
        var stream = request; stream.httpBodyStream = InputStream(data: Data("fixture".utf8))
        var both = request; both.setValue("fixture", forHTTPHeaderField: "X-API-Key")
        var imported = request; imported.setValue("fixture", forHTTPHeaderField: "X-Session")
        for bad in [cookie, post, body, stream, both, imported] {
            check((try? CustomQuotaHTTPClient.validate(bad)) == nil,
                  "The transport boundary rejects cookies, bodies, dual keys and unrelated imported session headers")
        }
        let definition = CustomQuotaDefinition(id: "custom-11111111-1111-4111-8111-111111111111", name: "My API", endpoint: "https://api.example.com/balance", auth: .bearer, mapping: mapping)
        try definition.validate()
        let encoded = try CustomQuotaRegistry.encode([definition])
        let decodedRegistry = try CustomQuotaRegistry.decode(encoded)
        check(!String(decoding: encoded, as: UTF8.self).contains("fixture-not-real")
              && decodedRegistry.first == definition,
              "Only source configuration, never a key or cached balance, enters the persisted registry")
        check((try? CustomQuotaRegistry.decode(Data(#"{"schemaVersion":2,"definitions":[]}"#.utf8))) == nil,
              "Unknown registry versions are preserved as failures rather than reset or overwritten")
        let oversized = (0..<32).map { index in
            CustomQuotaDefinition(id: "custom-" + UUID().uuidString.lowercased(), name: "Account \(index)",
                endpoint: "https://api.example.com/" + String(repeating: "a", count: 1980) + "/balance", auth: .none,
                mapping: .init(remainingPath: "/" + String(repeating: "b", count: 1000),
                    subtractPath: "/" + String(repeating: "c", count: 1000), resetPath: "/" + String(repeating: "d", count: 1000), unit: .usd))
        }
        check((try? CustomQuotaRegistry.encode(oversized)) == nil,
              "The registry cannot save an envelope that its next-process decoder would reject as oversized")
        guard failures.isEmpty else { exit(1) }
        print("PASS: custom endpoint boundaries, typed genuine values, zero/units/reset validation, safe field discovery and versioned key-free registry")
    }
}
