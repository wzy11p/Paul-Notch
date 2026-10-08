import SwiftUI

/// A planning lens over TaskStore. Task titles and completion are never copied here.
struct TimePlanningWorkspace: View {
    @ObservedObject var tasks: TaskStore
    @ObservedObject var plan: TimePlanStore
    @Binding var selectedDate: Date
    let onClose: () -> Void
    let onOpenTask: (UUID) -> Void
    let onCreateTask: (String) -> Void

    private enum Page: String, CaseIterable {
        case capture = "先梳理"
        case today = "当天"
        case direction = "目标与项目"
    }

    private enum Field: Hashable {
        case week, goal, project, nextStep, estimate, renameGoal, renameProject
        case captureTitle, captureAction
    }

    @State private var page: Page = .capture
    @State private var captureEditorID = UUID()
    @State private var captureDraft = ""
    @State private var captureMarked = false
    @State private var captureTitleDraft = ""
    @State private var captureTargetDate: Date?
    @State private var captureGoalID: UUID?
    @State private var captureActionDraft = ""
    @State private var captureActionID = UUID()
    @State private var showingNewCapture = false
    @State private var blockedGoalSwitch = false
    @State private var expandedBriefGoalID: UUID?
    @State private var weekDraft = ""
    @State private var goalDraft = ""
    @State private var projectDraft = ""
    @State private var newProjectGoalID: UUID?
    @State private var editingTaskID: UUID?
    @State private var stepDraft = ""
    @State private var estimateDraft = ""
    @State private var hasStartTime = false
    @State private var startTime = Date()
    @State private var editingGoalID: UUID?
    @State private var editingProjectID: UUID?
    @State private var goalRenameDraft = ""
    @State private var projectRenameDraft = ""
    @State private var pendingDeleteGoalID: UUID?
    @State private var pendingDeleteProjectID: UUID?
    @State private var confirmsDiscard = false
    @State private var hasRestoredDraft = false
    @State private var discardingDraft = false
    @State private var draftSaveFailed = false
    @State private var pendingDraftSave: Task<Void, Never>?
    @FocusState private var focusedField: Field?

    private var dayKey: String { TimePlanDay.key(for: selectedDate) }
    private var weekKey: String { TimePlanDay.weekKey(for: selectedDate) }
    private var plannedTasks: [TaskItem] {
        tasks.activeTasks
            .filter { plan.document.taskPlans[$0.id]?.plannedDay == dayKey }
            .sorted { lhs, rhs in
                let left = plan.document.taskPlans[lhs.id]?.startMinute ?? Int.max
                let right = plan.document.taskPlans[rhs.id]?.startMinute ?? Int.max
                if left != right { return left < right }
                return lhs.createdAt < rhs.createdAt
            }
    }
    private var completedCount: Int {
        plannedTasks.filter(\.isCompleted).count
    }
    private var dayLoad: TimePlanningLoad {
        TimePlanningLoad(dayKey: dayKey, taskIDs: plannedTasks.filter { !$0.isCompleted }.map(\.id),
                         document: plan.document)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if !plan.isLoaded {
                VStack(alignment: .leading, spacing: 12) {
                    Text(plan.errorMessage ?? "正在读取规划…")
                    if plan.errorMessage != nil {
                        Button("重新读取") { Task { await plan.load() } }
                            .frame(minHeight: 44)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                if let error = plan.errorMessage {
                    Text("规划尚未保存：\(error)")
                        .font(.caption)
                        .foregroundStyle(IslandTheme.accentOrange)
                        .lineLimit(2)
                        .accessibilityLabel("规划保存失败，\(error)")
                }
                if draftSaveFailed {
                    Text("输入草稿未能保存；离开前请检查或复制文字。")
                        .font(.caption)
                        .foregroundStyle(IslandTheme.accentOrange)
                }
                switch page {
                case .capture: capturePage
                case .today: todayPage
                case .direction: directionPage
                }
            }
        }
        .foregroundStyle(IslandTheme.text1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Planning is an intentional workspace, like the full task editor. Keep it
        // open while menus and IME candidate windows temporarily leave the panel.
        .onAppear {
            if plan.isLoaded { restoreDraft() }
            plan.isEditing = true
        }
        .onChange(of: plan.isLoaded) { loaded in
            if loaded && !hasRestoredDraft { restoreDraft() }
        }
        .onChange(of: draftSnapshot) { snapshot in
            scheduleDraftRetention(snapshot)
        }
        .onChange(of: plan.document) { _ in
            scheduleDraftRetention(draftSnapshot)
        }
        .onDisappear {
            pendingDraftSave?.cancel()
            if discardingDraft { discardDraftNow() }
            else if hasRestoredDraft { retainDraftNow(draftSnapshot) }
            plan.isEditing = false
        }
        .confirmationDialog("删除这个目标？", isPresented: Binding(
            get: { pendingDeleteGoalID != nil },
            set: { if !$0 { pendingDeleteGoalID = nil } }
        )) {
            Button("删除目标，保留项目", role: .destructive) {
                if let id = pendingDeleteGoalID {
                    Task {
                        if await plan.deleteGoal(id: id), newProjectGoalID == id {
                            newProjectGoalID = nil
                        }
                    }
                }
                pendingDeleteGoalID = nil
            }
            Button("取消", role: .cancel) { pendingDeleteGoalID = nil }
        } message: { Text("关联的项目和任务不会删除，项目会变为不关联目标。") }
        .confirmationDialog("删除这个项目？", isPresented: Binding(
            get: { pendingDeleteProjectID != nil },
            set: { if !$0 { pendingDeleteProjectID = nil } }
        )) {
            Button("删除项目，保留任务", role: .destructive) {
                if let id = pendingDeleteProjectID { Task { await plan.deleteProject(id: id) } }
                pendingDeleteProjectID = nil
            }
            Button("取消", role: .cancel) { pendingDeleteProjectID = nil }
        } message: { Text("原任务、安排日期和下一步仍会保留。") }
        .confirmationDialog("放弃未保存的输入？", isPresented: $confirmsDiscard) {
            Button("放弃并返回首页", role: .destructive) {
                discardingDraft = true
                discardDraftNow()
                onClose()
            }
            Button("继续编辑", role: .cancel) {}
        } message: { Text("已暂存输入草稿；放弃后会清除这份草稿。") }
        .alert("先处理未安排的动作", isPresented: $blockedGoalSwitch) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("先安排当前动作，或清空输入，再切换目标；不会把这段文字悄悄改挂到别的目标。")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: requestClose) {
                Label("返回首页", systemImage: "chevron.left")
                    .frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text("时间规划").font(.system(size: 18, weight: .semibold))
                .padding(.leading, 8)
            Spacer(minLength: 12)
            ForEach(Page.allCases, id: \.self) { item in
                Button { page = item; focusedField = nil } label: {
                    Text(item.rawValue).font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .background(page == item ? IslandTheme.surface3 : .clear,
                                    in: RoundedRectangle(cornerRadius: 12))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(page == item ? [.isSelected] : [])
            }
        }
    }

    private var capturePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let goal = selectedCaptureGoal, !showingNewCapture && captureDraft.isEmpty {
                    activeGoalCard(goal)
                } else {
                    captureEntry
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 4)
        }
    }

    private var selectedCaptureGoal: TimePlanGoal? {
        plan.document.goals.first { $0.id == captureGoalID }
    }

    private var captureEntry: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("先把想法倒出来").font(.system(size: 17, weight: .semibold))
                    Text("现状、卡点和想达到的结果都可以写；原文只保存在本机。")
                        .font(.caption).foregroundStyle(IslandTheme.text2)
                }
                Spacer(minLength: 8)
                if selectedCaptureGoal != nil {
                    Button("返回当前目标") { showingNewCapture = false; captureGoalID = plan.document.goals.last?.id }
                        .frame(minHeight: 44)
                }
            }
            ZStack(alignment: .topLeading) {
                if captureDraft.isEmpty {
                    Text("例如：我想完成什么？已有哪部分？哪里还卡住？")
                        .font(.system(size: 14)).foregroundStyle(IslandTheme.text2)
                        .padding(.leading, 14).padding(.top, 16)
                        .allowsHitTesting(false)
                }
                NoteTextEditor(draftID: captureEditorID, text: captureDraft, isEditable: true,
                               focusRequest: 0, accessibilityLabel: "时间规划原文") { id, text, marked in
                    guard id == captureEditorID else { return }
                    captureDraft = text
                    captureMarked = marked
                }
            }
            .frame(height: 116)
            .padding(8)
            .background(IslandTheme.surface2, in: RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 8) {
                TextField("目标名称（可留空，先用首句）", text: $captureTitleDraft)
                    .focused($focusedField, equals: .captureTitle)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .background(IslandTheme.surface2, in: RoundedRectangle(cornerRadius: 10))
                Toggle("有期限", isOn: Binding(get: { captureTargetDate != nil }, set: { enabled in
                    captureTargetDate = enabled ? (captureTargetDate ?? Date()) : nil
                }))
                    .toggleStyle(.checkbox)
                    .fixedSize()
                    .frame(minHeight: 44)
                if captureTargetDate != nil {
                    DatePicker("完成日期", selection: Binding(get: { captureTargetDate ?? Date() },
                                                      set: { captureTargetDate = $0 }),
                               displayedComponents: .date)
                        .labelsHidden()
                        .frame(minHeight: 44)
                }
                Button("保存目标") { saveCapturedGoal() }
                    .disabled(captureDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              captureMarked || captureDraft.count > 20_000 || plan.isSaving)
                    .foregroundStyle(IslandTheme.accentBlue)
                    .frame(minWidth: 80, minHeight: 44)
            }
            .buttonStyle(.plain)
            Text("这里不自动拆任务或猜优先级。保存后只选一个真正能开始的下一步。")
                .font(.caption).foregroundStyle(IslandTheme.text2)
        }
    }

    private func activeGoalCard(_ goal: TimePlanGoal) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("当前目标").font(.caption).foregroundStyle(IslandTheme.text2)
                    Text(goal.title).font(.system(size: 18, weight: .semibold)).lineLimit(2)
                }
                Spacer(minLength: 8)
                Menu {
                    ForEach(plan.document.goals.reversed()) { option in
                        Button(option.title) {
                            guard TimePlanningDraftStatus.canSwitchGoal(actionDraft: captureActionDraft) else {
                                blockedGoalSwitch = true
                                return
                            }
                            Task {
                                if await plan.setFocusGoal(id: option.id) { captureGoalID = option.id }
                            }
                        }
                    }
                } label: {
                    Label("切换目标", systemImage: "chevron.down")
                        .frame(minHeight: 44).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                Button("新增目标") {
                    guard TimePlanningDraftStatus.canSwitchGoal(actionDraft: captureActionDraft) else {
                        blockedGoalSwitch = true
                        return
                    }
                    showingNewCapture = true
                    captureGoalID = nil
                }
                    .frame(minHeight: 44)
            }
            if let target = goal.targetDay {
                Text("希望在 \(target) 前完成 · 目标日期不是任务截止日期")
                    .font(.caption).foregroundStyle(IslandTheme.text2)
            }
            if let brief = goal.brief, !brief.isEmpty {
                Text(brief).font(.system(size: 13)).foregroundStyle(IslandTheme.text2)
                    .lineLimit(expandedBriefGoalID == goal.id ? nil : 3).textSelection(.enabled)
                Button(expandedBriefGoalID == goal.id ? "收起原文" : "查看全部原文") {
                    expandedBriefGoalID = expandedBriefGoalID == goal.id ? nil : goal.id
                }
                .font(.caption).foregroundStyle(IslandTheme.accentBlue)
                .frame(minHeight: 44).contentShape(Rectangle())
                .buttonStyle(.plain)
            }
            Divider()
            if !goalTasks(goal.id).isEmpty {
                HStack {
                    Text("已拆成 \(goalTasks(goal.id).count) 个动作")
                        .font(.caption).foregroundStyle(IslandTheme.text2)
                    Spacer()
                    Text("完成 \(goalTasks(goal.id).filter(\.isCompleted).count)")
                        .font(.caption).foregroundStyle(IslandTheme.text2)
                }
                ForEach(Array(goalTasks(goal.id).prefix(3))) { task in
                    HStack(spacing: 4) {
                        Button {
                            Task { if await saveCurrentDrafts() { onOpenTask(task.id) } }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(task.isCompleted ? IslandTheme.accentGreen : IslandTheme.text2)
                                Text(task.title).lineLimit(1)
                                Spacer(minLength: 4)
                                if let day = plan.document.taskPlans[task.id]?.plannedDay {
                                    Text(day).font(.caption).foregroundStyle(IslandTheme.text2)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if !task.isCompleted && plan.document.taskPlans[task.id]?.plannedDay != nil {
                            Button {
                                Task { await plan.setFocusTask(id: task.id) }
                            } label: {
                                Image(systemName: "scope")
                                    .foregroundStyle(plan.document.focusTaskID == task.id ? IslandTheme.accentBlue : IslandTheme.text2)
                                    .frame(width: 44, height: 44).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(plan.document.focusTaskID == task.id ? "当前正在做：\(task.title)" : "设为现在先做：\(task.title)")
                            .disabled(plan.isSaving)
                        }
                    }
                }
                Divider()
            }
            Text("现在先做哪一步？").font(.system(size: 15, weight: .semibold))
            HStack(spacing: 8) {
                TextField("写一个能立即动手的动作，例如：列出 3 个待核实的数据", text: $captureActionDraft)
                    .focused($focusedField, equals: .captureAction)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .background(IslandTheme.surface3, in: RoundedRectangle(cornerRadius: 10))
                Button("安排到今天") { saveFirstAction(for: goal.id) }
                    .disabled(captureActionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              !tasks.hasLoaded || plan.isSaving)
                    .foregroundStyle(IslandTheme.accentBlue)
                    .frame(minWidth: 100, minHeight: 44)
            }
            .buttonStyle(.plain)
            Text("只选择今天要推进的动作；预计耗时和具体时段稍后再补。")
                .font(.caption).foregroundStyle(IslandTheme.text2)
            if let error = tasks.errorMessage {
                Text(error).font(.caption).foregroundStyle(IslandTheme.accentOrange)
            }
        }
        .padding(14)
        .background(IslandTheme.surface1, in: RoundedRectangle(cornerRadius: 14))
    }

    private func goalTasks(_ goalID: UUID) -> [TaskItem] {
        tasks.activeTasks.filter { plan.document.taskPlans[$0.id]?.goalID == goalID }
            .sorted { lhs, rhs in
                let left = plan.document.taskPlans[lhs.id]?.plannedDay ?? "9999-12-31"
                let right = plan.document.taskPlans[rhs.id]?.plannedDay ?? "9999-12-31"
                if left != right { return left < right }
                return lhs.createdAt < rhs.createdAt
            }
    }

    private func saveCapturedGoal() {
        guard !captureMarked else { return }
        let original = captureDraft
        let title = captureTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let date = captureTargetDate
        Task {
            guard await plan.addGoal(title: title.isEmpty ? original : title,
                                     brief: original,
                                     targetDay: date.map { TimePlanDay.key(for: $0) }) else { return }
            if let newID = plan.document.goals.last?.id {
                _ = await plan.setFocusGoal(id: newID)
            }
            guard captureDraft == original, captureTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines) == title,
                  captureTargetDate == date else { return }
            captureGoalID = plan.document.goals.last?.id
            captureDraft = ""
            captureTitleDraft = ""
            captureTargetDate = nil
            captureEditorID = UUID()
            showingNewCapture = false
            focusedField = .captureAction
        }
    }

    private func saveFirstAction(for goalID: UUID) {
        let title = captureActionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let taskID = captureActionID
        let today = TimePlanDay.key(for: Date())
        Task {
            guard await tasks.saveDetails(id: taskID, title: title, notes: "", dueDate: nil,
                                          priority: .blue, categoryID: nil) else { return }
            guard await plan.assignTaskToGoal(taskID: taskID, goalID: goalID),
                  await plan.planTask(taskID: taskID, dayKey: today),
                  await plan.setFocusTask(id: taskID) else { return }
            guard captureActionID == taskID, captureActionDraft.trimmingCharacters(in: .whitespacesAndNewlines) == title else { return }
            captureActionDraft = ""
            captureActionID = UUID()
            selectedDate = Date()
            page = .today
            focusedField = nil
        }
    }

    private var todayPage: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { shiftDay(-1) } label: {
                    Image(systemName: "chevron.left").frame(width: 44, height: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("前一天")
                Button { changeDay(to: Date()) } label: {
                    Text(selectedDate, format: .dateTime.month().day().weekday(.wide))
                        .font(.system(size: 14, weight: .semibold))
                        .frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).help("回到今天")
                Button { shiftDay(1) } label: {
                    Image(systemName: "chevron.right").frame(width: 44, height: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("后一天")
                Text("已完成 \(completedCount)/\(plannedTasks.count)")
                    .font(.caption).foregroundStyle(IslandTheme.text2)
                    .padding(.leading, 8)
                Spacer(minLength: 8)
                Menu {
                    Button("新建任务并安排到这天") {
                        Task { if await saveCurrentDrafts() { onCreateTask(dayKey) } }
                    }
                    if !availableTasks.isEmpty { Divider() }
                    ForEach(availableTasks) { task in
                        Button(task.title) { Task { await plan.planTask(taskID: task.id, dayKey: dayKey) } }
                    }
                } label: {
                    Label("添加任务", systemImage: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(IslandTheme.accentBlue)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .background(IslandTheme.surface3, in: RoundedRectangle(cornerRadius: 12))
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .disabled(!tasks.hasLoaded || plan.isSaving)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    dayCapacityBar
                    if plannedTasks.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("这天还没有安排任务").font(.headline)
                            Text("从待办挑选，或新建一个具体的下一步。")
                                .font(.callout).foregroundStyle(IslandTheme.text2)
                        }
                        .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
                    } else {
                        ForEach(plannedTasks) { task in
                            taskRow(task)
                            if editingTaskID == task.id { taskPlanningEditor(task) }
                        }
                    }
                    weekFocusEditor
                }
                .padding(.bottom, 4)
            }
        }
    }

    private var dayCapacityBar: some View {
        HStack(spacing: 8) {
            Menu {
                Button("不设可用时间") {
                    let target = dayKey
                    Task { await plan.setDailyCapacity(dayKey: target, minutes: nil) }
                }
                ForEach([30, 60, 90, 120, 180, 240, 300, 360, 480, 600, 720], id: \.self) { minutes in
                    Button(minutes < 60 ? "30 分钟" : "\(minutes / 60) 小时\(minutes % 60 == 0 ? "" : " 30 分钟")") {
                        let target = dayKey
                        Task { await plan.setDailyCapacity(dayKey: target, minutes: minutes) }
                    }
                }
            } label: {
                Label(dayLoad.capacityMinutes.map { "可用 \($0) 分钟" } ?? "可用时间未设置", systemImage: "hourglass")
                    .font(.system(size: 12, weight: .medium))
                    .frame(minHeight: 44).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .disabled(plan.isSaving)
            Text("已估 \(dayLoad.estimatedMinutes) 分钟")
                .font(.caption).foregroundStyle(IslandTheme.text2)
            if dayLoad.unestimatedCount > 0 {
                Text("\(dayLoad.unestimatedCount) 项未估")
                    .font(.caption).foregroundStyle(IslandTheme.text2)
            }
            if dayLoad.isKnownOverCapacity {
                Text("已超出可用时间")
                    .font(.caption).foregroundStyle(IslandTheme.accentOrange)
            }
            Spacer(minLength: 0)
        }
    }

    private var availableTasks: [TaskItem] {
        tasks.activeTasks.filter {
            !$0.isCompleted && plan.document.taskPlans[$0.id]?.plannedDay != dayKey
        }
    }

    private func taskRow(_ task: TaskItem) -> some View {
        let detail = plan.document.taskPlans[task.id]
        return HStack(spacing: 0) {
            Button { tasks.toggle(task) } label: {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(task.isCompleted ? IslandTheme.accentGreen : IslandTheme.text2)
                    .frame(width: 44, height: 54).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.isCompleted ? "标为未完成：\(task.title)" : "完成任务：\(task.title)")
            Button { openPlanEditor(task.id) } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.title).font(.system(size: 14, weight: .medium))
                            .lineLimit(2).strikethrough(task.isCompleted)
                        HStack(spacing: 8) {
                            if let name = detail?.projectID.flatMap({ projectID in
                                plan.document.projects.first { $0.id == projectID }?.title
                            }) { Text(name) }
                            if let step = detail?.nextStep, !step.isEmpty { Text("下一步：\(step)").lineLimit(1) }
                            if let minutes = detail?.estimatedMinutes { Text("预计 \(minutes) 分钟") }
                            else { Text("未估算") }
                            if let start = detail?.startMinute {
                                Text(String(format: "%02d:%02d", start / 60, start % 60))
                            }
                        }
                        .font(.system(size: 11)).foregroundStyle(IslandTheme.text2)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: editingTaskID == task.id ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11)).foregroundStyle(IslandTheme.text2)
                }
                .padding(.trailing, 8)
                .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("展开规划选项；不会打开任务编辑器")
            Button {
                Task { if await saveCurrentDrafts() { onOpenTask(task.id) } }
            } label: {
                Image(systemName: "square.and.pencil")
                    .frame(width: 44, height: 54).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("编辑任务详情：\(task.title)")
        }
        .background(IslandTheme.surface1, in: RoundedRectangle(cornerRadius: 12))
    }

    private func taskPlanningEditor(_ task: TaskItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("下一步动作（可选）", text: $stepDraft)
                    .focused($focusedField, equals: .nextStep)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .background(IslandTheme.surface3, in: RoundedRectangle(cornerRadius: 10))
                TextField("预计分钟", text: $estimateDraft)
                    .focused($focusedField, equals: .estimate)
                    .textFieldStyle(.plain)
                    .frame(width: 80, height: 44)
                    .padding(.horizontal, 10)
                    .background(IslandTheme.surface3, in: RoundedRectangle(cornerRadius: 10))
            }
            HStack(spacing: 8) {
                Menu {
                    Button("不关联项目") { assign(task.id, to: nil) }
                    ForEach(plan.document.projects) { project in
                        Button(project.title) { assign(task.id, to: project.id) }
                    }
                } label: {
                    Label(projectName(for: task.id), systemImage: "folder")
                        .lineLimit(1)
                        .frame(maxWidth: 150)
                        .padding(.horizontal, 12).frame(minHeight: 44).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                Toggle("安排时段", isOn: $hasStartTime).toggleStyle(.checkbox)
                    .frame(minHeight: 44)
                if hasStartTime {
                    DatePicker("开始", selection: $startTime, displayedComponents: .hourAndMinute)
                        .labelsHidden().frame(minHeight: 44)
                }
                Spacer(minLength: 0)
                Button("移到次日") { moveToNextDay(task.id) }
                    .disabled(task.isCompleted || plan.isSaving)
                    .frame(minHeight: 44)
                Button("移出当天") {
                    Task {
                        guard await saveOpenTaskEditor() else { return }
                        _ = await plan.unplanTask(taskID: task.id)
                    }
                }
                    .disabled(plan.isSaving)
                    .frame(minHeight: 44)
                Button("保存安排") { saveDetails() }
                    .disabled(plan.isSaving || !validEstimate)
                    .foregroundStyle(IslandTheme.accentBlue)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            Text("预计时间只用于安排；专注计时不会自动标记任务完成。")
                .font(.system(size: 11)).foregroundStyle(IslandTheme.text2)
            if !validEstimate {
                Text("预计分钟请填 1–600 的整数，或留空。")
                    .font(.caption).foregroundStyle(IslandTheme.accentOrange)
            }
        }
        .padding(10)
        .background(IslandTheme.surface2, in: RoundedRectangle(cornerRadius: 12))
    }

    private var validEstimate: Bool {
        let trimmed = estimateDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || (Int(trimmed).map { (1...600).contains($0) } ?? false)
    }

    private var weekFocusEditor: some View {
        HStack(spacing: 8) {
            Text("本周重点").font(.system(size: 13, weight: .semibold))
            TextField("这周希望推进什么？可留空", text: $weekDraft)
                .focused($focusedField, equals: .week)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(IslandTheme.surface2, in: RoundedRectangle(cornerRadius: 10))
            Button("保存") {
                let value = weekDraft
                let targetWeekKey = weekKey
                Task {
                    if await plan.setWeeklyFocus(weekKey: targetWeekKey, text: value),
                       weekKey == targetWeekKey, weekDraft == value {
                        focusedField = nil
                    }
                }
            }
            .disabled(plan.isSaving || weekDraft == (plan.document.weeklyFocus[weekKey] ?? ""))
            .frame(minWidth: 56, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
    }

    private var directionPage: some View {
        HStack(alignment: .top, spacing: 14) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("目标").font(.system(size: 16, weight: .semibold))
                    Text("写你想达到的结果；不必照搬任何模板。")
                        .font(.caption).foregroundStyle(IslandTheme.text2)
                    HStack(spacing: 8) {
                        TextField("新目标", text: $goalDraft)
                            .focused($focusedField, equals: .goal)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 12).frame(minHeight: 44)
                            .background(IslandTheme.surface2, in: RoundedRectangle(cornerRadius: 10))
                        Button("添加") {
                            let title = goalDraft
                            Task {
                                if await plan.addGoal(title: title), goalDraft == title {
                                    goalDraft = ""
                                    focusedField = nil
                                }
                            }
                        }
                        .disabled(goalDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || plan.isSaving)
                        .frame(minWidth: 52, minHeight: 44)
                    }
                    ForEach(plan.document.goals) { goal in goalRow(goal) }
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("项目").font(.system(size: 16, weight: .semibold))
                    Text("项目可以关联目标；任务可关联项目。")
                        .font(.caption).foregroundStyle(IslandTheme.text2)
                    HStack(spacing: 8) {
                        TextField("新项目", text: $projectDraft)
                            .focused($focusedField, equals: .project)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 12).frame(minHeight: 44)
                            .background(IslandTheme.surface2, in: RoundedRectangle(cornerRadius: 10))
                        Button("添加") {
                            let title = projectDraft
                            let goalID = newProjectGoalID
                            Task {
                                if await plan.addProject(title: title, goalID: goalID), projectDraft == title {
                                    projectDraft = ""
                                    focusedField = nil
                                }
                            }
                        }
                        .disabled(projectDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || plan.isSaving)
                        .frame(minWidth: 52, minHeight: 44)
                    }
                    goalMenu(selectedID: newProjectGoalID) { newProjectGoalID = $0 }
                    ForEach(plan.document.projects) { project in projectRow(project) }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func goalRow(_ goal: TimePlanGoal) -> some View {
        HStack(spacing: 8) {
            if editingGoalID == goal.id {
                TextField("目标名称", text: $goalRenameDraft)
                    .focused($focusedField, equals: .renameGoal)
                    .textFieldStyle(.plain)
                    .frame(maxWidth: .infinity, minHeight: 44)
                Button("保存") {
                    let title = goalRenameDraft
                    Task {
                        if await plan.renameGoal(id: goal.id, title: title),
                           editingGoalID == goal.id, goalRenameDraft == title {
                            editingGoalID = nil
                            focusedField = nil
                        }
                    }
                }
                .disabled(goalRenameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || plan.isSaving)
                Button("取消") { editingGoalID = nil; goalRenameDraft = ""; focusedField = nil }
                    .frame(minHeight: 44)
            } else {
                Text(goal.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                Spacer(minLength: 0)
                Button { goalRenameDraft = goal.title; editingGoalID = goal.id; focusedField = .renameGoal } label: {
                    Image(systemName: "pencil").frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .disabled(editingGoalID != nil)
                .accessibilityLabel("重命名目标：\(goal.title)")
                Menu {
                    Button("删除目标，保留项目", role: .destructive) { pendingDeleteGoalID = goal.id }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle())
                }.menuStyle(.borderlessButton).accessibilityLabel("目标选项：\(goal.title)")
            }
        }
        .padding(.leading, 12)
        .background(IslandTheme.surface1, in: RoundedRectangle(cornerRadius: 12))
    }

    private func projectRow(_ project: TimePlanProject) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
            if editingProjectID == project.id {
                    TextField("项目名称", text: $projectRenameDraft)
                        .focused($focusedField, equals: .renameProject)
                        .textFieldStyle(.plain)
                        .frame(maxWidth: .infinity, minHeight: 44)
                    Button("保存") {
                        let title = projectRenameDraft
                        Task {
                            if await plan.renameProject(id: project.id, title: title),
                               editingProjectID == project.id, projectRenameDraft == title {
                                editingProjectID = nil
                                focusedField = nil
                            }
                        }
                    }
                    .disabled(projectRenameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || plan.isSaving)
                    Button("取消") { editingProjectID = nil; projectRenameDraft = ""; focusedField = nil }
                        .frame(minHeight: 44)
                } else {
                    Text(project.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                    Spacer(minLength: 0)
                    Button { projectRenameDraft = project.title; editingProjectID = project.id; focusedField = .renameProject } label: {
                        Image(systemName: "pencil").frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .disabled(editingProjectID != nil)
                    .accessibilityLabel("重命名项目：\(project.title)")
                    Menu {
                        Button("删除项目，保留任务", role: .destructive) { pendingDeleteProjectID = project.id }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle())
                    }.menuStyle(.borderlessButton).accessibilityLabel("项目选项：\(project.title)")
                }
            }
            goalMenu(selectedID: project.goalID) { goalID in
                Task { await plan.setProjectGoal(projectID: project.id, goalID: goalID) }
            }
            .disabled(plan.isSaving)
        }
        .padding(.leading, 12)
        .background(IslandTheme.surface1, in: RoundedRectangle(cornerRadius: 12))
    }

    private func goalMenu(selectedID: UUID?, change: @escaping (UUID?) -> Void) -> some View {
        Menu {
            Button("不关联目标") { change(nil) }
            ForEach(plan.document.goals) { goal in Button(goal.title) { change(goal.id) } }
        } label: {
            Label(plan.document.goals.first { $0.id == selectedID }?.title ?? "不关联目标", systemImage: "scope")
                .font(.caption).foregroundStyle(IslandTheme.text2)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
    }

    private func openPlanEditor(_ taskID: UUID) {
        if editingTaskID == taskID {
            if taskEditorHasChanges { saveDetails() }
            else { editingTaskID = nil; focusedField = nil }
            return
        }
        if editingTaskID != nil && taskEditorHasChanges {
            Task { if await saveOpenTaskEditor() { openPlanEditor(taskID) } }
            return
        }
        editingTaskID = taskID
        let detail = plan.document.taskPlans[taskID]
        stepDraft = detail?.nextStep ?? ""
        estimateDraft = detail?.estimatedMinutes.map(String.init) ?? ""
        hasStartTime = detail?.startMinute != nil
        if let minute = detail?.startMinute,
           let date = Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60,
                                            second: 0, of: selectedDate) {
            startTime = date
        } else { startTime = selectedDate }
    }

    private func projectName(for taskID: UUID) -> String {
        guard let projectID = plan.document.taskPlans[taskID]?.projectID else { return "不关联项目" }
        return plan.document.projects.first { $0.id == projectID }?.title ?? "项目已移除"
    }

    private func assign(_ taskID: UUID, to projectID: UUID?) {
        Task { await plan.assignTask(taskID: taskID, projectID: projectID) }
    }

    private func saveDetails() {
        Task { _ = await saveOpenTaskEditor() }
    }

    private func saveOpenTaskEditor() async -> Bool {
        guard let taskID = editingTaskID else { return true }
        guard validEstimate else { return false }
        if !taskEditorHasChanges {
            editingTaskID = nil
            focusedField = nil
            return true
        }
        let rawStep = stepDraft
        let rawEstimate = estimateDraft
        let capturedHasStartTime = hasStartTime
        let capturedStartTime = startTime
        let trimmedStep = stepDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEstimate = estimateDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let minute = hasStartTime ? Calendar.current.component(.hour, from: startTime) * 60
            + Calendar.current.component(.minute, from: startTime) : nil
        if await plan.setTaskDetails(taskID: taskID,
                                     nextStep: trimmedStep.isEmpty ? nil : trimmedStep,
                                     estimatedMinutes: Int(trimmedEstimate), startMinute: minute) {
            guard editingTaskID == taskID,
                  stepDraft == rawStep, estimateDraft == rawEstimate,
                  hasStartTime == capturedHasStartTime,
                  startTime == capturedStartTime else { return false }
            focusedField = nil
            editingTaskID = nil
            return true
        }
        return false
    }

    private func moveToNextDay(_ taskID: UUID) {
        guard let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: selectedDate) else { return }
        Task {
            guard await saveOpenTaskEditor() else { return }
            _ = await plan.planTask(taskID: taskID, dayKey: TimePlanDay.key(for: tomorrow))
        }
    }

    private func shiftDay(_ amount: Int) {
        if let shifted = Calendar.current.date(byAdding: .day, value: amount, to: selectedDate) {
            changeDay(to: shifted)
        }
    }

    private func changeDay(to date: Date) {
        guard TimePlanDay.key(for: date) != dayKey else { return }
        Task {
            guard await saveCurrentDrafts() else { return }
            selectedDate = date
            weekDraft = plan.document.weeklyFocus[TimePlanDay.weekKey(for: date)] ?? ""
            editingTaskID = nil
        }
    }

    private func saveCurrentDrafts() async -> Bool {
        guard await saveOpenTaskEditor() else { return false }
        let saved = plan.document.weeklyFocus[weekKey] ?? ""
        guard weekDraft != saved else { return true }
        let value = weekDraft
        let targetWeekKey = weekKey
        return await plan.setWeeklyFocus(weekKey: targetWeekKey, text: value)
            && weekKey == targetWeekKey && weekDraft == value
    }

    private func requestClose() {
        if hasUnsavedInputs { confirmsDiscard = true }
        else { onClose() }
    }

    private var hasUnsavedInputs: Bool {
        weekDraft != (plan.document.weeklyFocus[weekKey] ?? "")
            || !captureDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !captureTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !captureActionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !goalDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !projectDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (editingGoalID.flatMap { id in
                plan.document.goals.first { $0.id == id }.map { goalRenameDraft != $0.title }
            } ?? false)
            || (editingProjectID.flatMap { id in
                plan.document.projects.first { $0.id == id }.map { projectRenameDraft != $0.title }
            } ?? false)
            || taskEditorHasChanges
    }

    private var draftSnapshot: TimePlanningDraft {
        TimePlanningDraft(selectedDate: selectedDate,
                          pageRaw: page == .capture ? "capture" : (page == .today ? "today" : "direction"),
                          weekDraft: weekDraft,
                          goalDraft: goalDraft,
                          projectDraft: projectDraft,
                          newProjectGoalID: newProjectGoalID,
                          editingTaskID: editingTaskID,
                          stepDraft: stepDraft,
                          estimateDraft: estimateDraft,
                          hasStartTime: hasStartTime,
                          startTime: startTime,
                          editingGoalID: editingGoalID,
                          editingProjectID: editingProjectID,
                          goalRenameDraft: goalRenameDraft,
                          projectRenameDraft: projectRenameDraft,
                          captureDraft: captureDraft,
                          captureTitleDraft: captureTitleDraft,
                          captureTargetDate: captureTargetDate,
                          captureGoalID: captureGoalID,
                          captureActionDraft: captureActionDraft,
                          captureActionID: captureActionID)
    }

    private func restoreDraft() {
        guard !hasRestoredDraft else { return }
        if let draft = TimePlanningDraftCache().load() {
            selectedDate = draft.selectedDate
            page = draft.pageRaw == "direction" ? .direction :
                (draft.pageRaw == "capture" ? .capture : .today)
            weekDraft = draft.weekDraft
            goalDraft = draft.goalDraft
            projectDraft = draft.projectDraft
            newProjectGoalID = draft.newProjectGoalID.flatMap { id in
                plan.document.goals.contains { $0.id == id } ? id : nil
            }
            // TaskStore loads independently from TimePlanStore. Keep the ID until
            // its task arrives instead of dropping unsaved fields during startup.
            editingTaskID = draft.editingTaskID
            stepDraft = draft.stepDraft
            estimateDraft = draft.estimateDraft
            hasStartTime = draft.hasStartTime
            startTime = draft.startTime
            editingGoalID = draft.editingGoalID.flatMap { id in
                plan.document.goals.contains { $0.id == id } ? id : nil
            }
            editingProjectID = draft.editingProjectID.flatMap { id in
                plan.document.projects.contains { $0.id == id } ? id : nil
            }
            goalRenameDraft = draft.goalRenameDraft
            projectRenameDraft = draft.projectRenameDraft
            captureDraft = draft.captureDraft ?? ""
            captureTitleDraft = draft.captureTitleDraft ?? ""
            captureTargetDate = draft.captureTargetDate
            captureGoalID = draft.captureGoalID.flatMap { id in
                plan.document.goals.contains { $0.id == id } ? id : nil
            } ?? plan.document.focusGoalID ?? plan.document.goals.last?.id
            captureActionDraft = draft.captureActionDraft ?? ""
            captureActionID = draft.captureActionID ?? UUID()
        } else {
            weekDraft = plan.document.weeklyFocus[weekKey] ?? ""
            captureGoalID = plan.document.focusGoalID ?? plan.document.goals.last?.id
        }
        hasRestoredDraft = true
    }

    private func scheduleDraftRetention(_ snapshot: TimePlanningDraft) {
        guard hasRestoredDraft, !discardingDraft else { return }
        // Stage synchronously so Cmd+Q can flush even inside the debounce window.
        TimePlanningDraftCoordinator.shared.stage(hasUnsavedInputs ? snapshot : nil)
        pendingDraftSave?.cancel()
        pendingDraftSave = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            draftSaveFailed = !TimePlanningDraftCoordinator.shared.flush()
        }
    }

    private func retainDraftNow(_ snapshot: TimePlanningDraft) {
        let coordinator = TimePlanningDraftCoordinator.shared
        coordinator.stage(hasUnsavedInputs ? snapshot : nil)
        draftSaveFailed = !coordinator.flush()
    }

    private func discardDraftNow() {
        let coordinator = TimePlanningDraftCoordinator.shared
        coordinator.stage(nil)
        draftSaveFailed = !coordinator.flush()
    }

    private var taskEditorHasChanges: Bool {
        guard let editingTaskID else { return false }
        let saved = plan.document.taskPlans[editingTaskID]
        let step = stepDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let minute = hasStartTime ? Calendar.current.component(.hour, from: startTime) * 60
            + Calendar.current.component(.minute, from: startTime) : nil
        return (step.isEmpty ? nil : step) != saved?.nextStep
            || TimePlanningDraftStatus.estimateHasChanges(estimateDraft, comparedTo: saved?.estimatedMinutes)
            || minute != saved?.startMinute
    }
}
