import Foundation

/// App identity only: no window titles, chat, browser tabs, AX permission or
/// credentials are needed to choose which already-connected source to show.
enum AmbientQuotaService: String, CaseIterable {
    case codex, cursor, grok, doubao, muse
    var name: String {
        switch self {
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .grok: "Grok Bot"
        case .doubao: "豆包工作"
        case .muse: "Muse"
        }
    }
    static func matching(bundleIdentifier: String?) -> Self? {
        switch bundleIdentifier {
        case "com.openai.codex": .codex
        case "com.todesktop.230313mzl4w4u92": .cursor
        case "com.anysphere.sand": .grok
        case "com.work.pc.doubao", "com.work.pc.doubao.browser": .doubao
        case "com.meta.endo": .muse
        default: nil
        }
    }
}

struct AmbientServiceSelection {
    private(set) var service: AmbientQuotaService = .codex
    mutating func observe(bundleIdentifier: String?) {
        // Paul gaining focus, login prompts and ordinary apps must not erase
        // the last AI context. A browser is not a guessed membership source.
        if let matching = AmbientQuotaService.matching(bundleIdentifier: bundleIdentifier) { service = matching }
    }
}

enum AmbientQuotaActivity: Equatable {
    case running(Int), idle, unknown, notAvailable
    var displayCount: String? {
        switch self {
        case .running(let count): count > 9 ? "9+" : "\(count)"
        case .unknown: "?"
        case .notAvailable: "—"
        case .idle: nil
        }
    }
    var isWorking: Bool { if case .running = self { return true }; return false }
}

struct AmbientQuotaLine: Identifiable, Equatable {
    let id: String
    let period: String
    let value: QuotaOverviewValue
    var poolLabel: String? = nil
    var resetDescription: String? = nil
    /// Preserve a provider's month/day caption as a calendar date, never as a
    /// guessed timezone/year or duration. Hover retains the full original text.
    var resetCalendarCaption: String? {
        guard DoubaoQuotaWindow(rawValue: id) != nil, period == "—", let text = resetDescription,
              text.count <= 150,
              let regex = try? NSRegularExpression(pattern: #"^([0-9]{1,2})月([0-9]{1,2})日\s+([0-9]{1,2}):([0-9]{2})\s+重置$"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let parts = (1...4).compactMap { index -> Int? in
            Range(match.range(at: index), in: text).flatMap { Int(text[$0]) }
        }
        guard parts.count == 4, (1...12).contains(parts[0]), (0...23).contains(parts[2]),
              (0...59).contains(parts[3]),
              (1...[31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][parts[0] - 1]).contains(parts[1]) else { return nil }
        return "\(parts[0])/\(parts[1])"
    }
    var countdownOnly: String {
        if let poolLabel, period.hasPrefix(poolLabel) { return String(period.dropFirst(poolLabel.count)) }
        return period
    }
}

/// These are two limits on the same membership, not two accounts. Stable
/// identities keep unavailable/expired slots from silently changing meaning.
enum DoubaoQuotaWindow: String, CaseIterable {
    case short = "doubao.short", weekly = "doubao.weekly"
    var title: String { self == .short ? "5 小时" : "7 天总额" }
    var marker: String { self == .short ? "5h" : "7天" }
    func matches(_ pool: QuotaOverviewPool) -> Bool {
        if let sourceID = pool.sourceID { return sourceID == rawValue }
        return self == .short ? pool.label == "当前时段" : pool.label == "近 7 天"
    }
    var unavailableLine: AmbientQuotaLine {
        .init(id: rawValue, period: "—", value: .unknown, poolLabel: marker, resetDescription: "尚未返回当前额度")
    }
}

/// Display-only adaptation of the same canonical account used by Home. Focus
/// changes never start requests, create sessions or authorize Keychain reads.
struct AmbientQuotaPresentation {
    let service: AmbientQuotaService
    let lines: [AmbientQuotaLine]
    let activity: AmbientQuotaActivity
    let summary: String
    var cursorModel: CursorModelSelection? = nil
    var liquidValue: QuotaOverviewValue? {
        if service == .doubao {
            guard let value = lines.first(where: { $0.id == DoubaoQuotaWindow.weekly.rawValue })?.value,
                  Self.isMembershipValue(value) else { return nil }
            return value
        }
        return service == .cursor && lines.count != 1 ? nil : lines.first?.value
    }

    static func make(service: AmbientQuotaService, account: QuotaOverviewAccount,
                     codexWindows: [CodexQuotaWindow] = [], resetsAt: Date? = nil, observedAt: Date? = nil,
                     tasksAreFresh: Bool = false, runningTaskCount: Int = 0,
                     cursorModel: CursorModelSelection = .unavailable, at now: Date) -> Self {
        let activity: AmbientQuotaActivity = service != .codex ? .notAvailable : !tasksAreFresh ? .unknown
            : runningTaskCount > 0 ? .running(runningTaskCount) : .idle
        var lines: [AmbientQuotaLine] = []
        var reason = account.displayReason
        let correctSource = account.id == service.rawValue && account.group == .membership &&
            account.status == .current && reason == nil && isMembershipValue(account.value)
        let observedIsFresh = observedAt.map { (-60...90).contains(now.timeIntervalSince($0)) } ?? true
        if correctSource && observedIsFresh {
            if service == .codex {
                lines = codexWindows.filter { $0.remainingPercent.isFinite && !($0.resetsAt.map { $0 <= now } ?? false) }
                    .sorted { rank($0) < rank($1) }.prefix(2).map {
                        .init(id: $0.id, period: QuotaResetCountdown.shortLabel(windowDurationMinutes: $0.windowDurationMinutes,
                            resetsAt: $0.resetsAt, at: now), value: .percent(Int($0.remainingPercent.rounded())))
                    }
            } else if service == .doubao {
                lines = doubaoLines(account, observedAt: observedAt, at: now)
            } else {
                let reset = resetsAt ?? observedAt.flatMap { dateFromProviderTiming(account.timing, observedAt: $0) }
                if reset.map({ $0 <= now }) == true { reason = "等待重置后的新额度" }
                else {
                    let period = account.timing == "开始使用后计时" ? "待用" : countdown(reset, at: now)
                    if service == .cursor {
                        let pools = account.visiblePools.compactMap { pool -> (CursorModelPool, QuotaOverviewValue)? in
                            let id = pool.sourceID ?? (pool.label == "Cursor" ? "Cursor Models" : pool.label == "其他模型" ? "Other Models" : pool.label)
                            guard let kind = CursorModelPool(rawValue: id), isMembershipValue(pool.value) else { return nil }
                            return (kind, pool.value)
                        }
                        let chosen = pools.filter { cursorModel.pool == nil || $0.0 == cursorModel.pool }
                        let unique = Set(chosen.map { $0.0.rawValue }).count == chosen.count
                        if chosen.isEmpty || !unique { reason = "当前模型对应的额度尚未返回" }
                        else {
                            lines = chosen.map { kind, value in
                                .init(id: kind.rawValue, period: chosen.count > 1 ? kind.marker + period : period,
                                      value: value, poolLabel: chosen.count > 1 ? kind.marker : nil)
                            }
                        }
                    } else { lines = [.init(id: service.rawValue, period: period, value: account.value)] }
                }
            }
        }
        if !correctSource || !observedIsFresh { reason = reason ?? "尚未获得该服务的当前额度" }
        let quota = lines.isEmpty ? "额度暂不可用，\(reason ?? "等待有效数据")" : lines.map { line in
            if let window = DoubaoQuotaWindow(rawValue: line.id) {
                return "\(window.title)剩余 \(line.value == .unknown ? "待确认" : line.value.text)，\(line.resetDescription ?? "未提供重置时间")，重置倒计时 \(line.period)"
            }
            return "\(line.value.text)剩余，\(line.period)重置倒计时"
        }.joined(separator: "；")
        let tasks: String
        switch activity {
        case .running(let count): tasks = "\(count) 个 \(service.name) 任务正在运行"
        case .idle: tasks = "\(service.name) 空闲"
        case .unknown: tasks = "\(service.name) 任务状态尚未同步"
        case .notAvailable: tasks = "\(service.name) 任务状态暂未接入，不显示猜测数量"
        }
        let modelSummary = service == .cursor ? "；\(cursorModel.explanation)；内指 Cursor Models，外指 Other Models" :
            service == .doubao ? "；球内水位表示 7 天总额；两个额度独立更新和重置" : ""
        return .init(service: service, lines: lines, activity: activity,
            summary: "\(service.name)，\(quota)，\(account.id == service.rawValue ? account.timing : "重置时间暂不可用")，\(tasks)\(modelSummary)",
            cursorModel: service == .cursor ? cursorModel : nil)
    }
    private static func doubaoLines(_ account: QuotaOverviewAccount, observedAt: Date?, at now: Date) -> [AmbientQuotaLine] {
        DoubaoQuotaWindow.allCases.map { window in
            let matches = account.visiblePools.filter(window.matches)
            // Older desktop readers may return only the primary value. Never
            // reuse it as the weekly total, nor pick an arbitrary duplicate.
            let pool: QuotaOverviewPool?
            if matches.count == 1 { pool = matches[0] }
            else if account.pools.isEmpty && window == .short {
                pool = .init(label: "当前时段", value: account.value, timing: account.timing)
            } else { pool = nil }
            guard let pool, isMembershipValue(pool.value) else { return window.unavailableLine }
            let reset = observedAt.flatMap { dateFromProviderTiming(pool.timing, observedAt: $0) }
            if reset.map({ $0 <= now }) == true {
                return .init(id: window.rawValue, period: "待刷新", value: .unknown, poolLabel: window.marker,
                             resetDescription: "等待官方返回重置后的新额度")
            }
            return .init(id: window.rawValue,
                period: pool.timing == "开始使用后计时" ? "待用" : countdown(reset, at: now),
                value: pool.value, poolLabel: window.marker, resetDescription: pool.timing)
        }
    }
    private static func rank(_ window: CodexQuotaWindow) -> Int {
        switch window.windowDurationMinutes { case 10080: 0; case 300: 1; default: 2 }
    }
    private static func isMembershipValue(_ value: QuotaOverviewValue) -> Bool {
        switch value { case .percent, .percentBound, .unlimited: true; default: false }
    }
    private static func countdown(_ reset: Date?, at now: Date) -> String {
        guard let reset else { return "—" }
        let seconds = reset.timeIntervalSince(now)
        guard seconds.isFinite, seconds > 0, seconds <= 366 * 86400 else { return "—" }
        if seconds >= 86400 { return "\(Int(ceil(seconds / 86400)))D" }
        if seconds >= 3600 { return "\(Int(ceil(seconds / 3600)))H" }
        if seconds >= 60 { return "\(Int(ceil(seconds / 60)))M" }
        return "<1M"
    }
    private static func dateFromProviderTiming(_ text: String, observedAt: Date) -> Date? {
        // Exact relative countdown from the already-verified quota subtree.
        // Absolute dates lacking a year/timezone and ambiguous prose stay unknown.
        let pattern = #"^\s*(?:([0-9]{1,3})\s*天\s*)?(?:([0-9]{1,2})\s*小时\s*)?(?:([0-9]{1,2})\s*分钟\s*)?后重置\s*$"#
        guard text.count <= 150, let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let values = (1...3).map { index -> Int in
            guard let range = Range(match.range(at: index), in: text) else { return 0 }
            return Int(text[range]) ?? 0
        }
        guard values[0] <= 366, values[1] < 24, values[2] < 60 else { return nil }
        let seconds = values[0] * 86400 + values[1] * 3600 + values[2] * 60
        guard seconds > 0, seconds <= 366 * 86400 else { return nil }
        return observedAt.addingTimeInterval(TimeInterval(seconds))
    }
}
