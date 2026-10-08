import Foundation

enum DesktopQuotaProvider: String, CaseIterable, Sendable {
    case cursor, grok, doubao
    var name: String {
        switch self { case .cursor: "Cursor"; case .grok: "Grok Bot"; case .doubao: "豆包工作" }
    }
    var bundleID: String {
        switch self {
        case .cursor: "com.todesktop.230313mzl4w4u92"
        case .grok: "com.anysphere.sand"
        case .doubao: "com.work.pc.doubao"
        }
    }
    var instructions: String {
        switch self {
        case .cursor: "设置 → Plan & Usage"
        case .grok: "左下角账户菜单 → 设置 → 用量与账单"
        case .doubao: "左下角账户菜单 → 当前时段额度用量 → 订阅与额度管理"
        }
    }
}

struct DesktopQuotaPool: Equatable, Sendable {
    let name: String
    let used: Double
    var remaining: Int { Int(max(0, min(100, 100 - used)).rounded(.down)) }
}

struct DesktopQuotaSnapshot: Equatable, Sendable {
    let pools: [DesktopQuotaPool]
    let resetLabel: String?
    let observedAt: Date
    var expiryLabel: String? = nil
    var resetsAt: Date? = nil
    var sourceName: String? = nil
}

enum DesktopQuotaFailure: Error, Equatable, Sendable {
    case permission, notRunning, pageUnavailable, invalidData, preview
    var message: String {
        switch self {
        case .permission: "Paul Notch 的辅助功能授权未生效。开启后在这里重试，不需要输入会员密码。"
        case .notRunning: "没有找到正在运行的应用。先打开并登录，再点读取。"
        case .pageUnavailable: "尚未读到额度页面。按下方路径打开原应用的额度页，再点读取；不会把聊天中的百分比当作额度。"
        case .invalidData: "原应用的额度格式暂时无法识别，未使用猜测数值。请确认页面已加载完成后重试。"
        case .preview: "隔离测试不读取个人账户，请在正式版使用。"
        }
    }
}

/// Input is limited by the AX adapter to a verified quota section, never chat content.
enum DesktopQuotaParser {
    static func parse(_ provider: DesktopQuotaProvider, lines: [String], at date: Date) throws -> DesktopQuotaSnapshot {
        let lines = Array(Set(lines.filter { $0.count <= 512 }.map {
            $0.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }))
        func captures(_ pattern: String) -> [String] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            return lines.compactMap { line in
                guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                      let range = Range(match.range(at: 1), in: line) else { return nil }
                return String(line[range])
            }
        }
        func pool(_ name: String, _ pattern: String) throws -> DesktopQuotaPool {
            let raw = captures(pattern)
            let values = Set(raw.compactMap(Double.init))
            guard !raw.isEmpty, raw.count == raw.compactMap(Double.init).count, values.count == 1,
                  let value = values.first, value.isFinite, (0...100).contains(value) else {
                throw DesktopQuotaFailure.invalidData
            }
            return .init(name: name, used: value)
        }
        let number = #"([0-9]+(?:\.[0-9]+)?)\s*%"#
        let pools: [DesktopQuotaPool]
        switch provider {
        case .cursor:
            pools = [try pool("Cursor Models", "^Cursor Models(?: · Includes Cursor Grok and Composer)? " + number + " used$"),
                     try pool("Other Models", "^Other Models " + number + " used$")]
        case .grok:
            pools = [try pool("每周额度", "^(?:(?:每周用量|Weekly usage|每周用量限额[:：])\\s*|[0-9]+\\s*天后重置\\s*)" + number + "$")]
        case .doubao:
            let unstarted = captures(#"(?:^|\s)当前时段 (未消耗) 开始使用后计时(?:\s|$)"#)
            let weeklyUnstarted = captures(#"(?:^|\s)近 7 天 (未消耗) 开始使用后计时(?:\s|$)"#)
            if !unstarted.isEmpty, !weeklyUnstarted.isEmpty {
                let menu = captures("^当前时段额度用量\\s*" + number + "$")
                guard menu.allSatisfy({ Double($0) == 0 }) else { throw DesktopQuotaFailure.invalidData }
                pools = [.init(name: "当前时段额度", used: 0), .init(name: "近 7 天额度", used: 0)]
            } else {
                pools = [try pool("当前时段额度", "^当前时段额度用量\\s*" + number + "$")]
            }
        }
        let days = captures(#"(?:^|\s)Usage limits reset on .*?\(\s*([0-9]+) days? left\s*\)(?:\s|$)"#)
        let grokDays = captures(#"^([0-9]+)\s*天后重置(?:\s*[0-9]+(?:\.[0-9]+)?\s*%)?$"#)
        let sourceDays = provider == .cursor ? days : (provider == .grok ? grokDays : [])
        let reset = Set(sourceDays).count == 1 ? sourceDays.first.flatMap(Int.init) : nil
        let resetLabel = provider == .doubao && pools.count == 2 ? "开始使用后计时"
            : reset.flatMap { (0...366).contains($0) ? "约 \($0) 天后重置" : nil }
        let expiry = provider == .doubao
            ? captures(#"^个人订阅 .+ (赠送时长至(?:[1-9]|1[0-2])月(?:[1-9]|[12][0-9]|3[01])日)$"#) : []
        return .init(pools: pools, resetLabel: resetLabel, observedAt: date,
                     expiryLabel: Set(expiry).count == 1 ? expiry.first : nil)
    }
}
