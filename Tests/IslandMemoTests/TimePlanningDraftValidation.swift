import Foundation

@main
struct TimePlanningDraftValidation {
    private static func require(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }

    static func main() throws {
        try restoresEveryFieldAcrossCacheInstances()
        try olderDraftStillDecodesAfterCaptureFields()
        try clearRemovesOnlyTheDedicatedDraft()
        try malformedDataIsLeftByteForByteUntouched()
        estimateDraftKeepsInvalidText()
        changingFocusNeverReassignsAnUnsentAction()
        try stagedDraftFlushesOnImmediateQuit()
        print("PASS: time planning draft round trip, clear, malformed Data, invalid estimate and immediate quit flush")
    }

    private static func isolatedDefaults(_ name: String) -> (String, UserDefaults) {
        let suite = "local.paul.time-planning-draft-test.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (suite, defaults)
    }

    private static func restoresEveryFieldAcrossCacheInstances() throws {
        let (suite, defaults) = isolatedDefaults("roundtrip")
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = TimePlanningDraftCache(defaults: defaults)
        require(cache.load() == nil, "Fresh cache has no draft")

        var draft = TimePlanningDraft()
        draft.selectedDate = Date(timeIntervalSince1970: 1_777_777_777.125)
        draft.pageRaw = "week"
        draft.weekDraft = "本周写完简历初稿 📝"
        draft.goalDraft = "符合愿景的工作 🌱"
        draft.projectDraft = "小组 MVP / 个人作品"
        draft.newProjectGoalID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        draft.editingTaskID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        draft.stepDraft = "写清我负责的功能、取舍和结果"
        draft.estimateDraft = "90"
        draft.hasStartTime = true
        draft.startTime = Date(timeIntervalSince1970: 1_777_778_888.75)
        draft.editingGoalID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        draft.editingProjectID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        draft.goalRenameDraft = "更明确的职业方向"
        draft.projectRenameDraft = "简历和面试准备"
        draft.captureDraft = "我想先把现状完整写出来。"
        draft.captureTitleDraft = "找到合适的工作"
        draft.captureTargetDate = Date(timeIntervalSince1970: 1_777_779_999)
        draft.captureGoalID = UUID()
        draft.captureActionDraft = "列出项目数据的出处"
        draft.captureActionID = UUID()

        require(cache.save(draft), "Draft can be saved")
        let reopened = TimePlanningDraftCache(defaults: UserDefaults(suiteName: suite)!)
        require(reopened.load() == draft, "Every Unicode, Date, UUID and form field survives another cache instance")
        require(defaults.data(forKey: TimePlanningDraftCache.storageKey) != nil, "Draft uses its dedicated settings key")
    }

    private static func olderDraftStillDecodesAfterCaptureFields() throws {
        let legacy = TimePlanningDraft()
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
        object.removeValue(forKey: "captureDraft")
        object.removeValue(forKey: "captureTitleDraft")
        object.removeValue(forKey: "captureTargetDate")
        object.removeValue(forKey: "captureGoalID")
        object.removeValue(forKey: "captureActionDraft")
        object.removeValue(forKey: "captureActionID")
        let decoded = try JSONDecoder().decode(TimePlanningDraft.self,
                                               from: JSONSerialization.data(withJSONObject: object))
        require(decoded.captureDraft == nil && decoded.captureTitleDraft == nil && decoded.captureTargetDate == nil,
                "A draft saved before capture existed still opens")
        require(decoded.captureGoalID == nil && decoded.captureActionDraft == nil && decoded.captureActionID == nil,
                "Older drafts need no action or selected goal")
    }

    private static func clearRemovesOnlyTheDedicatedDraft() throws {
        let (suite, defaults) = isolatedDefaults("clear")
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("untouched", forKey: "other-setting")
        let cache = TimePlanningDraftCache(defaults: defaults)
        var draft = TimePlanningDraft()
        draft.goalDraft = "可恢复草稿"
        require(cache.save(draft), "Seed draft before clear")
        cache.clear()
        require(TimePlanningDraftCache(defaults: UserDefaults(suiteName: suite)!).load() == nil, "Cleared draft does not return")
        require(defaults.data(forKey: TimePlanningDraftCache.storageKey) == nil, "Dedicated key is removed")
        require(defaults.string(forKey: "other-setting") == "untouched", "Other settings are preserved")
    }

    private static func malformedDataIsLeftByteForByteUntouched() throws {
        let (suite, defaults) = isolatedDefaults("corrupt")
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = Data("{invalid draft JSON".utf8)
        defaults.set(original, forKey: TimePlanningDraftCache.storageKey)
        let cache = TimePlanningDraftCache(defaults: defaults)
        require(cache.load() == nil, "Malformed draft is not decoded")
        require(TimePlanningDraftCache(defaults: UserDefaults(suiteName: suite)!).load() == nil, "Malformed draft stays unreadable across instances")
        require(defaults.data(forKey: TimePlanningDraftCache.storageKey) == original, "Failed decode never overwrites or deletes original bytes")
    }

    private static func estimateDraftKeepsInvalidText() {
        require(TimePlanningDraftStatus.estimateHasChanges("abc", comparedTo: nil),
                "Invalid nonempty estimate is unsaved even when no estimate was previously stored")
        require(TimePlanningDraftStatus.estimateHasChanges("0", comparedTo: nil),
                "Out-of-range numeric text is unsaved")
        require(!TimePlanningDraftStatus.estimateHasChanges("", comparedTo: nil),
                "Empty estimate matches missing value")
        require(!TimePlanningDraftStatus.estimateHasChanges(" 45 ", comparedTo: 45),
                "Equivalent valid numeric input is unchanged")
    }

    private static func changingFocusNeverReassignsAnUnsentAction() {
        require(!TimePlanningDraftStatus.canSwitchGoal(actionDraft: "列出项目数据"),
                "Switching goals cannot silently move a typed action to another goal")
        require(TimePlanningDraftStatus.canSwitchGoal(actionDraft: "  \n"),
                "Empty action input does not block goal selection")
    }

    @MainActor
    private static func stagedDraftFlushesOnImmediateQuit() throws {
        let (suite, defaults) = isolatedDefaults("quit")
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = TimePlanningDraftCoordinator(defaults: defaults)
        var draft = TimePlanningDraft()
        draft.goalDraft = "刚输入，还没到延迟保存时间"
        coordinator.stage(draft)
        require(TimePlanningDraftCache(defaults: defaults).load() == nil,
                "Debounced write has not yet happened")
        require(coordinator.flush(), "Termination can flush staged input immediately")
        require(TimePlanningDraftCache(defaults: defaults).load() == draft,
                "Fresh cache reopens the exact staged input")
        coordinator.stage(nil)
        require(coordinator.flush(), "Discard clears the staged draft")
        require(TimePlanningDraftCache(defaults: defaults).load() == nil,
                "Discarded input does not return")
    }
}
