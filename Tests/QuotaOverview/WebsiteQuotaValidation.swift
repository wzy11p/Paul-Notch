import Foundation

@main struct WebsiteQuotaValidation {
    static func main() throws {
        var failures = 0
        func check(_ condition: Bool, _ message: String) { if !condition { failures += 1; print("FAIL: \(message)") } }
        let now = Date(timeIntervalSince1970: 1_790_827_200)
        let doubao = try WebsiteQuotaParser.doubao(rows: [
            .init(name: "当前时段", usage: "已用 13%", timing: "2 小时 18 分钟后重置"),
            .init(name: "近 7 天", usage: "未消耗", timing: "开始使用后计时")], at: now)
        check(doubao.value == .percent(87) && doubao.details.contains(where: { $0.value.contains("100%") }),
              "Verified personal quota rows keep both pools separate, not chat percentages or an account gift deadline")
        check(doubao.pools.map(\.value) == [.percent(87), .percent(100)] &&
              doubao.pools.map(\.timing) == ["2 小时 18 分钟后重置", "开始使用后计时"],
              "Compact cards must receive both typed personal pools and preserve their independent reported clocks")
        let noClock = try WebsiteQuotaParser.doubao(rows: [
            .init(name: "当前时段", usage: "已用 13%", timing: ""),
            .init(name: "近 7 天", usage: "未消耗", timing: "")], at: now)
        check(noClock.pools.allSatisfy { !$0.timing.isEmpty },
              "Missing vendor reset times must remain explicitly unknown, not disappear from the compact card")
        let partial = try WebsiteQuotaParser.doubao(rows: [
            .init(name: "当前时段", usage: "已用 <1%", timing: "1 小时后重置"),
            .init(name: "近 7 天", usage: "已用完", timing: "10月6日 12:00 重置")], at: now)
        check(partial.value.text == ">99%" && partial.details.contains(where: { $0.value == "0%" }),
              "A rounded less-than-one source stays a bound instead of inventing an exact 100%; exhaustion stays zero")
        for rows in [[WebsiteQuotaRow(name: "当前时段", usage: "已用 13%", timing: "")],
                     [.init(name: "聊天", usage: "97%", timing: "7天后重置"), .init(name: "近 7 天", usage: "未消耗", timing: "")],
                     [.init(name: "当前时段", usage: "加载中", timing: ""), .init(name: "近 7 天", usage: "未消耗", timing: "")],
                     [.init(name: "当前时段", usage: "已用 -1%", timing: ""), .init(name: "近 7 天", usage: "未消耗", timing: "")]] {
            do { _ = try WebsiteQuotaParser.doubao(rows: rows, at: now); check(false, "Missing, unrelated or loading rows must never become a quota") }
            catch {}
        }
        let audio = try WebsiteQuotaParser.audio(amount: 128_001, reload: "2026-10-03 12:00", ends: nil, at: now)
        check(audio.value == .credits(128_001, unit: "声贝") && audio.timing.contains("2 天"),
              "Audio's own confirmed billing response provides credits and its own reload time, not the API wallet")
        let zero = try WebsiteQuotaParser.audio(amount: 0, reload: nil, ends: nil, at: now)
        check(zero.value == .credits(0, unit: "声贝") && zero.timing == "官方未提供重置 / 到期时间",
              "Only a completed successful credit response can supply real zero; do not invent expiry from plan pricing")
        for amount in [-1.0, Double.nan, Double.infinity, 1.5] {
            do { _ = try WebsiteQuotaParser.audio(amount: amount, reload: nil, ends: nil, at: now); check(false, "Malformed credit values are rejected") }
            catch {}
        }
        check(WebsiteQuotaProvider.doubao.permitsCapture(URL(string: "https://www.doubao.com/member/quota-management")!) &&
              !WebsiteQuotaProvider.doubao.permitsCapture(URL(string: "https://www.doubao.com/chat/test")!),
              "Website capture is scoped to the verified quota route, never chat pages")
        check(WebsiteQuotaProvider.miniMaxCN.permitsCapture(URL(string: "https://www.minimax.cn/audio/subscribe")!) &&
              !WebsiteQuotaProvider.miniMaxCN.permitsCapture(URL(string: "https://www.minimax.cn.evil.invalid/audio/subscribe")!),
              "China and international Audio accounts have exact separate host boundaries")
        let feishuAuthorization = URL(string: "https://accounts.feishu.cn/open-apis/authen/v1/authorize?client_id=fixture&redirect_uri=https%3A%2F%2Fwww.doubao.com%2Ffeishu-code-to-token")!
        check(WebsiteQuotaProvider.doubao.permitsOrigin(feishuAuthorization),
              "Doubao's official Feishu SSO origin must be navigable instead of leaving the login button spinning")
        check(!WebsiteQuotaProvider.doubao.permitsCapture(feishuAuthorization) &&
              !WebsiteQuotaProvider.miniMaxCN.permitsOrigin(feishuAuthorization) &&
              !WebsiteQuotaProvider.miniMaxGlobal.permitsOrigin(feishuAuthorization),
              "An authentication origin is never a quota-capture source or another provider's navigation allowance")
        for address in ["http://accounts.feishu.cn/open-apis/authen/v1/authorize",
                        "https://accounts.feishu.cn.evil.invalid/", "https://evil.accounts.feishu.cn/",
                        "https://accounts.feishu.cn:8443/", "https://fixture@accounts.feishu.cn/",
                        "file:///tmp/feishu.html", "lark://client/passport", "https://unrelated.invalid/"] {
            check(!WebsiteQuotaProvider.doubao.permitsOrigin(URL(string: address)!),
                  "Feishu login must not widen into arbitrary websites, subdomains, ports, credentials or app launches")
        }
        guard failures == 0 else { exit(1) }
        print("PASS: owned website quota units, separate pools, percentage bounds, true zero, unknown dates and strict route gates")
    }
}
