import Foundation

private actor RecordingTaskRepository: TaskRepository {
    var saved: [[TaskItem]] = []
    var shouldFail = false
    func load() async throws -> [TaskItem] { [] }
    func save(_ tasks: [TaskItem]) async throws {
        try await Task.sleep(for: .milliseconds(10))
        if shouldFail { throw CocoaError(.fileWriteNoPermission) }
        saved.append(tasks)
    }
    func setFailure(_ value: Bool) { shouldFail = value }
    func latest() -> [TaskItem] { saved.last ?? [] }
}

@main
struct MemoTaskDetailsValidation {
    static func require(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }

    @MainActor
    static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("memo-details-validation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("tasks.json")
        let legacy = Data("""
        [{"id":"00000000-0000-0000-0000-000000000001","title":"旧任务","isCompleted":false,"createdAt":"2026-09-05T00:00:00Z","subtasks":[{"id":"00000000-0000-0000-0000-000000000002","title":"原有步骤","isCompleted":true,"createdAt":"2026-09-05T00:00:00Z"}]}]
        """.utf8)
        try legacy.write(to: file, options: .atomic)
        let repository = LocalTaskRepository(fileURL: file)
        var loaded = try await repository.load()
        require(loaded.count == 1 && loaded[0].notes == nil, "Legacy decode")
        loaded[0].notes = "第一段\n第二段，中文说明"
        loaded[0].schemaVersion = 2
        loaded[0].updatedAt = .now
        try await repository.save(loaded)
        let reread = try await repository.load()
        require(reread.count == 1 && reread[0].subtasks?.count == 1, "Counts preserved")
        require(reread[0].notes == loaded[0].notes && reread[0].schemaVersion == 2, "Multiline v2 round trip")
        let backup = folder.appendingPathComponent("tasks-before-details-v2.json")
        require(try Data(contentsOf: backup) == legacy, "Exact rollback backup")
        try await repository.save([])
        require(try Data(contentsOf: backup) == legacy, "Backup never overwritten")
        try Data(contentsOf: backup).write(to: file, options: .atomic)
        require(try await repository.load().count == 1, "Rollback restores count")

        let fake = RecordingTaskRepository()
        let store = TaskStore(repository: fake)
        store.load()
        while !store.hasLoaded { try await Task.sleep(for: .milliseconds(5)) }
        store.requestAddFocus()
        require(store.hasPendingMemoAddRequest, "Home observes pending add without consuming it")
        require(store.consumeMemoAddRequest(), "Unmounted workspace can consume pending add")
        require(!store.hasPendingMemoAddRequest, "Consumed add no longer opens Home editor")
        require(!store.consumeMemoAddRequest(), "Add intent consumed exactly once")
        let id = UUID()
        await fake.setFailure(true)
        let failed = await store.saveDetails(id: id, title: "草稿", notes: "两段\n保留", dueDate: nil, priority: .blue, categoryID: nil)
        require(!failed && store.tasks.count == 1, "Failure is visible")
        await fake.setFailure(false)
        let success = await store.saveDetails(id: id, title: "重试", notes: "两段\n保留", dueDate: nil, priority: .blue, categoryID: nil)
        require(success && store.tasks.count == 1, "Stable ID prevents duplicate retry")
        store.updateTitle(store.tasks[0], title: "较早修改")
        let last = await store.saveDetails(id: id, title: "最新修改", notes: "保留正文", dueDate: nil, priority: .red, categoryID: nil)
        require(last, "Last write succeeds")
        require(await fake.latest().first?.title == "最新修改", "Queued writes preserve final order")
        require(await fake.latest().first?.notes == "保留正文", "Queued writes retain notes")
        let step = SubtaskItem(title: "创建时添加步骤", isCompleted: true, dueDate: .now, priority: .orange)
        let together = await store.saveDetails(id: id, title: "完整任务", notes: "一起保存", dueDate: nil,
            priority: .blue, categoryID: "daily", subtasks: [step])
        require(together, "Task with steps saves")
        require(await fake.latest().first?.subtasks == [step], "Step metadata persists with details")
        _ = await store.saveDetails(id: id, title: "旧调用方", notes: "", dueDate: nil, priority: .blue, categoryID: nil)
        require(await fake.latest().first?.subtasks == [step], "Omitted steps preserve existing steps")
        await fake.setFailure(true)
        let failedSteps = await store.saveDetails(id: id, title: "重试步骤", notes: "", dueDate: nil,
            priority: .blue, categoryID: nil, subtasks: [])
        let durableAfterFailure = await fake.latest()
        require(!failedSteps && durableAfterFailure.first?.subtasks == [step], "Failed save preserves durable steps")
        await fake.setFailure(false)
        _ = await store.saveDetails(id: id, title: "重试步骤", notes: "", dueDate: nil, priority: .blue, categoryID: nil, subtasks: [])
        require(await fake.latest().first?.subtasks == [], "Explicit empty steps removes them on successful retry")
        print("PASS: details compatibility, backup/rollback, retry, ordered saves, create intent, unified subtask saving")
        print("Disposable fixtures: \(folder.path)")
    }
}
