import Foundation

private let balanceFixture = Data(#"{"available_amount":"6.77","cash_balance":"6.77","voucher_balance":"0.00","credit_balance":"0.00","owed_amount":"0.00","balance_alert_switch":false,"balance_alert_threshold":"","base_resp":{"status_code":0,"status_msg":"success"}}"#.utf8)

@MainActor private final class MiniMaxTestVault: QuotaCredentialStoring {
    var key: String?
    var denied = false
    func read() throws -> String? { key }
    func save(_ value: String) throws {
        if denied { throw QuotaConnectionError.keychain }; key = value
    }
    func delete() throws { key = nil }
}

private actor MiniMaxTestTransport {
    var count = 0
    var status = 200
    var body = balanceFixture
    var delayed = false
    var retryAfter: TimeInterval?
    func configure(status: Int, body: Data = balanceFixture, delayed: Bool = false, retryAfter: TimeInterval? = nil) {
        self.status = status; self.body = body; self.delayed = delayed; self.retryAfter = retryAfter
    }
    func fetch(_ request: URLRequest) async throws -> QuotaHTTPResponse {
        count += 1
        guard request.url?.absoluteString == "https://api.minimaxi.com/account/query_balance",
              request.httpMethod == "GET", request.httpBody == nil,
              request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer sk-api-test-") == true else {
            throw QuotaConnectionError.invalidData
        }
        let result = QuotaHTTPResponse(status: status, data: body, etag: nil, retryAfter: retryAfter)
        if delayed { try? await Task.sleep(for: .milliseconds(120)) }
        return result
    }
}

@main struct MiniMaxWalletValidation {
    @MainActor static func main() async throws {
        var failures: [String] = []
        func check(_ value: Bool, _ message: String) {
            if !value { failures.append(message); print("FAIL: \(message)") }
        }
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let balance = try MiniMaxWalletBalance.decode(balanceFixture, at: now)
        check(balance.available == Decimal(string: "6.77") && balance.cash == Decimal(string: "6.77"),
              "Wallet amounts are exact decimals, not percentages or Token Plan counts")
        check(balance.observedAt == now && balance.owed == 0, "Keep source time and independent wallet components")
        for malformed in ["{}", #"{"model_remains":[]}"#,
                          String(decoding: balanceFixture, as: UTF8.self).replacingOccurrences(of: "6.77", with: "6.77 CNY"),
                          String(decoding: balanceFixture, as: UTF8.self).replacingOccurrences(of: "6.77", with: "NaN")] {
            do { _ = try MiniMaxWalletBalance.decode(Data(malformed.utf8), at: now); check(false, "Reject malformed/token-plan wallet payload") }
            catch QuotaConnectionError.invalidData {} catch { check(false, "Unexpected parse rejection") }
        }
        let unauthorized = Data(#"{"base_resp":{"status_code":1004,"status_msg":"untrusted diagnostic secret"}}"#.utf8)
        do { _ = try MiniMaxWalletBalance.decode(unauthorized, at: now); check(false, "HTTP-200 business auth errors are not a balance") }
        catch QuotaConnectionError.authentication {} catch { check(false, "MiniMax 1004 must request authorization") }
        for key in ["", "sk-cp-test-plan", "eyJ-old-or-unknown", "sk-api-test-a\nb", "sk-api-test-a b"] {
            do { _ = try QuotaReadRequest.miniMaxWallet(key: key); check(false, "Reject unsupported or unsafe key before sending") }
            catch QuotaConnectionError.invalidKey {} catch { check(false, "Unexpected key rejection") }
        }
        let request = try QuotaReadRequest.miniMaxWallet(key: "sk-api-test-valid")
        check(request.url?.absoluteString == "https://api.minimaxi.com/account/query_balance" &&
              request.httpMethod == "GET" && request.httpBody == nil && !request.httpShouldHandleCookies,
              "Only the documented China wallet read endpoint receives the key")

        let suite = "test.paul.minimax.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let vault = MiniMaxTestVault()
        let transport = MiniMaxTestTransport()
        let store = MiniMaxWalletStore(defaults: defaults, vault: vault, allowsConnections: true,
                                      transport: { try await transport.fetch($0) })
        store.refresh()
        check(await transport.count == 0, "No opt-in means no request or secret read")
        await transport.configure(status: 200, delayed: true)
        check(store.connect("sk-api-test-valid"), "Explicit setup starts validation")
        check(vault.key == nil && !store.enabled, "Unverified key must not be saved or presented as connected")
        check(!store.connect("sk-api-test-double"), "A double submit cannot change the in-flight key")
        await settle(store)
        check(store.snapshot?.available == Decimal(string: "6.77") && vault.key == "sk-api-test-valid" && store.enabled,
              "Verified response and secure save establish the connection")
        let home = store.account(now: .now)
        check(home.id == "minimax-api" && home.value == .money(Decimal(string: "6.77")!, currency: "CNY") && home.status == .current,
              "Home shows the parsed wallet and native currency, not a placeholder")
        let clock = CadenceClock()
        let cadence = MiniMaxWalletStore(defaults: defaults, vault: vault, allowsConnections: true,
            transport: { try await transport.fetch($0) }, clock: { clock.now })
        cadence.refresh(); await settle(cadence)
        let beforeDue = await transport.count
        await transport.configure(status: 200, body: Data(String(decoding: balanceFixture, as: UTF8.self)
            .replacingOccurrences(of: "6.77", with: "5.20").utf8))
        clock.now = clock.now.addingTimeInterval(29)
        cadence.refresh(); await settle(cadence)
        check(await transport.count == beforeDue, "MiniMax cannot query before its thirty-second due time")
        clock.now = clock.now.addingTimeInterval(1)
        cadence.refresh(); await settle(cadence)
        check(cadence.snapshot?.available == Decimal(string: "5.20"),
              "MiniMax source changes appear after thirty seconds without a new Key or setup action")
        cadence.stop()
        await transport.configure(status: 400, body: unauthorized)
        _ = store.connect("sk-api-test-invalid")
        await settle(store)
        check(vault.key == "sk-api-test-valid" && store.snapshot != nil && !store.needsAuthorization,
              "Failed replacement keeps the old working account and key")
        check(store.error != nil && store.error?.contains("untrusted") == false,
              "Server error text and credentials never enter UI diagnostics")
        await transport.configure(status: 200)
        vault.denied = true
        _ = store.connect("sk-api-test-denied")
        await settle(store)
        check(vault.key == "sk-api-test-valid" && store.error != nil, "Keychain failure preserves the previous connection")
        vault.denied = false
        store.stop()
        let restarted = MiniMaxWalletStore(defaults: defaults, vault: vault, allowsConnections: true,
                                          transport: { try await transport.fetch($0) })
        restarted.refresh()
        await settle(restarted)
        check(restarted.enabled && restarted.snapshot != nil, "Restart re-reads an explicitly connected wallet")
        await transport.configure(status: 500)
        restarted.refresh(force: true)
        await settle(restarted)
        check(restarted.snapshot != nil && restarted.account(now: .now).status == .stale,
              "Network failure labels the last successful amount as stale")
        await transport.configure(status: 200, body: unauthorized)
        restarted.refresh(force: true)
        await settle(restarted)
        check(restarted.needsAuthorization && restarted.snapshot == nil,
              "Expired active credentials clear the cached value and stop background retries")
        let countAtAuthFailure = await transport.count
        restarted.refresh(force: true)
        check(await transport.count == countAtAuthFailure, "Unauthorized account is not polled repeatedly")
        await transport.configure(status: 200, delayed: true)
        _ = restarted.connect("sk-api-test-late")
        for _ in 0..<10 { restarted.refresh(force: true) }
        restarted.disconnect()
        try await Task.sleep(for: .milliseconds(170))
        check(restarted.snapshot == nil && vault.key == nil && !restarted.enabled,
              "Disconnect blocks late publication and late key writes")
        let isolated = MiniMaxWalletStore(defaults: defaults, vault: vault, allowsConnections: false,
                                         transport: { try await transport.fetch($0) })
        check(!isolated.connect("sk-api-test-isolated") && vault.key == nil, "Preview cannot connect real credentials")
        await transport.configure(status: 429, retryAfter: 600)
        _ = restarted.connect("sk-api-test-limited")
        await settle(restarted)
        let countAtLimit = await transport.count
        check(!restarted.connect("sk-api-test-limited"), "Retry-After blocks repeated setup submissions")
        restarted.refresh(force: true)
        check(await transport.count == countAtLimit, "Rate limiting also blocks manual refresh")
        restarted.stop()
        guard failures.isEmpty else { exit(1) }
        print("PASS: MiniMax CN wallet decimals, key scope, explicit opt-in, verified save, safe replacement, restart, stale/auth/rate states and disconnect races")
    }
    @MainActor private final class CadenceClock { var now = Date() }
    @MainActor private static func settle(_ store: MiniMaxWalletStore) async {
        for _ in 0..<150 {
            if !store.isRefreshing { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
