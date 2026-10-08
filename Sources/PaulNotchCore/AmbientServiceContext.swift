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
}

/// Display-only adaptation of the same canonical account used by Home. Focus
/// changes never start requests, create sessions or authorize Keychain reads.
struct AmbientQuotaPresentation {
    let service: AmbientQuotaService
    let lines: [AmbientQuotaLine]
    let activity: AmbientQuotaActivity
    let summary: String

    static func make(service: AmbientQuotaService, account: QuotaOverviewAccount,
                     codexWindows: [CodexQuotaWindow] = [], resetsAt: Date? = nil, observedAt: Date? = nil,
                     tasksAreFresh: Bool = false, runningTaskCount: Int = 0, at now: Date) -> Self {
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
            } else {
                let reset = resetsAt ?? observedAt.flatMap { dateFromProviderTiming(account.timing, observedAt: $0) }
                if reset.map({ $0 <= now }) == true { reason = "等待重置后的新额度" }
                else {
                    let period = account.timing == "开始使用后计时" ? "待用" : countdown(reset, at: now)
                    lines = [.init(id: service.rawValue, period: period, value: account.value)]
                }
            }
        }
        if !correctSource || !observedIsFresh { reason = reason ?? "尚未获得该服务的当前额度" }
        let quota = lines.isEmpty ? "额度暂不可用，\(reason ?? "等待有效数据")" :
            lines.map { "\($0.value.text)剩余，\($0.period)重置倒计时" }.joined(separator: "；")
        let tasks: String
        switch activity {
        case .running(let count): tasks = "\(count) 个 \(service.name) 任务正在运行"
        case .idle: tasks = "\(service.name) 空闲"
        case .unknown: tasks = "\(service.name) 任务状态尚未同步"
        case .notAvailable: tasks = "\(service.name) 任务状态暂未接入，不显示猜测数量"
        }
        return .init(service: service, lines: lines, activity: activity,
            summary: "\(service.name)，\(quota)，\(account.id == service.rawValue ? account.timing : "重置时间暂不可用")，\(tasks)")
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
