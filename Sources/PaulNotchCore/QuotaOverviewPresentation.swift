import Foundation

/// Display units, separate from provider responses and persisted account records.
enum QuotaOverviewValue: Equatable {
    case percent(Int)
    case percentBound(lowerExclusive: Int, upperInclusive: Int)
    case unlimited
    case money(Decimal, currency: String)
    case credits(Int, unit: String)
    case unknown

    var text: String {
        switch self {
        case .percent(let remaining):
            return (0...100).contains(remaining) ? "\(remaining)%" : "无法获取"
        case .percentBound(let lower, let upper):
            return 0 <= lower && lower < upper && upper <= 100 ? ">\(lower)%" : "无法获取"
        case .unlimited: return "暂不限额"
        case .money(let amount, let currency):
            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.numberStyle = .currency
            formatter.currencyCode = currency
            return formatter.string(from: amount as NSDecimalNumber) ?? "无法获取"
        case .credits(let count, let unit):
            guard count >= 0 else { return "无法获取" }
            return "\(count.formatted(.number.locale(Locale(identifier: "en_US")))) \(unit)"
        case .unknown:
            return "无法获取"
        }
    }

    var fraction: Double? {
        guard case .percent(let remaining) = self, (0...100).contains(remaining) else { return nil }
        return Double(remaining) / 100
    }
}

enum QuotaOverviewGroup: String, CaseIterable, Identifiable {
    case membership, usage
    var id: Self { self }
    var title: String { self == .membership ? "会员额度" : "API 与配音" }
}

enum QuotaOverviewFilter: String, CaseIterable, Identifiable {
    case all, membership, usage
    var id: Self { self }
    var title: String {
        switch self {
        case .all: "全部"
        case .membership: "会员"
        case .usage: "API 与配音"
        }
    }
}

enum QuotaOverviewStatus: String {
    case sample = "示例", notConnected = "待接入", stale = "旧数据"
    case current = "已同步", unavailable = "暂不可用"
}

struct QuotaOverviewDetail: Equatable {
    let label: String
    let value: String
}

enum QuotaOverviewKind: String { case membership = "会员", api = "API", audio = "配音" }

/// Independently reported pools belonging to one account, not additional services.
struct QuotaOverviewPool: Equatable {
    let label: String
    let value: QuotaOverviewValue
    let timing: String
}

struct QuotaOverviewAccount: Identifiable, Equatable {
    let id: String
    let name: String
    let account: String
    let group: QuotaOverviewGroup
    let value: QuotaOverviewValue
    let timing: String
    let status: QuotaOverviewStatus
    var details: [QuotaOverviewDetail] = []
    var explanation: String = ""
    var usageKind: QuotaOverviewKind = .api
    var unavailableReason: String? = nil
    var pools: [QuotaOverviewPool] = []
    var kind: QuotaOverviewKind { group == .membership ? .membership : usageKind }

    /// Keep historical values in their source model without presenting them as current.
    var displayValue: String { displayReason == nil ? value.text : "—" }
    var visiblePools: [QuotaOverviewPool] {
        displayReason == nil ? Array(pools.prefix(2)) : []
    }
    var displayReason: String? {
        if let unavailableReason { return unavailableReason }
        switch status {
        case .stale: return "数据已过期，等待重新读取"
        case .unavailable: return "读取未成功，请重试"
        case .notConnected: return "尚未连接账户"
        case .sample, .current:
            return value.text == "无法获取" ? "尚未获得有效数据" : nil
        }
    }
    var accessibilitySummary: String {
        "\(name)，\(account)，\(displayReason == nil ? value.text : "无法获取")，\(displayReason ?? status.rawValue)，\(timing)"
            + visiblePools.map { "，\($0.label) \($0.value.text)，\($0.timing)" }.joined()
    }
}

enum QuotaOverviewMode { case preview, notch }

struct QuotaOverviewTool: Identifiable {
    let id: String
    let title: String
    let systemImage: String
}

/// Equal rounded squares. More accounts add scroll content, never larger or smaller cards.
struct QuotaBentoLayout {
    let columns: Int
    let cardWidth: Double
    let spacing: Double = 18
    let leadingInset: Double

    init(width: Double, accountCount: Int) {
        columns = max(2, min(6, Int((max(0, width) + spacing) / 136)))
        cardWidth = min(118, max(0, (width - spacing * Double(columns - 1)) / Double(columns)))
        leadingInset = max(0, (width - cardWidth * Double(columns) - spacing * Double(columns - 1)) / 2)
    }
}

enum QuotaOverviewQuery {
    static func matches(_ accounts: [QuotaOverviewAccount], search: String,
                        filter: QuotaOverviewFilter) -> [QuotaOverviewAccount] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return accounts.filter { item in
            let groupMatches = filter == .all || item.group.rawValue == filter.rawValue
            return groupMatches && (query.isEmpty || "\(item.name) \(item.account)".localizedStandardContains(query))
        }
    }
}
