import SwiftUI

struct NoteWorkspace: View {
    @ObservedObject var notes: NoteStore
    @ObservedObject var settings: AppSettingsStore
    @State private var query = ""
    @State private var showsTrash = false
    @State private var hoveredID: UUID?
    @State private var editorFocusRequest = 0

    private var matches: [NoteItem] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return notes.notes.filter {
            ($0.trashedAt != nil) == showsTrash &&
            (search.isEmpty || $0.body.localizedCaseInsensitiveContains(search) || categoryName($0.categoryID).localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            history.frame(width: 232)
            editor.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(IslandTheme.text1)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            notes.isEditing = true
            await notes.load()
            focusEditor()
        }
        .onDisappear {
            notes.isEditing = false
            notes.updateComposition(false, forDraftID: notes.draft.id)
            Task { await notes.flushDraft() }
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text(showsTrash ? "回收站" : "随笔记").font(.system(size: 16, weight: .semibold))
                Spacer(minLength: 0)
                Button {
                    showsTrash = false
                    query = ""
                    notes.select(nil)
                    focusEditor()
                } label: {
                    Label("新建", systemImage: "square.and.pencil")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 8).frame(height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(IslandTheme.accentBlue)
                .disabled(!notes.isLoaded || notes.isSaving)
                .accessibilityLabel("新建随笔")
                .keyboardShortcut("n", modifiers: .command)
                Button { showsTrash.toggle() } label: {
                    Image(systemName: showsTrash ? "tray" : "trash")
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(IslandTheme.text2)
                .accessibilityLabel(showsTrash ? "查看最近笔记" : "查看笔记回收站")
                .help(showsTrash ? "返回最近笔记" : "已删除的笔记可在这里恢复")
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(IslandTheme.text2)
                TextField("搜索内容或分类", text: $query).textFieldStyle(.plain)
                    .accessibilityLabel("搜索随笔")
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("清空笔记搜索")
                }
            }
            .font(.system(size: 13)).padding(.horizontal, 10).frame(height: 44)
            .background(IslandTheme.surface2, in: RoundedRectangle(cornerRadius: 10))

            if notes.isLoading {
                ProgressView("正在读取笔记…").padding(.top, 20)
            } else if matches.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(!query.isEmpty ? "没有匹配的笔记" : (showsTrash ? "回收站是空的" : "还没有记下的内容"))
                        .font(.system(size: 14, weight: .medium))
                    Text(!query.isEmpty ? "换个关键词试试。" : (showsTrash ? "移到这里的笔记可以恢复。" : "在右边写下第一条，点“记下”就会出现在这里。"))
                        .font(.system(size: 12)).foregroundStyle(IslandTheme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 16).padding(.horizontal, 8)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(matches) { note in
                            Button {
                                notes.select(note)
                                if !showsTrash { focusEditor() }
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(note.title).font(.system(size: 14, weight: .medium))
                                        .lineLimit(2).multilineTextAlignment(.leading)
                                    HStack(spacing: 6) {
                                        Text(note.updatedAt, format: .dateTime.month().day())
                                        Text(categoryName(note.categoryID)).lineLimit(1)
                                        if notes.hasDraft(for: note) { Text("草稿").foregroundStyle(IslandTheme.accentBlue) }
                                    }.font(.system(size: 11)).foregroundStyle(IslandTheme.text2)
                                }
                                .padding(12).frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
                                .background(notes.selectedKey == note.id.uuidString || hoveredID == note.id ? IslandTheme.surface3 : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 10))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).disabled(notes.isSaving)
                            .accessibilityLabel("打开笔记：" + note.title)
                            .accessibilityAddTraits(notes.selectedKey == note.id.uuidString ? .isSelected : [])
                            .onHover { hoveredID = $0 ? note.id : nil }
                        }
                    }
                }
            }
        }.frame(maxHeight: .infinity, alignment: .top)
    }

    private var editor: some View {
        let draftID = notes.draft.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(notes.selectedNote?.trashedAt != nil ? "已移到回收站" : (notes.isNew ? "记一条" : "编辑笔记"))
                    .font(.system(size: 16, weight: .semibold))
                Spacer(minLength: 0)
                Menu {
                    Button("暂不分类") { notes.updateCategory(nil, forDraftID: draftID) }
                    ForEach(settings.memoCategories) { category in
                        Button(category.name) { notes.updateCategory(category.id, forDraftID: draftID) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                        Text(categoryName(notes.draft.categoryID)).lineLimit(1)
                    }
                    .font(.system(size: 12)).padding(.horizontal, 8).frame(minWidth: 100, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).fixedSize()
                .frame(minWidth: 100, minHeight: 44).contentShape(Rectangle())
                .disabled(!notes.isLoaded || notes.isSaving || notes.selectedNote?.trashedAt != nil)
                .accessibilityLabel("笔记分类：" + categoryName(notes.draft.categoryID))
                if let note = notes.selectedNote, note.trashedAt == nil {
                    Button { Task { await notes.setTrashed(true, note: note) } } label: {
                        Image(systemName: "trash").frame(width: 44, height: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(IslandTheme.text2)
                        .disabled(notes.isSaving).accessibilityLabel("移到笔记回收站")
                        .help("可在回收站恢复；未提交的草稿也会保留")
                }
            }

            if let error = notes.errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(IslandTheme.accentOrange)
                    Text(error).font(.system(size: 12)).lineLimit(3).help(error)
                    Spacer(minLength: 0)
                    Button("重试") {
                        Task { await notes.retrySaving() }
                    }.buttonStyle(.plain).foregroundStyle(IslandTheme.accentBlue)
                        .frame(minWidth: 44, minHeight: 44).disabled(notes.isSaving)
                }
            }

            ZStack(alignment: .topLeading) {
                NoteTextEditor(draftID: draftID, text: notes.draft.body,
                               isEditable: notes.isLoaded && !notes.isSaving && notes.selectedNote?.trashedAt == nil,
                               focusRequest: editorFocusRequest) { id, body, composing in
                    notes.updateComposition(composing, forDraftID: id)
                    notes.updateBody(body, forDraftID: id)
                }
                    .id(draftID) // Each draft owns its native IME session and undo history.
                    .padding(10)
                if notes.draft.body.isEmpty {
                    Text("想到什么，先写下来…\n不用想标题，也不用先选分类。")
                        .font(.system(size: 16)).lineSpacing(5).foregroundStyle(IslandTheme.text2)
                        .padding(.horizontal, 16).padding(.vertical, 18)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(IslandTheme.surface2, in: RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 12) {
                Text(notes.isSaving ? "正在保存…" : notes.status)
                    .font(.system(size: 12)).foregroundStyle(IslandTheme.text2)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                if let note = notes.selectedNote, note.trashedAt != nil {
                    Button("恢复笔记") { Task { await notes.setTrashed(false, note: note) } }
                        .buttonStyle(NotePrimaryButtonStyle()).disabled(notes.isSaving)
                } else {
                    Button(notes.isNew ? "记下" : "保存修改") {
                        Task {
                            if await notes.commit() { showsTrash = false; query = ""; focusEditor() }
                        }
                    }
                    .buttonStyle(NotePrimaryButtonStyle()).disabled(!notes.canCommit)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help(notes.composingDraftID == draftID ? "请先确认拼音候选词" : "Command + Return；Enter 正常换行")
                }
            }.frame(minHeight: 44)
        }.frame(maxHeight: .infinity)
    }

    private func categoryName(_ id: String?) -> String {
        guard let id else { return "暂不分类" }
        return settings.memoCategories.first { $0.id == id }?.name ?? "原分类已移除"
    }

    private func focusEditor() {
        guard notes.isLoaded else { return }
        NSApp.windows.first { $0 is IslandPanel && $0.isVisible }?.makeKey()
        editorFocusRequest += 1
    }
}

private struct NotePrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 18).frame(minWidth: 90, minHeight: 44)
            .foregroundStyle(enabled ? Color.black : IslandTheme.text2)
            .background(enabled ? IslandTheme.accentBlue.opacity(configuration.isPressed ? 0.75 : 1) : IslandTheme.surface3,
                        in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
    }
}
