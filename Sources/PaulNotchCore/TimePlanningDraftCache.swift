import Foundation

/// Unsubmitted form state only. Canonical goals, projects and task plans live in TimePlanStore.
struct TimePlanningDraft: Codable, Equatable {
    var selectedDate: Date = .now
    var pageRaw: String = "today"
    var weekDraft: String = ""
    var goalDraft: String = ""
    var projectDraft: String = ""
    var newProjectGoalID: UUID?
    var editingTaskID: UUID?
    var stepDraft: String = ""
    var estimateDraft: String = ""
    var hasStartTime: Bool = false
    var startTime: Date = .now
    var editingGoalID: UUID?
    var editingProjectID: UUID?
    var goalRenameDraft: String = ""
    var projectRenameDraft: String = ""
    /// Optional additions preserve decoding of drafts written before freeform capture existed.
    var captureDraft: String?
    var captureTitleDraft: String?
    var captureTargetDate: Date?
    var captureGoalID: UUID?
    var captureActionDraft: String?
    var captureActionID: UUID?
}

struct TimePlanningDraftCache {
    static let storageKey = "time-planning-draft-v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = AppEnvironment.defaults) {
        self.defaults = defaults
    }

    func load() -> TimePlanningDraft? {
        guard let data = defaults.data(forKey: Self.storageKey) else { return nil }
        return try? JSONDecoder().decode(TimePlanningDraft.self, from: data)
    }

    @discardableResult
    func save(_ draft: TimePlanningDraft) -> Bool {
        guard let data = try? JSONEncoder().encode(draft) else { return false }
        defaults.set(data, forKey: Self.storageKey)
        return defaults.synchronize() && defaults.data(forKey: Self.storageKey) == data
    }

    @discardableResult
    func clear() -> Bool {
        defaults.removeObject(forKey: Self.storageKey)
        return defaults.synchronize() && defaults.data(forKey: Self.storageKey) == nil
    }
}

/// Keeps the latest keystroke in memory immediately; disk writes can be
/// debounced for IME responsiveness and explicitly flushed before app quit.
@MainActor
final class TimePlanningDraftCoordinator {
    static let shared = TimePlanningDraftCoordinator()

    private let cache: TimePlanningDraftCache
    private var staged: TimePlanningDraft?
    private var hasStagedChange = false

    init(defaults: UserDefaults = AppEnvironment.defaults) {
        cache = TimePlanningDraftCache(defaults: defaults)
    }

    func stage(_ draft: TimePlanningDraft?) {
        staged = draft
        hasStagedChange = true
    }

    @discardableResult
    func flush() -> Bool {
        guard hasStagedChange else { return true }
        let saved = staged.map(cache.save) ?? cache.clear()
        if saved { hasStagedChange = false }
        return saved
    }
}

enum TimePlanningDraftStatus {
    static func canSwitchGoal(actionDraft: String) -> Bool {
        actionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func estimateHasChanges(_ raw: String, comparedTo saved: Int?) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return saved != nil }
        guard let value = Int(trimmed), (1...600).contains(value) else { return true }
        return value != saved
    }
}
