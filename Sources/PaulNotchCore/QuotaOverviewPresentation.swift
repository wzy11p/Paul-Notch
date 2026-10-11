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
    var sourceID: String? = nil
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

/// Equal readable bubbles; count-aware sizing is separate from the manual viewport.
struct QuotaBentoLayout {
    static let preferredCardWidth: Double = 110
    static let minimumCardWidth: Double = 108
    static let gap: Double = 16
    static let edgeInset: Double = 6
    let columns: Int
    let cardWidth: Double
    let spacing: Double = Self.gap
    let leadingInset: Double
    let contentHeight: Double

    init(width: Double, accountCount: Int) {
        let usable = max(0, width - Self.edgeInset * 2)
        let fitting = max(1, Int((usable + spacing) / (Self.minimumCardWidth + spacing)))
        columns = min(8, max(1, accountCount), fitting)
        cardWidth = min(Self.preferredCardWidth, max(0, (usable - spacing * Double(columns - 1)) / Double(columns)))
        leadingInset = max(0, (width - cardWidth * Double(columns) - spacing * Double(columns - 1)) / 2)
        let rows = (max(0, accountCount) + columns - 1) / columns
        contentHeight = Double(rows) * cardWidth + Double(max(0, rows - 1)) * spacing + Self.edgeInset * 2
    }
}

/// Semantic Home extent, not a SwiftUI minimum-size probe or provider snapshot.
struct QuotaHomeLayout: Equatable {
    var accountCount = 8
    var supplementaryHeight: Double = 0
    var minimumBodyHeight: Double = 0
    // Grip 16 + Home padding 18 + header 30 + two gaps 16 + footer 24.
    static let chromeHeight: Double = 104
    static let horizontalPadding: Double = 28
    static let minimumSize = CGSize(width: 360, height: 240)

    func size(topInset: CGFloat, screen: CGSize) -> CGSize {
        let count = max(0, accountCount)
        let availableWidth = max(1, Double(screen.width) - 24)
        let availableHeight = max(1, Double(screen.height) - 12)
        let pitch = QuotaBentoLayout.preferredCardWidth + QuotaBentoLayout.gap
        let maxColumns = max(1, min(8, Int((availableWidth - Self.horizontalPadding
            - QuotaBentoLayout.edgeInset * 2 + QuotaBentoLayout.gap) / (QuotaBentoLayout.minimumCardWidth + QuotaBentoLayout.gap))))
        let preferred = count <= 4 ? 2 : count <= 6 ? 3 : count <= 12 ? 4 : count <= 20 ? 5 : 6
        var columns = min(maxColumns, max(1, count), preferred)
        let chrome = Double(topInset) + Self.chromeHeight + supplementaryHeight
        let fittingRows = max(1, Int((availableHeight - chrome - QuotaBentoLayout.edgeInset * 2
            + QuotaBentoLayout.gap) / pitch))
        // When height is limited, use available width before requiring scrolling.
        columns = min(maxColumns, max(columns, (count + fittingRows - 1) / fittingRows))
        let width = min(availableWidth, max(Double(Self.minimumSize.width),
            Double(columns) * QuotaBentoLayout.preferredCardWidth + Double(columns - 1) * QuotaBentoLayout.gap
                + QuotaBentoLayout.edgeInset * 2 + Self.horizontalPadding))
        let grid = QuotaBentoLayout(width: width - Self.horizontalPadding, accountCount: count)
        let body = max(minimumBodyHeight, Self.chromeHeight + supplementaryHeight + (count == 0 ? 150 : grid.contentHeight))
        return CGSize(width: width, height: min(availableHeight, max(Double(Self.minimumSize.height), Double(topInset) + body)))
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
