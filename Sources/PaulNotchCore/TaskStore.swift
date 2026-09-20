import Foundation
import SwiftUI

@MainActor
final class TaskStore: ObservableObject {
    @Published private(set) var tasks: [TaskItem] = []
    @Published var errorMessage: String?
    @Published private(set) var focusAddRequest = 0
    @Published private(set) var resetMemoListRequest = 0
    @Published var memoEditingActive = false
    @Published private(set) var hasLoaded = false
    private var pendingMemoAdd = false
    var hasPendingMemoAddRequest: Bool { pendingMemoAdd }
    private var pendingSave: Task<Bool, Never>?

    private let repository: any TaskRepository

    init(repository: any TaskRepository) {
        self.repository = repository
    }

    var activeTasks: [TaskItem] {
        tasks.filter { $0.deletedAt == nil }.sorted {
            if $0.isCompleted != $1.isCompleted { return !$0.isCompleted }
            switch ($0.dueDate, $1.dueDate) {
            case let (left?, right?): return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return $0.createdAt > $1.createdAt
            }
        }
    }

    var deletedTasks: [TaskItem] {
        tasks.filter { $0.deletedAt != nil }.sorted {
            ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast)
        }
    }

    func load() {
        Task {
            do {
                tasks = try await repository.load()
                hasLoaded = true
            }
            catch { errorMessage = "读取任务失败：\(error.localizedDescription)" }
        }
    }

    func add(title: String, dueDate: Date?, priority: TaskPriority = .blue, categoryID: String? = nil) {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        tasks.append(TaskItem(title: cleaned, dueDate: dueDate, priority: priority, categoryID: categoryID))
        persist()
    }

    func requestAddFocus() {
        pendingMemoAdd = true
        focusAddRequest += 1
    }

    func consumeMemoAddRequest() -> Bool {
        guard pendingMemoAdd else { return false }
        pendingMemoAdd = false
        return true
    }

    func requestMemoListReset() {
        resetMemoListRequest += 1
    }

    func toggle(_ task: TaskItem) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index].isCompleted.toggle()
        persist()
    }

    func delete(_ task: TaskItem) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index].deletedAt = .now
        persist()
    }

    func restore(_ task: TaskItem) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index].deletedAt = nil
        persist()
    }

    func permanentlyDelete(_ task: TaskItem) {
        tasks.removeAll { $0.id == task.id }
        persist()
    }

    func emptyTrash() {
        tasks.removeAll { $0.deletedAt != nil }
        persist()
    }

    func updateTitle(_ task: TaskItem, title: String) {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty,
              let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index].title = cleaned
        persist()
    }

    func updateDueDate(_ task: TaskItem, dueDate: Date?) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index].dueDate = dueDate
        persist()
    }

    func updatePriority(_ task: TaskItem, priority: TaskPriority) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index].priority = priority
        persist()
    }

    func updateCategory(_ task: TaskItem, categoryID: String?) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index].categoryID = categoryID
        persist()
    }

    func addSubtask(to task: TaskItem, title: String) {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty,
              let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        if tasks[index].subtasks == nil { tasks[index].subtasks = [] }
        tasks[index].subtasks?.append(SubtaskItem(title: cleaned))
        persist()
    }

    func toggleSubtask(in task: TaskItem, subtask: SubtaskItem) {
        guard let taskIndex = tasks.firstIndex(where: { $0.id == task.id }),
              let subtaskIndex = tasks[taskIndex].subtasks?.firstIndex(where: { $0.id == subtask.id }) else { return }
        tasks[taskIndex].subtasks?[subtaskIndex].isCompleted.toggle()
        persist()
    }

    func deleteSubtask(from task: TaskItem, subtask: SubtaskItem) {
        guard let taskIndex = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[taskIndex].subtasks?.removeAll { $0.id == subtask.id }
        persist()
    }

    func updateSubtaskDueDate(in task: TaskItem, subtask: SubtaskItem, dueDate: Date?) {
        guard let taskIndex = tasks.firstIndex(where: { $0.id == task.id }),
              let subtaskIndex = tasks[taskIndex].subtasks?.firstIndex(where: { $0.id == subtask.id }) else { return }
        tasks[taskIndex].subtasks?[subtaskIndex].dueDate = dueDate
        persist()
    }

    func updateSubtaskPriority(in task: TaskItem, subtask: SubtaskItem, priority: TaskPriority) {
        guard let taskIndex = tasks.firstIndex(where: { $0.id == task.id }),
              let subtaskIndex = tasks[taskIndex].subtasks?.firstIndex(where: { $0.id == subtask.id }) else { return }
        tasks[taskIndex].subtasks?[subtaskIndex].priority = priority
        persist()
    }

    /// A stable draft ID makes retries idempotent, including recovery after a restart.
    func saveDetails(id: UUID, title: String, notes: String, dueDate: Date?,
                     priority: TaskPriority, categoryID: String?, subtasks: [SubtaskItem]? = nil) async -> Bool {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasLoaded, !cleaned.isEmpty else {
            errorMessage = hasLoaded ? "请填写任务标题" : "任务尚未读取成功，请稍后重试"
            return false
        }
        let index: Int
        if let existing = tasks.firstIndex(where: { $0.id == id }) {
            guard tasks[existing].deletedAt == nil else {
                errorMessage = "此任务已在回收站，请先恢复"
                return false
            }
            index = existing
        } else {
            tasks.append(TaskItem(id: id, title: cleaned))
            index = tasks.count - 1
        }
        tasks[index].title = cleaned
        tasks[index].notes = notes
        tasks[index].dueDate = dueDate
        tasks[index].priority = priority
        tasks[index].categoryID = categoryID
        if let subtasks { tasks[index].subtasks = subtasks }
        tasks[index].updatedAt = .now
        tasks[index].schemaVersion = 2
        return await persist().value
    }

    @discardableResult
    private func persist() -> Task<Bool, Never> {
        let snapshot = tasks
        let previous = pendingSave
        let save = Task { @MainActor in
            _ = await previous?.value
            do {
                try await repository.save(snapshot)
                return true
            } catch {
                errorMessage = "保存任务失败：\(error.localizedDescription)"
                return false
            }
        }
        pendingSave = save
        return save
    }
}
