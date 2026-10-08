import Foundation

@main struct QuotaConnectionsValidation {
    static func main() throws {
        var failures: [String] = []
        func check(_ value: Bool, _ message: String) {
            if !value { failures.append(message); print("FAIL: \(message)") }
        }
        let balance = Data(#"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"6.77","granted_balance":"1.10","topped_up_balance":"5.67"},{"currency":"USD","total_balance":"2.50","granted_balance":"0","topped_up_balance":"2.50"}]}"#.utf8)
        let decoded = try DeepSeekBalance.decode(balance, at: Date(timeIntervalSince1970: 1000))
        check(decoded.entries.count == 2 && decoded.entries.first?.total == Decimal(string: "6.77"), "Preserve decimal balances and currencies without adding or converting them")
        for text in ["{}", #"{"is_available":false,"balance_infos":[]}"#,
                     #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"6.77oops","granted_balance":"0","topped_up_balance":"0"}]}"#] {
            check((try? DeepSeekBalance.decode(Data(text.utf8), at: .now)) == nil, "Malformed/missing balances must remain unknown, not zero")
        }
        let request = try QuotaReadRequest.deepSeek(key: "test-token-not-a-real-key")
        check(request.url?.absoluteString == "https://api.deepseek.com/user/balance" && request.httpMethod == "GET" && request.httpBody == nil,
              "Credentials only go to the fixed read-only balance endpoint")
        check(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token-not-a-real-key", "Use the explicitly supplied credential only")
        check((try? QuotaReadRequest.deepSeek(key: "token\r\ninjected: yes")) == nil, "Reject header injection")
        let feedRequest = QuotaReadRequest.resetFeed(etag: #"W/"v1-test""#)
        check(feedRequest.value(forHTTPHeaderField: "Authorization") == nil && feedRequest.value(forHTTPHeaderField: "Cookie") == nil,
              "Public announcements must not receive account credentials or cookies")
        check(feedRequest.value(forHTTPHeaderField: "If-None-Match") == #"W/"v1-test""#, "Reuse feed ETag for conditional reads")
        let feed = Data(#"{"schemaVersion":1,"checkedAt":"2026-09-27T12:00:00+08:00","monitor":{"status":"healthy"},"events":[{"id":"test-1","type":"direct_reset","status":"announced","title":"下周重置","updatedAt":"2026-09-27T11:00:00+08:00","confirmedAt":null,"occurredOn":null,"confirmationBasis":null,"estimate":{"from":"2026-09-29T03:00:00+08:00","basis":"model"},"schedule":null,"posts":[{"text":"下周会有更多重置","originalText":"More resets next week","url":"https://x.com/thsottiaux/status/123"}]}]}"#.utf8)
        let reset = try QuotaResetFeed.decode(feed)
        check(reset.events.count == 1 && reset.events.first?.statusLabel == "预告 · 时间未确认", "Do not turn a model estimate into a confirmed reset time")
        check(reset.events.first?.sourceURL?.host == "x.com", "Keep safe original-post attribution")
        let receipt = String(decoding: feed, as: UTF8.self).replacingOccurrences(of: "\"announced\"", with: "\"confirmed\"").replacingOccurrences(of: "\"confirmationBasis\":null", with: "\"confirmationBasis\":\"receipt_review\"")
        check(try QuotaResetFeed.decode(Data(receipt.utf8)).events.first?.statusLabel == "社区回执核验", "Community receipt review is not an official confirmation post")
        let unsafe = String(decoding: feed, as: UTF8.self).replacingOccurrences(of: "https://x.com/thsottiaux/status/123", with: "file:///tmp/private")
        check(try QuotaResetFeed.decode(Data(unsafe.utf8)).events.first?.sourceURL == nil, "Untrusted feed links cannot open local files")
        let future = String(decoding: feed, as: UTF8.self).replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2")
        check((try? QuotaResetFeed.decode(Data(future.utf8))) == nil, "Unknown feed versions must not overwrite a working snapshot")
        guard failures.isEmpty else { exit(1) }
        print("PASS: exact balance units, strict payloads, read-only request boundaries and conservative public announcement semantics")
    }
}
