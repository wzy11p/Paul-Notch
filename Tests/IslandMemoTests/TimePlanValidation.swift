import Foundation

@main
struct TimePlanValidation {
    private static func require(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }

    @MainActor
    static func main() async throws {
        try await calendarKeysCrossMidnightAndYear()
        try goalContextAndTargetDayRoundTrip()
        try await freeformCaptureKeepsOriginalWords()
        try await explicitCaptureAndGoalActionSurviveRestart()
        try await dayCapacityIsOptionalAndNeverInventsUnknownEstimates()
        try await changesSurviveRestartWithoutCopyingTasks()
        try await deletionKeepsTaskPlans()
        try await malformedDataStaysUntouched()
        try await failedWriteDoesNotPublishAndCanRetry()
        try await concurrentWritesFlushInOrder()
        print("PASS: time planning dates, user catalog, task references, restart, deletion, corrupt data, failed write, flush")
    }

    private static func fixture(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("paul-time-plan-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func goalContextAndTargetDayRoundTrip() throws {
        let id = UUID()
        let context = "一周内准备面试。简历初版已完成；项目介绍和数据待整理。"
        let payload = """
        {"schemaVersion":1,"goals":[{"id":"\(id.uuidString)","title":"准备面试","brief":"\(context)","targetDay":"2026-10-04"}],"projects":[],"taskPlans":{},"weeklyFocus":{}}
        """
        let decoder = JSONDecoder()
        let loaded = try decoder.decode(TimePlanDocument.self, from: Data(payload.utf8))
        try loaded.validate()
        let encoded = try JSONEncoder().encode(loaded)
        let json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        let goals = json["goals"] as! [[String: Any]]
        require(goals[0]["brief"] as? String == context,
                "A captured goal retains the owner's original wording across a save")
        require(goals[0]["targetDay"] as? String == "2026-10-04",
                "A goal's target day survives independently of task due dates")

        let invalidPayload = payload.replacingOccurrences(of: "2026-10-04", with: "2026-02-30")
        let invalid = try decoder.decode(TimePlanDocument.self, from: Data(invalidPayload.utf8))
        do {
            try invalid.validate()
            preconditionFailure("An impossible goal target day must be rejected")
        } catch {
            // The invalid document must not be eligible for a repository write.
        }
    }

    @MainActor
    private static func freeformCaptureKeepsOriginalWords() async throws {
        let directory = try fixture("goal-capture")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("time-plan-v1.json")
        let store = TimePlanStore(repository: LocalTimePlanRepository(fileURL: file))
        await store.load()
        let raw = "准备面试。简历初版已完成，项目介绍未完成，数据未完成；希望一周内准备好。"
        require(await store.addGoal(title: raw), "Capture the user's paragraph as a goal")
        require(store.document.goals.count == 1, "One capture creates one goal")
        require(store.document.goals[0].title == "准备面试", "A long capture gets a compact editable title")
        require(store.document.goals[0].brief == raw, "The original paragraph is retained verbatim")
        let reopened = TimePlanStore(repository: LocalTimePlanRepository(fileURL: file))
        await reopened.load()
        require(reopened.document.goals[0].brief == raw, "The captured wording survives restart")
    }

    @MainActor
    private static func explicitCaptureAndGoalActionSurviveRestart() async throws {
        let directory = try fixture("goal-action")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("time-plan-v1.json")
        let store = TimePlanStore(repository: LocalTimePlanRepository(fileURL: file))
        await store.load()
        let original = "先把所有想到的事倒进来。简历已有初版，项目和数据还没整理。"
        require(await store.addGoal(title: "准备面试", brief: original, targetDay: "2026-10-04"),
                "A named goal can retain the original intake and target day")
        let goalID = store.document.goals[0].id
        require(store.document.goals[0].brief == original && store.document.goals[0].targetDay == "2026-10-04",
                "User-authored context and chosen date are not inferred away")
        require(await store.setFocusGoal(id: goalID), "The owner can choose the one goal to foreground")
        require(store.document.focusGoalID == goalID, "The chosen focus is visible")
        let taskID = UUID()
        require(await store.assignTaskToGoal(taskID: taskID, goalID: goalID),
                "A concrete next action can link directly to its goal without a project")
        require(await store.planTask(taskID: taskID, dayKey: "2026-09-27"), "Schedule that action")
        require(await store.setFocusTask(id: taskID), "One action can be marked as the current next step")
        require(!(await store.setFocusTask(id: UUID())), "Unknown actions cannot become the focus")
        let reopened = TimePlanStore(repository: LocalTimePlanRepository(fileURL: file))
        await reopened.load()
        require(reopened.document.focusGoalID == goalID, "Chosen focus survives restart")
        require(reopened.document.focusTaskID == taskID, "Current next step survives restart")
        require(reopened.document.taskPlans[taskID]?.goalID == goalID,
                "The action-goal link survives restart")
        require(!(await reopened.assignTaskToGoal(taskID: taskID, goalID: UUID())),
                "An unknown goal cannot be referenced")
        require(reopened.document.taskPlans[taskID]?.goalID == goalID,
                "A failed relink preserves the prior association")
        require(await reopened.deleteGoal(id: goalID), "The goal can still be deleted")
        require(reopened.document.focusGoalID == nil, "Deleting the focused goal clears only the focus pointer")
        require(reopened.document.taskPlans[taskID]?.goalID == nil &&
                reopened.document.taskPlans[taskID]?.plannedDay == "2026-09-27",
                "Deleting a goal detaches but never destroys its action")
        require(await reopened.unplanTask(taskID: taskID), "The focused action can be removed from the day")
        require(reopened.document.focusTaskID == nil, "Removing its plan clears the current-action marker")
    }

    @MainActor
    private static func dayCapacityIsOptionalAndNeverInventsUnknownEstimates() async throws {
        let directory = try fixture("capacity")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("time-plan-v1.json")
        let store = TimePlanStore(repository: LocalTimePlanRepository(fileURL: file))
        await store.load()
        require(store.document.dailyCapacityMinutes.isEmpty, "Old planning documents have no invented capacity")
        require(await store.setDailyCapacity(dayKey: "2026-09-27", minutes: 240), "Owner can set four hours")
        require(!(await store.setDailyCapacity(dayKey: "2026-09-27", minutes: 0)), "Zero is not a capacity")
        let first = UUID(), second = UUID()
        require(await store.planTask(taskID: first, dayKey: "2026-09-27"), "Plan estimated task")
        require(await store.setTaskDetails(taskID: first, nextStep: nil, estimatedMinutes: 90, startMinute: nil),
                "Estimate the first task")
        require(await store.planTask(taskID: second, dayKey: "2026-09-27"), "Plan unknown-duration task")
        let load = TimePlanningLoad(dayKey: "2026-09-27", taskIDs: [first, second], document: store.document)
        require(load.estimatedMinutes == 90 && load.unestimatedCount == 1 && load.capacityMinutes == 240,
                "Unknown duration is counted as unknown, never zero effort")
        require(!load.isKnownOverCapacity, "Partial estimates alone cannot claim overbooking")
        let reopened = TimePlanStore(repository: LocalTimePlanRepository(fileURL: file))
        await reopened.load()
        require(reopened.document.dailyCapacityMinutes["2026-09-27"] == 240, "Capacity survives restart")
        require(await reopened.setDailyCapacity(dayKey: "2026-09-27", minutes: nil), "Capacity can be cleared")
        require(reopened.document.dailyCapacityMinutes.isEmpty, "Clearing does not leave a stale budget")
    }

    private static func calendarKeysCrossMidnightAndYear() async throws {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
        let beforeMidnight = Date(timeIntervalSince1970: 1_767_196_600) // 2025-12-31 15:56:40 UTC
        let afterMidnight = beforeMidnight.addingTimeInterval(3_600)
        require(TimePlanDay.key(for: beforeMidnight, calendar: local) == "2025-12-31", "Local date before midnight")
        require(TimePlanDay.key(for: afterMidnight, calendar: local) == "2026-01-01", "Local date after midnight")
        require(TimePlanDay.weekKey(for: beforeMidnight, calendar: local) == "2026-W01", "ISO week-year differs from date year")
        require(TimePlanDay.weekKey(for: afterMidnight, calendar: local) == "2026-W01", "ISO week remains stable over New Year")
    }

    @MainActor
    private static func changesSurviveRestartWithoutCopyingTasks() async throws {
        let directory = try fixture("restart")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("time-plan-v1.json")
        let store = TimePlanStore(repository: LocalTimePlanRepository(fileURL: file))
        await store.load()
        require(store.isLoaded && store.document.goals.isEmpty, "Missing file starts an empty plan")

        require(await store.addGoal(title: "  找到合适的工作 🌱  "), "Add Unicode goal")
        let goalID = store.document.goals[0].id
        require(store.document.goals[0].title == "找到合适的工作 🌱", "Goal title is trimmed")
        require(await store.renameGoal(id: goalID, title: "职业方向 🌱"), "Rename goal")
        require(await store.addProject(title: "  简历与面试  ", goalID: goalID), "Add project")
        let projectID = store.document.projects[0].id
        require(await store.renameProject(id: projectID, title: "简历、问候语、面试"), "Rename project")
        require(await store.addGoal(title: "个人项目"), "Add another goal")
        let secondGoalID = store.document.goals[1].id
        require(await store.setProjectGoal(projectID: projectID, goalID: secondGoalID), "Move project between goals")

        let taskID = UUID()
        require(await store.assignTask(taskID: taskID, projectID: projectID), "Assign existing task ID")
        require(await store.planTask(taskID: taskID, dayKey: "2026-01-01"), "Plan task for a local day")
        require(await store.setTaskDetails(taskID: taskID, nextStep: "  写清 MVP 中我的贡献  ", estimatedMinutes: 90, startMinute: 9 * 60 + 30), "Set next step and optional timing")
        require(await store.setWeeklyFocus(weekKey: "2026-W01", text: "  完成简历初稿，发给组长 📝  "), "Set weekly focus")
        require(store.document.taskPlans[taskID]?.nextStep == "写清 MVP 中我的贡献", "Task plan retains normalized next step")
        require(store.document.taskPlans[taskID]?.plannedDay == "2026-01-01", "Task plan records a day separately from deadline")
        require(store.document.weeklyFocus["2026-W01"] == "完成简历初稿，发给组长 📝", "Weekly focus retains Unicode")

        let beforeInvalid = try Data(contentsOf: file)
        let priorDocument = store.document
        require(!(await store.planTask(taskID: taskID, dayKey: "2026-02-30")), "Reject nonexistent calendar date")
        require(!(await store.setTaskDetails(taskID: taskID, nextStep: nil, estimatedMinutes: 0, startMinute: 1_440)), "Reject nonpositive estimate and out-of-day start")
        require(!(await store.assignTask(taskID: taskID, projectID: UUID())), "Reject unknown project ID")
        require(!(await store.setWeeklyFocus(weekKey: "2026-W99", text: "无效")), "Reject invalid week")
        let afterInvalid = try Data(contentsOf: file)
        require(store.document == priorDocument && afterInvalid == beforeInvalid, "Invalid edits leave memory and disk unchanged")

        let reopened = TimePlanStore(repository: LocalTimePlanRepository(fileURL: file))
        await reopened.load()
        require(reopened.isLoaded && reopened.document == priorDocument, "Entire plan survives process-style reload")
        require(reopened.document.taskPlans.count == 1 && reopened.document.taskPlans[taskID]?.taskID == taskID, "Only a task UUID reference is stored")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        require(json?["tasks"] == nil && json?["taskPlans"] != nil, "Planning document does not become another task repository")
        require(await reopened.unplanTask(taskID: taskID), "Unplan task")
        require(reopened.document.taskPlans[taskID]?.plannedDay == nil && reopened.document.taskPlans[taskID]?.startMinute == nil, "Unplanning clears calendar placement")
        require(reopened.document.taskPlans[taskID]?.projectID == projectID && reopened.document.taskPlans[taskID]?.nextStep == "写清 MVP 中我的贡献", "Unplanning retains project and next step")
    }

    @MainActor
    private static func deletionKeepsTaskPlans() async throws {
        let directory = try fixture("deletion")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("time-plan-v1.json")
        let store = TimePlanStore(repository: LocalTimePlanRepository(fileURL: file))
        await store.load()
        require(await store.addGoal(title: "求职"), "Create goal for deletion test")
        let goalID = store.document.goals[0].id
        require(await store.addProject(title: "简历", goalID: goalID), "Create project for deletion test")
        let projectID = store.document.projects[0].id
        let taskID = UUID()
        require(await store.assignTask(taskID: taskID, projectID: projectID), "Assign task before deletion")
        require(await store.planTask(taskID: taskID, dayKey: "2026-09-26"), "Place task before deletion")
        require(await store.deleteGoal(id: goalID), "Delete goal")
        require(store.document.projects[0].goalID == nil, "Deleting goal detaches its projects")
        require(store.document.taskPlans[taskID]?.projectID == projectID, "Deleting goal preserves task/project link")
        require(await store.deleteProject(id: projectID), "Delete project")
        require(store.document.taskPlans[taskID]?.projectID == nil, "Deleting project detaches task plan")
        require(store.document.taskPlans[taskID]?.plannedDay == "2026-09-26", "Deleting project keeps planned date")
        let reopened = TimePlanStore(repository: LocalTimePlanRepository(fileURL: file))
        await reopened.load()
        require(reopened.document.taskPlans[taskID]?.plannedDay == "2026-09-26", "Detached task plan survives restart")
    }

    @MainActor
    private static func malformedDataStaysUntouched() async throws {
        let directory = try fixture("corrupt")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("time-plan-v1.json")
        let corruptBytes = Data("{not valid json".utf8)
        try corruptBytes.write(to: file)
        let store = TimePlanStore(repository: LocalTimePlanRepository(fileURL: file))
        await store.load()
        require(!store.isLoaded && store.errorMessage != nil, "Malformed plan reports a load error")
        require(await store.flushPendingWrites(), "Read failure has no unsaved write and permits safe quit")
        require(!(await store.addGoal(title: "不可覆盖")), "Unloaded store refuses mutation")
        require(try Data(contentsOf: file) == corruptBytes, "Malformed file stays byte-identical")
    }

    @MainActor
    private static func failedWriteDoesNotPublishAndCanRetry() async throws {
        let directory = try fixture("failed-write")
        defer { try? FileManager.default.removeItem(at: directory) }
        let blockedParent = directory.appendingPathComponent("blocked")
        try Data("regular file".utf8).write(to: blockedParent)
        let file = blockedParent.appendingPathComponent("time-plan-v1.json")
        let store = TimePlanStore(repository: LocalTimePlanRepository(fileURL: file))
        await store.load()
        require(store.isLoaded, "Missing child file permits an empty document")
        let before = store.document
        require(!(await store.addGoal(title: "未落盘")), "Write through regular-file parent fails")
        require(store.document == before && !store.isSaving, "Failed write does not publish candidate document")
        let failedFlush = await store.flushPendingWrites()
        require(store.errorMessage != nil && !failedFlush, "Flush reports failed save")
        try FileManager.default.removeItem(at: blockedParent)
        try FileManager.default.createDirectory(at: blockedParent, withIntermediateDirectories: false)
        require(await store.addGoal(title: "已落盘"), "Retry succeeds after path recovers")
        require(store.document.goals.map(\.title) == ["已落盘"], "Failed candidate was not merged into retry")
        require(await store.flushPendingWrites(), "Flush clears earlier failure after successful retry")
    }

    @MainActor
    private static func concurrentWritesFlushInOrder() async throws {
        let directory = try fixture("flush")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("time-plan-v1.json")
        let store = TimePlanStore(repository: LocalTimePlanRepository(fileURL: file))
        await store.load()
        let first = Task { await store.setWeeklyFocus(weekKey: "2026-W39", text: "第一周") }
        let second = Task { await store.setWeeklyFocus(weekKey: "2026-W40", text: "第二周") }
        _ = await first.value
        require(await store.flushPendingWrites(), "Flush waits for queued writes")
        require(await second.value, "Second write succeeds")
        let onDisk = try await LocalTimePlanRepository(fileURL: file).load()
        require(onDisk == store.document && onDisk.weeklyFocus.count == 2, "Disk matches final in-memory state after overlapping calls")
    }
}
