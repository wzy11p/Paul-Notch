import SwiftUI

/// Hover is read-only; only an explicit click enters the persistent editor.
struct MemoTaskWorkspace: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var settings: AppSettingsStore
    let completed: Bool
    var initialTaskID: UUID? = nil
    @State private var selectedCategory: String?
    @State private var editorID: UUID?
    @State private var creating = false
    @State private var hoverID: UUID?
    @State private var previewID: UUID?
    @State private var previewRequest: Task<Void, Never>?
    @State private var showsCategoryManager = false
    private static let allCategoriesID = "__all_categories__"

    private var editing: Bool { creating || editorID != nil }
    private var items: [TaskItem] {
        store.activeTasks.filter {
            $0.isCompleted == completed && (selectedCategory == nil || !settings.memoCategoriesEnabled
                || settings.effectiveMemoCategoryID(for: $0.categoryID) == selectedCategory)
        }
    }

    var body: some View {
        Group {
            if editing {
                MemoTaskEditor(store: store, settings: settings,
                               task: store.tasks.first { $0.id == editorID },
                               defaultCategory: selectedCategory) {
                    creating = false
                    editorID = nil
                    store.memoEditingActive = false
                }
                .id(editorID?.uuidString ?? "new")
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            store.memoEditingActive = editing
            if let initialTaskID, !editing { openEditor(initialTaskID) }
            consumeAddIntent()
        }
        .onDisappear {
            cancelPreview()
            store.memoEditingActive = false
        }
        .onChange(of: completed) { _ in cancelPreview() }
        .onChange(of: selectedCategory) { _ in cancelPreview() }
        .onChange(of: settings.memoCategories.map(\.id)) { ids in
            if let selectedCategory, !ids.contains(selectedCategory) { self.selectedCategory = nil }
        }
        .onChange(of: store.focusAddRequest) { _ in consumeAddIntent() }
    }

    private var list: some View {
        VStack(spacing: 8) {
            if settings.memoCategoriesEnabled {
                HStack(spacing: 0) {
                    ReorderableTabStrip(
                        items: [ReorderableTabItem(id: Self.allCategoriesID, title: "全部分类", movable: false)]
                            + settings.memoCategories.map { ReorderableTabItem(id: $0.id, title: $0.name) },
                        selectedID: selectedCategory ?? Self.allCategoriesID,
                        onSelect: { selectedCategory = $0 == Self.allCategoriesID ? nil : $0 },
                        onReorder: { ids in
                            _ = settings.reorderMemoCategories(ids.filter { $0 != Self.allCategoriesID })
                        }
                    )
                    .frame(height: 44)
                    Button { cancelPreview(); showsCategoryManager = true } label: {
                        Image(systemName: "slider.horizontal.3")
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("管理分类；拖动分类名称可排序")
                    .accessibilityLabel("管理分类")
                    .popover(isPresented: $showsCategoryManager, arrowEdge: .bottom) {
                        MemoCategoryManager(settings: settings)
                    }
                }
            }
            if !completed {
                Button { openEditor(nil) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "square.and.pencil")
                        Text("新建任务")
                        Spacer()
                        Text("标题、说明与子任务").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!store.hasLoaded)
            }
            if items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: completed ? "checkmark.circle" : "checklist").font(.title)
                    Text(completed ? "还没有已完成任务" : "这里还没有任务")
                    if !completed { Text("先记下来，细节可以慢慢补充").font(.caption) }
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(items) { task in row(task) }
                    }
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let task = items.first(where: { $0.id == previewID }) {
                preview(task)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private func row(_ task: TaskItem) -> some View {
        HStack(spacing: 0) {
            Button {
                cancelPreview()
                store.toggle(task)
            } label: {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(task.isCompleted ? Color.green : Color.secondary)
                    .frame(width: 44, height: 54).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.isCompleted ? "标为未完成" : "完成任务")

            // The wide label owns the blank area. No parent tap gesture steals checkbox clicks.
            Button { openEditor(task.id) } label: {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(task.title).lineLimit(2).strikethrough(task.isCompleted)
                        HStack(spacing: 10) {
                            if settings.memoCategoriesEnabled {
                                Text(categoryName(task)).lineLimit(1)
                            }
                            if settings.memoDueDatesEnabled, let date = task.dueDate {
                                Label(date.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                                    .foregroundStyle(date < .now && !completed ? Color.orange : Color.secondary)
                            }
                            if !(task.notes ?? "").isEmpty {
                                Image(systemName: "text.alignleft").accessibilityLabel("有详细说明")
                            }
                            if settings.memoSubtasksEnabled, let steps = task.subtasks, !steps.isEmpty {
                                Text("\(steps.filter(\.isCompleted).count)/\(steps.count)")
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if settings.memoPrioritiesEnabled {
                        Text(settings.priorityName(for: task.priority ?? .blue))
                            .font(.caption)
                            .foregroundStyle(settings.priorityColor(for: task.priority ?? .blue))
                    }
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.trailing, 14).padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("打开任务详情；停留可预览")
            .onHover { inside in schedulePreview(task.id, inside: inside) }
            .onDisappear { if hoverID == task.id { cancelPreview() } }
        }
        .background(.white.opacity(hoverID == task.id ? 0.10 : 0.045), in: RoundedRectangle(cornerRadius: 12))
    }

    private func preview(_ task: TaskItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("内容预览", systemImage: "eye")
                Spacer()
                Text("单击任务打开")
            }
            .font(.caption).foregroundStyle(.secondary)
            Text(task.title).font(.headline).lineLimit(2)
            Text((task.notes ?? "").isEmpty ? "还没有说明，打开详情后可补充。" : task.notes!)
                .font(.callout).foregroundStyle(.secondary).lineLimit(4)
        }
        .padding(16).frame(width: 310, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 6)
        .padding(8)
    }

    private func categoryName(_ task: TaskItem) -> String {
        settings.memoCategoryName(for: task.categoryID)
    }

    private func schedulePreview(_ id: UUID, inside: Bool) {
        if !inside {
            if hoverID == id { cancelPreview() }
            return
        }
        cancelPreview()
        hoverID = id
        previewRequest = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, hoverID == id, !editing else { return }
            previewID = id
        }
    }

    private func cancelPreview() {
        previewRequest?.cancel()
        previewRequest = nil
        hoverID = nil
        previewID = nil
    }

    private func openEditor(_ id: UUID?) {
        cancelPreview()
        editorID = id
        creating = id == nil
        store.memoEditingActive = true
        NSApp.windows.first { $0 is IslandPanel && $0.isVisible }?.makeKeyAndOrderFront(nil)
    }

    private func consumeAddIntent() {
        if store.consumeMemoAddRequest() { openEditor(nil) }
    }
}

struct MemoTaskDraft: Codable, Equatable {
    var id: UUID
    var title: String
    var notes: String
    var dueDate: Date?
    var priority: TaskPriority
    var categoryID: String?
    // Optional preserves decoding of retained v2 drafts written before subtask editing.
    var subtasks: [SubtaskItem]?
    var pendingStepTitle: String?
    // An optional planning intent belongs to this retained editor draft, not
    // to TaskItem's due date. It survives leaving Home before the first save.
    var plannedDay: String?

    init(task: TaskItem?, categoryID: String?, plannedDay: String? = nil) {
        id = task?.id ?? UUID()
        title = task?.title ?? ""
        notes = task?.notes ?? ""
        dueDate = task?.dueDate
        priority = task?.priority ?? .blue
        self.categoryID = task?.categoryID ?? categoryID
        subtasks = task?.subtasks ?? []
        self.plannedDay = plannedDay
    }
}

struct MemoTaskEditor: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var settings: AppSettingsStore
    let task: TaskItem?
    let onClose: () -> Void
    let onSaved: ((UUID, String?) async -> Bool)?
    let returnLabel: String
    private let draftKey: String
    @State private var draft: MemoTaskDraft
    @State private var saving = false
    @State private var failed = false
    @State private var failedPlanning = false
    @State private var showsCategory = false
    @State private var showsPriority = false
    @FocusState private var titleFocused: Bool

    init(store: TaskStore, settings: AppSettingsStore, task: TaskItem?, defaultCategory: String?, plannedDay: String? = nil, returnLabel: String = "返回列表", onSaved: ((UUID, String?) async -> Bool)? = nil, onClose: @escaping () -> Void) {
        self.store = store
        self.settings = settings
        self.task = task
        self.onClose = onClose
        self.onSaved = onSaved
        self.returnLabel = returnLabel
        draftKey = "memo-task-draft-v2-" + (task?.id.uuidString ?? "new")
        let restored = AppEnvironment.defaults.data(forKey: draftKey)
            .flatMap { try? JSONDecoder().decode(MemoTaskDraft.self, from: $0) }
        // Opening an old nil-category task must not assign today's first tab.
        let newCategory = task == nil ? (defaultCategory ?? settings.memoCategories.first?.id) : nil
        var initial = restored ?? MemoTaskDraft(task: task, categoryID: newCategory, plannedDay: plannedDay)
        if initial.subtasks == nil { initial.subtasks = task?.subtasks ?? [] }
        // The current entry action owns placement. A retained draft from an
        // earlier planning session must not silently schedule a Home-created
        // task on its old day (or override a newly selected day).
        if task == nil { initial.plannedDay = plannedDay }
        _draft = State(initialValue: initial)
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button { retainDraft(); onClose() } label: {
                    Label(returnLabel, systemImage: "chevron.left")
                        .padding(.horizontal, 10).frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                Text(task == nil ? "新建任务" : "任务详情").font(.headline)
                Spacer()
                Text(draft.plannedDay.map { "计划日期 \($0)" } ?? "移开鼠标不会关闭")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    TextField("任务标题", text: $draft.title, axis: .vertical)
                        .font(.system(size: 20, weight: .semibold))
                        .textFieldStyle(.plain).lineLimit(1...3).focused($titleFocused)
                        .padding(12)
                        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("详细说明").font(.callout.weight(.medium))
                        TextEditor(text: $draft.notes)
                            .font(.body).scrollContentBackground(.hidden)
                            .frame(height: 80)
                            .padding(8)
                            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                            .accessibilityLabel("详细说明，可换行")
                    }
                    HStack(spacing: 12) {
                        if settings.memoCategoriesEnabled {
                            Button { showsCategory.toggle() } label: {
                                Label("分类：\(categoryName)", systemImage: "folder")
                                    .padding(.horizontal, 12).frame(minHeight: 44).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                            .popover(isPresented: $showsCategory) {
                                VStack(spacing: 0) {
                                    ForEach(settings.memoCategories) { category in
                                        Button {
                                            draft.categoryID = category.id
                                            showsCategory = false
                                        } label: {
                                            HStack {
                                                Text(category.name)
                                                Spacer()
                                                if draft.categoryID == category.id { Image(systemName: "checkmark") }
                                            }
                                            .padding(.horizontal, 12).frame(width: 210, height: 44)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }.padding(8)
                            }
                        }
                        if settings.memoPrioritiesEnabled {
                            Button { showsPriority.toggle() } label: {
                                Label("优先级：\(settings.priorityName(for: draft.priority))", systemImage: "flag")
                                    .padding(.horizontal, 12).frame(minHeight: 44).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                            .popover(isPresented: $showsPriority) {
                                VStack(spacing: 0) {
                                    ForEach(TaskPriority.allCases, id: \.self) { priority in
                                        Button {
                                            draft.priority = priority
                                            showsPriority = false
                                        } label: {
                                            HStack {
                                                Text(settings.priorityName(for: priority))
                                                Spacer()
                                                if draft.priority == priority { Image(systemName: "checkmark") }
                                            }
                                            .padding(.horizontal, 12).frame(width: 180, height: 44)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }.padding(8)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    if settings.memoDueDatesEnabled {
                        HStack(spacing: 16) {
                            Button {
                                draft.dueDate = draft.dueDate == nil ? .now.addingTimeInterval(3600) : nil
                            } label: {
                                Label("设置截止时间", systemImage: draft.dueDate == nil ? "square" : "checkmark.square.fill")
                                    .padding(.horizontal, 12).frame(minHeight: 44).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityValue(draft.dueDate == nil ? "未设置" : "已设置")
                            if draft.dueDate != nil {
                                DatePicker("截止", selection: Binding(
                                    get: { draft.dueDate ?? .now }, set: { draft.dueDate = $0 }
                                ))
                                .labelsHidden()
                            }
                            Spacer()
                        }
                    }
                    if settings.memoSubtasksEnabled {
                        Divider()
                        HStack {
                            Text("子任务").font(.headline)
                            Text("与正文一起保存").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(draft.subtasks ?? []) { subtask in
                            draftStep(subtask)
                        }
                        HStack {
                            TextField("添加一个步骤", text: Binding(
                                get: { draft.pendingStepTitle ?? "" },
                                set: { draft.pendingStepTitle = $0 }
                            )).textFieldStyle(.roundedBorder)
                            Button(action: appendStep) {
                                Text("添加步骤").padding(.horizontal, 12).frame(minHeight: 44).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled((draft.pendingStepTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
                .padding(4)
            }
            HStack {
                Text(failedPlanning ? "任务已保存，安排日期未保存；草稿已保留，重试不会重复建任务" :
                     (failed ? "保存失败，草稿已保留，请重试" : "返回保留草稿 · 点击保存才更新任务"))
                    .font(.caption).foregroundStyle(failed ? Color.orange : Color.secondary)
                Spacer()
                if let task {
                    Button(role: .destructive) {
                        store.delete(task)
                        onClose()
                    } label: {
                        Label("移到回收站", systemImage: "trash")
                            .padding(.horizontal, 12).frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Button(action: save) {
                    Text(saving ? "正在保存…" : (failedPlanning ? "重试保存安排" :
                        (failed ? "重试保存" : (task == nil ? "添加任务" : "保存修改"))))
                        .padding(.horizontal, 16).frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(IslandTheme.accentBlue.opacity(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.25 : 1), in: RoundedRectangle(cornerRadius: 10))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.hasLoaded)
            }
        }
        .disabled(saving)
        .onAppear {
            retainDraft()
            if task == nil {
                DispatchQueue.main.async { titleFocused = true }
            }
        }
        .onChange(of: draft) { _ in
            retainDraft()
            if !failedPlanning { failed = false }
        }
    }

    private var categoryName: String {
        settings.memoCategoryName(for: draft.categoryID)
    }

    private func appendStep() {
        let title = (draft.pendingStepTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        draft.subtasks = (draft.subtasks ?? []) + [SubtaskItem(title: title)]
        draft.pendingStepTitle = nil
    }

    private func editStep(_ id: UUID, _ change: (inout SubtaskItem) -> Void) {
        guard let index = draft.subtasks?.firstIndex(where: { $0.id == id }) else { return }
        change(&draft.subtasks![index])
    }

    private func draftStep(_ step: SubtaskItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Button { editStep(step.id) { $0.isCompleted.toggle() } } label: {
                    Image(systemName: step.isCompleted ? "checkmark.circle.fill" : "circle")
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(step.isCompleted ? "标记步骤未完成" : "完成步骤")
                TextField("步骤标题", text: Binding(
                    get: { step.title },
                    set: { value in editStep(step.id) { $0.title = value } }
                )).textFieldStyle(.roundedBorder)
                Button { draft.subtasks?.removeAll { $0.id == step.id } } label: {
                    Image(systemName: "minus.circle")
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("移除步骤：" + step.title)
            }
            HStack {
                if settings.memoPrioritiesEnabled {
                    Picker("步骤优先级", selection: Binding(
                        get: { step.priority ?? .blue },
                        set: { value in editStep(step.id) { $0.priority = value } }
                    )) {
                        ForEach(TaskPriority.allCases, id: \.self) { priority in
                            Text(settings.priorityName(for: priority)).tag(priority)
                        }
                    }.frame(maxWidth: 220)
                }
                if settings.memoDueDatesEnabled {
                    Toggle("步骤截止时间", isOn: Binding(
                        get: { step.dueDate != nil },
                        set: { value in editStep(step.id) { $0.dueDate = value ? .now.addingTimeInterval(3600) : nil } }
                    )).toggleStyle(.checkbox)
                    if let date = step.dueDate {
                        DatePicker("步骤截止", selection: Binding(
                            get: { date },
                            set: { value in editStep(step.id) { $0.dueDate = value } }
                        )).labelsHidden()
                    }
                }
                Spacer(minLength: 0)
            }.padding(.leading, 48).frame(minHeight: 44)
        }
    }

    private func retainDraft() {
        if let data = try? JSONEncoder().encode(draft) { AppEnvironment.defaults.set(data, forKey: draftKey) }
    }

    private func save() {
        guard !saving else { return }
        appendStep()
        retainDraft()
        let submitted = draft
        saving = true
        Task { @MainActor in
            let success = await store.saveDetails(id: submitted.id, title: submitted.title, notes: submitted.notes,
                dueDate: submitted.dueDate, priority: submitted.priority, categoryID: submitted.categoryID,
                subtasks: submitted.subtasks)
            if success {
                let planned = await onSaved?(submitted.id, submitted.plannedDay) ?? true
                saving = false
                if planned {
                    failedPlanning = false
                    AppEnvironment.defaults.removeObject(forKey: draftKey)
                    onClose()
                } else {
                    failedPlanning = true
                    failed = true
                    retainDraft()
                }
            } else {
                saving = false
                failed = true
            }
        }
    }
}
