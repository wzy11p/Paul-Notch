import Foundation
import SwiftUI

struct TimePlanGoal: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    /// The owner's original description remains available when a plan is revised.
    var brief: String?
    /// A desired result date, separate from any task due date or planned work day.
    var targetDay: String?

    init(id: UUID = UUID(), title: String, brief: String? = nil, targetDay: String? = nil) {
        self.id = id
        self.title = title
        self.brief = brief
        self.targetDay = targetDay
    }
}

struct TimePlanProject: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    var goalID: UUID?

    init(id: UUID = UUID(), title: String, goalID: UUID? = nil) {
        self.id = id
        self.title = title
        self.goalID = goalID
    }
}

/// Only a task's ID and planning metadata live here. Task content remains in TaskStore.
struct TimeTaskPlan: Codable, Equatable, Sendable {
    let taskID: UUID
    /// A task can serve a goal directly; a project is never required just to plan today.
    var goalID: UUID?
    var projectID: UUID?
    var plannedDay: String?
    var nextStep: String?
    var estimatedMinutes: Int?
    /// Minutes after local midnight; nil means no precise starting time.
    var startMinute: Int?

    init(taskID: UUID, goalID: UUID? = nil, projectID: UUID? = nil, plannedDay: String? = nil,
         nextStep: String? = nil, estimatedMinutes: Int? = nil, startMinute: Int? = nil) {
        self.taskID = taskID
        self.goalID = goalID
        self.projectID = projectID
        self.plannedDay = plannedDay
        self.nextStep = nextStep
        self.estimatedMinutes = estimatedMinutes
        self.startMinute = startMinute
    }
}

struct TimePlanDocument: Codable, Equatable, Sendable {
    let schemaVersion: Int
    var goals: [TimePlanGoal]
    var projects: [TimePlanProject]
    var taskPlans: [UUID: TimeTaskPlan]
    var weeklyFocus: [String: String]
    /// Optional owner-estimated focus time for a day. Missing is unknown, not zero.
    var dailyCapacityMinutes: [String: Int]
    /// Owner-selected attention, not an algorithmically inferred priority.
    var focusGoalID: UUID?
    /// One explicitly selected next action; never inferred from a task count.
    var focusTaskID: UUID?

    init(schemaVersion: Int = 1, goals: [TimePlanGoal] = [], projects: [TimePlanProject] = [],
         taskPlans: [UUID: TimeTaskPlan] = [:], weeklyFocus: [String: String] = [:],
         dailyCapacityMinutes: [String: Int] = [:], focusGoalID: UUID? = nil,
         focusTaskID: UUID? = nil) {
        self.schemaVersion = schemaVersion
        self.goals = goals
        self.projects = projects
        self.taskPlans = taskPlans
        self.weeklyFocus = weeklyFocus
        self.dailyCapacityMinutes = dailyCapacityMinutes
        self.focusGoalID = focusGoalID
        self.focusTaskID = focusTaskID
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, goals, projects, taskPlans, weeklyFocus, dailyCapacityMinutes, focusGoalID, focusTaskID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        goals = try container.decode([TimePlanGoal].self, forKey: .goals)
        projects = try container.decode([TimePlanProject].self, forKey: .projects)
        weeklyFocus = try container.decode([String: String].self, forKey: .weeklyFocus)
        dailyCapacityMinutes = try container.decodeIfPresent([String: Int].self, forKey: .dailyCapacityMinutes) ?? [:]
        focusGoalID = try container.decodeIfPresent(UUID.self, forKey: .focusGoalID)
        focusTaskID = try container.decodeIfPresent(UUID.self, forKey: .focusTaskID)
        let keyedPlans = try container.decode([String: TimeTaskPlan].self, forKey: .taskPlans)
        var plans: [UUID: TimeTaskPlan] = [:]
        for (key, plan) in keyedPlans {
            guard let id = UUID(uuidString: key), id == plan.taskID else {
                throw TimePlanFailure.invalidDocument("任务引用不一致")
            }
            plans[id] = plan
        }
        taskPlans = plans
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(goals, forKey: .goals)
        try container.encode(projects, forKey: .projects)
        try container.encode(weeklyFocus, forKey: .weeklyFocus)
        try container.encode(dailyCapacityMinutes, forKey: .dailyCapacityMinutes)
        try container.encodeIfPresent(focusGoalID, forKey: .focusGoalID)
        try container.encodeIfPresent(focusTaskID, forKey: .focusTaskID)
        let keyedPlans = Dictionary(uniqueKeysWithValues: taskPlans.map { ($0.key.uuidString, $0.value) })
        try container.encode(keyedPlans, forKey: .taskPlans)
    }

    func validate() throws {
        guard schemaVersion == 1 else { throw TimePlanFailure.invalidDocument("不支持的规划版本") }
        let goalIDs = Set(goals.map(\.id))
        let projectIDs = Set(projects.map(\.id))
        guard goalIDs.count == goals.count, projectIDs.count == projects.count,
              focusGoalID == nil || goalIDs.contains(focusGoalID!),
              goals.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              goals.allSatisfy({ $0.brief == nil || $0.brief!.count <= 20_000 }),
              goals.allSatisfy({ $0.targetDay == nil || TimePlanDay.isValidDayKey($0.targetDay!) }),
              projects.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              projects.allSatisfy({ $0.goalID == nil || goalIDs.contains($0.goalID!) }) else {
            throw TimePlanFailure.invalidDocument("目标或项目数据无效")
        }
        for (id, plan) in taskPlans {
            guard id == plan.taskID,
                  plan.goalID == nil || goalIDs.contains(plan.goalID!),
                  plan.projectID == nil || projectIDs.contains(plan.projectID!),
                  plan.plannedDay == nil || TimePlanDay.isValidDayKey(plan.plannedDay!),
                  plan.estimatedMinutes == nil || plan.estimatedMinutes! > 0,
                  plan.startMinute == nil || ((0..<1_440).contains(plan.startMinute!) && plan.plannedDay != nil) else {
                throw TimePlanFailure.invalidDocument("任务规划数据无效")
            }
        }
        guard focusTaskID == nil || taskPlans[focusTaskID!]?.plannedDay != nil else {
            throw TimePlanFailure.invalidDocument("当前动作不在计划中")
        }
        guard weeklyFocus.allSatisfy({ TimePlanDay.isValidWeekKey($0.key) }) else {
            throw TimePlanFailure.invalidDocument("周重点日期无效")
        }
        guard dailyCapacityMinutes.allSatisfy({ TimePlanDay.isValidDayKey($0.key) && (1...1_440).contains($0.value) }) else {
            throw TimePlanFailure.invalidDocument("每日可用时间无效")
        }
    }
}

/// Known estimates remain separate from tasks without an estimate.
struct TimePlanningLoad {
    let capacityMinutes: Int?
    let estimatedMinutes: Int
    let unestimatedCount: Int

    init(dayKey: String, taskIDs: [UUID], document: TimePlanDocument) {
        capacityMinutes = document.dailyCapacityMinutes[dayKey]
        let plans = taskIDs.compactMap { document.taskPlans[$0] }.filter { $0.plannedDay == dayKey }
        estimatedMinutes = plans.compactMap(\.estimatedMinutes).reduce(0, +)
        unestimatedCount = plans.filter { $0.estimatedMinutes == nil }.count
    }

    var isKnownOverCapacity: Bool {
        guard let capacityMinutes else { return false }
        return estimatedMinutes > capacityMinutes
    }
}

enum TimePlanDay {
    static func key(for date: Date, calendar: Calendar = .current) -> String {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = calendar.timeZone
        let components = local.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
    }

    static func weekKey(for date: Date, calendar: Calendar = .current) -> String {
        var local = Calendar(identifier: .iso8601)
        local.timeZone = calendar.timeZone
        let components = local.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return String(format: "%04d-W%02d", components.yearForWeekOfYear!, components.weekOfYear!)
    }

    static func isValidDayKey(_ key: String) -> Bool {
        let bytes = Array(key.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45,
              bytes.enumerated().allSatisfy({ index, value in index == 4 || index == 7 || (48...57).contains(value) }),
              let year = Int(key.prefix(4)), let month = Int(key.dropFirst(5).prefix(2)),
              let day = Int(key.suffix(2)), (1...9_999).contains(year) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return false }
        let resolved = calendar.dateComponents([.year, .month, .day], from: date)
        return resolved.year == year && resolved.month == month && resolved.day == day
    }

    static func isValidWeekKey(_ key: String) -> Bool {
        let bytes = Array(key.utf8)
        guard bytes.count == 8, bytes[4] == 45, bytes[5] == 87,
              bytes.enumerated().allSatisfy({ index, value in index == 4 || index == 5 || (48...57).contains(value) }),
              let year = Int(key.prefix(4)), let week = Int(key.suffix(2)),
              (1...9_999).contains(year), (1...53).contains(week) else { return false }
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = DateComponents()
        components.yearForWeekOfYear = year
        components.weekOfYear = week
        components.weekday = 2
        guard let date = calendar.date(from: components) else { return false }
        let resolved = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return resolved.yearForWeekOfYear == year && resolved.weekOfYear == week
    }
}

private enum TimePlanFailure: LocalizedError {
    case invalidDocument(String)
    case invalidInput(String)
    case missing(String)
    case notLoaded

    var errorDescription: String? {
        switch self {
        case .invalidDocument(let detail): return detail
        case .invalidInput(let detail): return detail
        case .missing(let detail): return detail
        case .notLoaded: return "规划尚未成功读取，请先重试读取"
        }
    }
}

actor LocalTimePlanRepository {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? AppEnvironment.dataDirectory.appendingPathComponent("time-plan-v1.json")
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
    }

    func load() throws -> TimePlanDocument {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return TimePlanDocument() }
        let document = try decoder.decode(TimePlanDocument.self, from: Data(contentsOf: fileURL))
        try document.validate()
        return document
    }

    func save(_ document: TimePlanDocument) throws {
        try document.validate()
        // A corrupt or future-version file must never be silently replaced.
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let existing = try decoder.decode(TimePlanDocument.self, from: Data(contentsOf: fileURL))
            try existing.validate()
        }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(document).write(to: fileURL, options: .atomic)
    }
}

@MainActor
final class TimePlanStore: ObservableObject {
    @Published private(set) var document = TimePlanDocument()
    @Published private(set) var isLoaded = false
    @Published private(set) var isSaving = false
    @Published var errorMessage: String?
    @Published var isEditing = false

    private let repository: LocalTimePlanRepository
    private var pendingMutation: Task<Bool, Never>?
    private var queuedMutationCount = 0
    private var latestMutationID = 0
    private var hasFailedWrite = false

    init(repository: LocalTimePlanRepository) {
        self.repository = repository
    }

    func load() async {
        guard !isSaving else {
            errorMessage = "规划正在保存，请稍后读取"
            return
        }
        do {
            document = try await repository.load()
            isLoaded = true
            errorMessage = nil
        } catch {
            isLoaded = false
            errorMessage = "读取规划失败：\(error.localizedDescription)"
        }
    }

    func addGoal(title: String, brief: String? = nil, targetDay: String? = nil) async -> Bool {
        await change { document in
            let original = title
            let cleaned = try Self.cleanTitle(title)
            guard cleaned.count <= 20_000 else {
                throw TimePlanFailure.invalidInput("目标描述最多 20000 字")
            }
            guard brief == nil || brief!.count <= 20_000 else {
                throw TimePlanFailure.invalidInput("现状描述最多 20000 字")
            }
            guard targetDay == nil || TimePlanDay.isValidDayKey(targetDay!) else {
                throw TimePlanFailure.invalidInput("请选择有效的目标日期")
            }
            let breakIndex = cleaned.firstIndex { "。；.!?！？\n".contains($0) }
            let isNarrative = breakIndex != nil || cleaned.count > 48
            let prefix = breakIndex.map { String(cleaned[..<$0]) } ?? cleaned
            let proposedTitle = String(prefix.trimmingCharacters(in: .whitespacesAndNewlines).prefix(48))
            document.goals.append(TimePlanGoal(title: isNarrative && !proposedTitle.isEmpty ? proposedTitle : cleaned,
                                               brief: brief ?? (isNarrative ? original : nil),
                                               targetDay: targetDay))
        }
    }

    func renameGoal(id: UUID, title: String) async -> Bool {
        await change { document in
            guard let index = document.goals.firstIndex(where: { $0.id == id }) else {
                throw TimePlanFailure.missing("找不到目标")
            }
            document.goals[index].title = try Self.cleanTitle(title)
        }
    }

    func setFocusGoal(id: UUID?) async -> Bool {
        await change { document in
            try Self.requireGoal(id, in: document)
            document.focusGoalID = id
        }
    }

    func deleteGoal(id: UUID) async -> Bool {
        await change { document in
            guard document.goals.contains(where: { $0.id == id }) else {
                throw TimePlanFailure.missing("找不到目标")
            }
            document.goals.removeAll { $0.id == id }
            if document.focusGoalID == id { document.focusGoalID = nil }
            for index in document.projects.indices where document.projects[index].goalID == id {
                document.projects[index].goalID = nil
            }
            for taskID in Array(document.taskPlans.keys) where document.taskPlans[taskID]?.goalID == id {
                document.taskPlans[taskID]?.goalID = nil
            }
        }
    }

    func addProject(title: String, goalID: UUID? = nil) async -> Bool {
        await change { document in
            try Self.requireGoal(goalID, in: document)
            document.projects.append(TimePlanProject(title: try Self.cleanTitle(title), goalID: goalID))
        }
    }

    func renameProject(id: UUID, title: String) async -> Bool {
        await change { document in
            guard let index = document.projects.firstIndex(where: { $0.id == id }) else {
                throw TimePlanFailure.missing("找不到项目")
            }
            document.projects[index].title = try Self.cleanTitle(title)
        }
    }

    func setProjectGoal(projectID: UUID, goalID: UUID?) async -> Bool {
        await change { document in
            try Self.requireGoal(goalID, in: document)
            guard let index = document.projects.firstIndex(where: { $0.id == projectID }) else {
                throw TimePlanFailure.missing("找不到项目")
            }
            document.projects[index].goalID = goalID
        }
    }

    func deleteProject(id: UUID) async -> Bool {
        await change { document in
            guard document.projects.contains(where: { $0.id == id }) else {
                throw TimePlanFailure.missing("找不到项目")
            }
            document.projects.removeAll { $0.id == id }
            for taskID in Array(document.taskPlans.keys) where document.taskPlans[taskID]?.projectID == id {
                document.taskPlans[taskID]?.projectID = nil
            }
        }
    }

    func assignTask(taskID: UUID, projectID: UUID?) async -> Bool {
        await change { document in
            try Self.requireProject(projectID, in: document)
            var plan = document.taskPlans[taskID] ?? TimeTaskPlan(taskID: taskID)
            plan.projectID = projectID
            document.taskPlans[taskID] = plan
        }
    }

    func assignTaskToGoal(taskID: UUID, goalID: UUID?) async -> Bool {
        await change { document in
            try Self.requireGoal(goalID, in: document)
            var plan = document.taskPlans[taskID] ?? TimeTaskPlan(taskID: taskID)
            plan.goalID = goalID
            document.taskPlans[taskID] = plan
        }
    }

    func planTask(taskID: UUID, dayKey: String) async -> Bool {
        await change { document in
            guard TimePlanDay.isValidDayKey(dayKey) else {
                throw TimePlanFailure.invalidInput("请选择有效日期")
            }
            var plan = document.taskPlans[taskID] ?? TimeTaskPlan(taskID: taskID)
            plan.plannedDay = dayKey
            document.taskPlans[taskID] = plan
        }
    }

    func setFocusTask(id: UUID?) async -> Bool {
        await change { document in
            guard id == nil || document.taskPlans[id!]?.plannedDay != nil else {
                throw TimePlanFailure.missing("当前动作尚未安排到某一天")
            }
            document.focusTaskID = id
        }
    }

    func setTaskDetails(taskID: UUID, nextStep: String?, estimatedMinutes: Int?, startMinute: Int?) async -> Bool {
        await change { document in
            guard estimatedMinutes == nil || estimatedMinutes! > 0,
                  startMinute == nil || (0..<1_440).contains(startMinute!) else {
                throw TimePlanFailure.invalidInput("预计耗时或开始时间无效")
            }
            var plan = document.taskPlans[taskID] ?? TimeTaskPlan(taskID: taskID)
            guard startMinute == nil || plan.plannedDay != nil else {
                throw TimePlanFailure.invalidInput("请先选择计划日期")
            }
            let cleaned = nextStep?.trimmingCharacters(in: .whitespacesAndNewlines)
            plan.nextStep = cleaned?.isEmpty == true ? nil : cleaned
            plan.estimatedMinutes = estimatedMinutes
            plan.startMinute = startMinute
            document.taskPlans[taskID] = plan
        }
    }

    func unplanTask(taskID: UUID) async -> Bool {
        await change { document in
            guard var plan = document.taskPlans[taskID] else { return }
            plan.plannedDay = nil
            plan.startMinute = nil
            document.taskPlans[taskID] = plan
            if document.focusTaskID == taskID { document.focusTaskID = nil }
        }
    }

    func setWeeklyFocus(weekKey: String, text: String) async -> Bool {
        await change { document in
            guard TimePlanDay.isValidWeekKey(weekKey) else {
                throw TimePlanFailure.invalidInput("请选择有效周次")
            }
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty { document.weeklyFocus.removeValue(forKey: weekKey) }
            else { document.weeklyFocus[weekKey] = cleaned }
        }
    }

    func setDailyCapacity(dayKey: String, minutes: Int?) async -> Bool {
        await change { document in
            guard TimePlanDay.isValidDayKey(dayKey), minutes == nil || (1...1_440).contains(minutes!) else {
                throw TimePlanFailure.invalidInput("每日可用时间须为 1–1440 分钟")
            }
            if let minutes { document.dailyCapacityMinutes[dayKey] = minutes }
            else { document.dailyCapacityMinutes.removeValue(forKey: dayKey) }
        }
    }

    func flushPendingWrites() async -> Bool {
        while let pendingMutation { _ = await pendingMutation.value }
        return !isSaving && !hasFailedWrite
    }

    private func change(_ edit: @escaping @MainActor (inout TimePlanDocument) throws -> Void) async -> Bool {
        queuedMutationCount += 1
        latestMutationID += 1
        let mutationID = latestMutationID
        isSaving = true
        let previous = pendingMutation
        let job = Task { @MainActor in
            _ = await previous?.value
            defer {
                queuedMutationCount -= 1
                isSaving = queuedMutationCount > 0
                if latestMutationID == mutationID { pendingMutation = nil }
            }
            guard isLoaded else {
                errorMessage = TimePlanFailure.notLoaded.localizedDescription
                return false
            }
            var candidate = document
            do {
                try edit(&candidate)
            } catch {
                errorMessage = "保存规划失败：\(error.localizedDescription)"
                return false
            }
            do {
                try await repository.save(candidate)
                document = candidate
                hasFailedWrite = false
                errorMessage = nil
                return true
            } catch {
                hasFailedWrite = true
                errorMessage = "保存规划失败：\(error.localizedDescription)"
                return false
            }
        }
        pendingMutation = job
        return await job.value
    }

    private static func cleanTitle(_ title: String) throws -> String {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw TimePlanFailure.invalidInput("请填写名称") }
        return cleaned
    }

    private static func requireGoal(_ id: UUID?, in document: TimePlanDocument) throws {
        guard id == nil || document.goals.contains(where: { $0.id == id }) else {
            throw TimePlanFailure.missing("找不到目标")
        }
    }

    private static func requireProject(_ id: UUID?, in document: TimePlanDocument) throws {
        guard id == nil || document.projects.contains(where: { $0.id == id }) else {
            throw TimePlanFailure.missing("找不到项目")
        }
    }
}
