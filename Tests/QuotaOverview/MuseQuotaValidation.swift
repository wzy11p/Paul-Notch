import Foundation

/// Synthetic data only. Native account values must never become fixtures.
@main struct MuseQuotaValidation {
    static func main() throws {
        guard let muse = WebsiteQuotaProvider(rawValue: "muse") else {
            print("FAIL: Muse has no owned first-login quota provider")
            exit(1)
        }
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures += 1; print("FAIL: \(message)") }
        }
        check(muse.accountID == "muse" && muse.name == "Muse", "Muse must own a distinct saved login, not reuse Audio or Doubao")
        check(muse.quotaURL.absoluteString == "https://muse.ai/?settings_tab=general",
              "First connection opens General usage, not the separate subscription-management pane")
        check(muse.permitsCapture(muse.quotaURL), "Official quota route must be readable")
        check(muse.permitsCapture(URL(string: "https://muse.ai/")!),
              "Muse consumes its settings deep link: the cleared root may reach bounded rendered General verification")
        for site in ["https://muse.ai/?settings_tab=connectors", "https://muse.ai/?settings_tab=general&pane=wallet",
                     "https://muse.ai/chat/fixture?settings_tab=general&pane=subscriptions", "https://auth.muse.ai/?settings_tab=general&pane=subscriptions",
                     "https://muse.ai.evil.invalid/?settings_tab=general&pane=subscriptions", "http://muse.ai/?settings_tab=general&pane=subscriptions",
                     "https://muse.ai/?settings_tab=general&settings_tab=chat&pane=subscriptions",
                     "https://muse.ai/?settings_tab=general&pane=subscriptions", "https://muse.ai/?settings_tab=general&chat=fixture"] {
            check(!muse.permitsCapture(URL(string: site)!), "Chat, login, ambiguous queries and foreign pages cannot supply quota")
        }
        for site in ["https://auth.muse.ai/", "https://auth.meta.com/", "https://www.facebook.com/", "https://www.instagram.com/"] {
            let url = URL(string: site)!
            check(muse.permitsOrigin(url) && !muse.permitsCapture(url), "Observed official SSO origins are navigation only, never capture")
            check(!WebsiteQuotaProvider.doubao.permitsOrigin(url) && !WebsiteQuotaProvider.miniMaxCN.permitsOrigin(url),
                  "Muse login does not expand existing providers' allowed origins")
        }
        for site in ["https://auth.meta.com.evil.invalid/", "https://evil.auth.meta.com/", "https://auth.meta.com:8443/",
                     "https://fixture@auth.meta.com/", "file:///tmp/muse.html", "endo-window://settings", "https://unrelated.invalid/"] {
            check(!muse.permitsOrigin(URL(string: site)!), "Muse login cannot silently navigate arbitrary sites, files or another app")
        }
        let now = Date(timeIntervalSince1970: 1_790_827_200)
        let snapshot = try WebsiteQuotaParser.muse(used: 29.25, reset: "2026-10-10T12:30:00Z",
            extraBalance: 543_210, extraDisplay: nil, extraNeverExpires: true, at: now)
        check(snapshot.value == .percent(70) && snapshot.resetsAt == Date(timeIntervalSince1970: 1_791_635_400),
              "Muse used percentage becomes remaining; only the supplied precise reset becomes a clock")
        check(snapshot.pools.map(\.value) == [.percent(70), .credits(543_210, unit: "词元")],
              "Weekly quota and separately purchased tokens retain separate units, not API money or combined percentages")
        check(snapshot.pools.last?.timing == "从不过期", "Only a provider-reported nonexpiring extra pool may say never expires")
        let unknown = try WebsiteQuotaParser.muse(used: 0, reset: nil, extraBalance: nil,
            extraDisplay: nil, extraNeverExpires: false, at: now)
        check(unknown.value == .percent(100) && unknown.resetsAt == nil && unknown.pools.count == 1,
              "Confirmed zero use is real 100%; missing extra balance cannot default to zero")
        let dateOnly = try WebsiteQuotaParser.muse(used: 100, reset: "每周限额将在 10月10日重置",
            extraBalance: nil, extraDisplay: "剩余 2.5 万个词元", extraNeverExpires: true, at: now)
        check(dateOnly.value == .percent(0) && dateOnly.resetsAt == nil && dateOnly.timing.contains("10月10日"),
              "Date-only native captions are retained but cannot invent an exact midnight or a seven-day clock")
        check(dateOnly.details.contains(where: { $0.label == "额外余额（页面显示）" && $0.value == "剩余 2.5 万个词元" }) && dateOnly.pools.count == 1,
              "A rounded page-only token label is not rewritten as a fabricated exact token count")
        for used in [-1.0, 100.1, Double.nan, Double.infinity] {
            do { _ = try WebsiteQuotaParser.muse(used: used, reset: nil, extraBalance: nil,
                    extraDisplay: nil, extraNeverExpires: false, at: now)
                check(false, "Malformed usage must never publish a percentage")
            } catch {}
        }
        for balance in [-1, 1_000_000_000_001] {
            do { _ = try WebsiteQuotaParser.muse(used: 10, reset: nil, extraBalance: balance,
                    extraDisplay: nil, extraNeverExpires: false, at: now)
                check(false, "Invalid extra token balances cannot be published")
            } catch {}
        }
        guard failures == 0 else { exit(1) }
        print("PASS: Muse first owned login identity, quota route and exact SSO/capture boundaries")
    }
}
