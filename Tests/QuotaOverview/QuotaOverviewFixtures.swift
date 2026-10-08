import Foundation

/// Illustrative values only. Never loaded by the personal app or a provider adapter.
enum QuotaOverviewFixtures {
    static func accounts(count: Int) -> [QuotaOverviewAccount] {
        let examples: [QuotaOverviewAccount] = [
            .init(id: "codex", name: "Codex", account: "个人 · 周额度", group: .membership,
                  value: .percent(97), timing: "6 天后重置", status: .sample),
            .init(id: "kimi", name: "Kimi", account: "个人 · 会员", group: .membership,
                  value: .percent(63), timing: "2 天后重置", status: .sample),
            .init(id: "grok", name: "SuperGrok", account: "个人 · 会员", group: .membership,
                  value: .percent(41), timing: "3 天后重置", status: .sample),
            .init(id: "doubao", name: "豆包工作", account: "个人 · 会员", group: .membership,
                  value: .unknown, timing: "重置时间未知", status: .notConnected),
            .init(id: "deepseek", name: "DeepSeek API", account: "个人 · 钱包余额", group: .usage,
                  value: .money(Decimal(string: "28.60")!, currency: "CNY"), timing: "按量扣费", status: .sample),
            .init(id: "minimax-api", name: "MiniMax API", account: "个人 · 钱包余额", group: .usage,
                  value: .money(Decimal(string: "6.77")!, currency: "CNY"), timing: "按量扣费", status: .sample),
            .init(id: "minimax-audio", name: "MiniMax Audio", account: "个人 · 配音会员", group: .usage,
                  value: .credits(128000, unit: "积分"), timing: "8 天后到期", status: .sample, usageKind: .audio)
        ]
        guard count > examples.count else { return Array(examples.prefix(max(0, count))) }
        return examples + (8...count).map { index in
            QuotaOverviewAccount(id: "sample-\(index)", name: "示例服务 \(index)", account: "项目 \(index)",
                                 group: index.isMultiple(of: 2) ? .usage : .membership,
                                 value: index.isMultiple(of: 2) ? .money(Decimal(index), currency: "USD") : .percent(index),
                                 timing: "时间未知", status: index == 9 ? .stale : .sample)
        }
    }
}
