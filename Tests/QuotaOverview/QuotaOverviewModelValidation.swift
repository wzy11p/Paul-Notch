import Foundation

@main
struct QuotaOverviewModelValidation {
    static func main() {
        var failures: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message); print("FAIL: \(message)") }
        }
        let accounts = QuotaOverviewFixtures.accounts(count: 30)
        check(QuotaOverviewQuery.matches(accounts, search: "  kImI  ", filter: .all).map(\.id) == ["kimi"],
              "Searching with spaces or a different case must still find Kimi")
        check(QuotaOverviewQuery.matches(accounts, search: "项目 23", filter: .all).map(\.id) == ["sample-23"],
              "A large account list must be searchable by account name, not just provider")
        check(QuotaOverviewQuery.matches(accounts, search: "MiniMax", filter: .membership).isEmpty,
              "Membership filtering must not mix the API wallet and Audio credits")
        check(QuotaOverviewQuery.matches(accounts, search: "MiniMax", filter: .usage).map(\.id) == ["minimax-api", "minimax-audio"],
              "One provider's wallet and Audio subscription must remain separate entries")
        check(QuotaOverviewQuery.matches(accounts, search: "missing", filter: .all).isEmpty,
              "A failed search must not fall back to unrelated accounts")
        check(QuotaOverviewQuery.matches(accounts, search: "", filter: .all).count == 30,
              "A large overview must not silently discard accounts after its first page")
        for size in [0, 4, 12, 30] {
            let items = QuotaOverviewFixtures.accounts(count: size)
            check(Set(items.map(\.id)).count == size, "Synthetic accounts need stable unique identities at \(size)")
        }
        check(QuotaOverviewValue.percent(100).text == "100%", "A full quota must retain its percent unit")
        check(QuotaOverviewValue.percent(0).text == "0%", "An actual exhausted quota must not become unknown")
        check(QuotaOverviewValue.percent(-1).text == "无法获取", "An invalid percent must not be represented as exhausted")
        check(QuotaOverviewValue.percent(101).fraction == nil, "An invalid percent must not produce a progress bar")
        check(QuotaOverviewValue.unknown.text == "无法获取" && QuotaOverviewValue.unknown.fraction == nil,
              "Unknown balances must have neither zero nor a misleading progress bar")
        check(QuotaOverviewValue.money(Decimal(string: "6.77")!, currency: "CNY").text == "¥6.77",
              "Money must retain decimal cents and its currency")
        check(QuotaOverviewValue.credits(128000, unit: "积分").text == "128,000 积分",
              "Audio balances must retain their unit instead of pretending to be a percentage")
        check(QuotaOverviewValue.money(0, currency: "USD").fraction == nil,
              "A wallet without a spending limit must not acquire a percentage")
        let unavailable = QuotaOverviewAccount(id: "muse", name: "Muse", account: "Meta", group: .membership,
            value: .unknown, timing: "未提供", status: .notConnected)
        check(unavailable.displayValue == "—", "An unread account must stay visually quiet, without a large error headline")
        check(unavailable.accessibilitySummary.contains("无法获取"),
              "A quiet dash must still explain the unavailable value to assistive navigation")
        let twoPools = QuotaOverviewAccount(id: "doubao", name: "豆包工作", account: "ByteDance", group: .membership,
            value: .percent(55), timing: "3 小时后重置", status: .current,
            pools: [.init(label: "当前时段", value: .percent(55), timing: "3 小时后重置"),
                    .init(label: "近 7 天", value: .percent(81), timing: "6 天后重置")])
        check(twoPools.visiblePools.map(\.value) == [.percent(55), .percent(81)],
              "Two independent pools must not be combined into a single percentage")
        let stalePools = QuotaOverviewAccount(id: "doubao", name: "豆包工作", account: "ByteDance", group: .membership,
            value: .percent(55), timing: "3 小时后重置", status: .stale, pools: twoPools.pools)
        check(stalePools.visiblePools.isEmpty && stalePools.displayValue == "—",
              "Expired independent pools must not remain visible as current balances")
        for width in [360.0, 600, 820] {
            for count in [0, 1, 4, 7, 12, 30] {
                let layout = QuotaBentoLayout(width: width, accountCount: count)
                check(layout.columns >= 2 && layout.columns <= 6, "Bento uses a bounded column count")
                check(layout.cardWidth >= 110 && layout.cardWidth <= 118,
                      "Equal square cards stay compact without shrinking into tiny targets")
                check(layout.spacing >= 18 && layout.cardWidth * Double(layout.columns)
                          + layout.spacing * Double(layout.columns - 1) <= width,
                      "Smaller bubbles must have breathing room and remain inside the fixed panel")
            }
        }
        check(QuotaBentoLayout(width: 552, accountCount: 7).columns == 4,
              "The compact notch fits four equal square cards per row")
        check(QuotaBentoLayout(width: 820, accountCount: 4).columns == 6,
              "A wider surface must not turn four square cards into oversized rectangles")
        guard failures.isEmpty else { exit(1) }
        print("PASS: quota search, 0/4/12/30 accounts, separate pools, truthful units and unknown states")
    }
}
