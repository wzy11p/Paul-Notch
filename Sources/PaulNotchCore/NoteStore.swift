import Foundation
import Combine

@MainActor
final class NoteStore: ObservableObject {
    @Published private(set) var library = NoteLibrary()
    @Published private(set) var selectedKey = "new"
    @Published private(set) var isLoaded = false
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var status = ""
    @Published private(set) var errorMessage: String?
    @Published var isEditing = false
    @Published private(set) var composingDraftID: UUID?

    private let repository: LocalNoteRepository
    private let legacyText: () -> String?
    private var pendingDraft: Task<Void, Never>?
    private var writeTail: Task<Void, Error>?
    private var saveWaiters: [CheckedContinuation<Void, Never>] = []
    private var revision = 0

    init(repository: LocalNoteRepository, legacyText: @escaping () -> String? = { nil }) {
        self.repository = repository
        self.legacyText = legacyText
    }

    var notes: [NoteItem] {
        library.notes.sorted { $0.updatedAt > $1.updatedAt }
    }
    var selectedNote: NoteItem? { library.notes.first { $0.id.uuidString == selectedKey } }
    var draft: NoteDraft { library.drafts[selectedKey] ?? NoteDraft(id: UUID(), body: "", categoryID: nil) }
    var isNew: Bool { selectedKey == "new" }
    var canCommit: Bool {
        isLoaded && !isSaving && composingDraftID != draft.id && selectedNote?.trashedAt == nil && !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var hasDraftChanges: Bool {
        guard let draft = library.drafts[selectedKey] else { return false }
        guard let note = selectedNote else { return !draft.body.isEmpty }
        return draft.body != note.body || draft.categoryID != note.categoryID
    }
    func hasDraft(for note: NoteItem) -> Bool {
        guard let draft = library.drafts[note.id.uuidString] else { return false }
        return draft.body != note.body || draft.categoryID != note.categoryID
    }

    func load() async {
        guard !isLoaded, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            library = try await repository.load(legacyText: legacyText())
            isLoaded = true
            errorMessage = nil
            ensureDraft()
            status = draft.body.isEmpty ? "写下想法，标题会从首行生成" : "已恢复上次草稿"
        } catch {
            errorMessage = "笔记未能读取，原文件未覆盖。请检查存储位置后重试。\n\(error.localizedDescription)"
        }
    }

    func updateBody(_ body: String, forDraftID: UUID? = nil) {
        guard isLoaded, !isSaving, selectedNote?.trashedAt == nil else { return }
        guard forDraftID == nil || forDraftID == draft.id else { return }
        var current = draft
        guard current.body != body else { return }
        current.body = body
        library.drafts[selectedKey] = current
        scheduleDraft()
    }

    func updateComposition(_ composing: Bool, forDraftID: UUID) {
        guard isLoaded, draft.id == forDraftID else { return }
        let next = composing ? forDraftID : nil
        if composingDraftID != next { composingDraftID = next }
    }

    func updateCategory(_ categoryID: String?, forDraftID: UUID? = nil) {
        guard isLoaded, !isSaving, selectedNote?.trashedAt == nil else { return }
        guard forDraftID == nil || forDraftID == draft.id else { return }
        var current = draft
        current.categoryID = categoryID
        library.drafts[selectedKey] = current
        scheduleDraft()
    }

    func select(_ note: NoteItem?) {
        guard isLoaded, !isSaving else { return }
        selectedKey = note?.id.uuidString ?? "new"
        ensureDraft()
        if composingDraftID != draft.id { composingDraftID = nil }
        status = hasDraftChanges ? "草稿会自动保留；记下后进入记录" : (isNew ? "写下想法，标题会从首行生成" : "已记下")
    }

    /// Retry the current in-memory drafts. Reload only an initially unreadable
    /// store; reloading an already loaded store could discard unsaved content.
    func retrySaving() async {
        if isLoaded {
            await flushDraft()
        } else {
            await load()
        }
    }

    func flushDraft() async {
        pendingDraft?.cancel()
        pendingDraft = nil
        if isSaving {
            await withCheckedContinuation { saveWaiters.append($0) }
        }
        guard isLoaded else { return }
        let snapshot = library
        let currentRevision = revision
        do {
            try await enqueue(snapshot)
            if currentRevision == revision {
                errorMessage = nil
                status = hasDraftChanges ? "草稿已保留，尚未记下" : "已保存"
            }
        } catch {
            errorMessage = "草稿未能保存，文字仍在此处。请重试，暂时不要退出应用。\n\(error.localizedDescription)"
        }
    }

    @discardableResult
    func commit() async -> Bool {
        guard canCommit else { return false }
        pendingDraft?.cancel()
        isSaving = true
        defer { finishSaving() }
        let current = draft
        let now = Date()
        var candidate = library
        if let index = candidate.notes.firstIndex(where: { $0.id == current.id }) {
            candidate.notes[index].body = current.body
            candidate.notes[index].categoryID = current.categoryID
            candidate.notes[index].updatedAt = now
        } else {
            candidate.notes.append(NoteItem(id: current.id, body: current.body, categoryID: current.categoryID,
                                            createdAt: now, updatedAt: now, trashedAt: nil))
        }
        candidate.drafts.removeValue(forKey: selectedKey)
        do {
            try await enqueue(candidate)
            library = candidate
            revision += 1
            selectedKey = "new"
            ensureDraft()
            errorMessage = nil
            status = "已记下，可以继续写下一条"
            return true
        } catch {
            errorMessage = "没有记下，草稿和原笔记都还在。请重试。\n\(error.localizedDescription)"
            return false
        }
    }

    func setTrashed(_ trashed: Bool, note: NoteItem) async {
        guard isLoaded, !isSaving, let index = library.notes.firstIndex(where: { $0.id == note.id }) else { return }
        pendingDraft?.cancel()
        isSaving = true
        defer { finishSaving() }
        var candidate = library
        candidate.notes[index].trashedAt = trashed ? Date() : nil
        do {
            try await enqueue(candidate)
            library = candidate
            revision += 1
            selectedKey = "new"
            ensureDraft()
            errorMessage = nil
            status = trashed ? "已移到回收站，可以恢复" : "已恢复笔记"
        } catch {
            errorMessage = "操作未保存，原笔记仍保留。请重试。\n\(error.localizedDescription)"
        }
    }

    private func ensureDraft() {
        guard library.drafts[selectedKey] == nil else { return }
        if let note = selectedNote {
            library.drafts[selectedKey] = NoteDraft(id: note.id, body: note.body, categoryID: note.categoryID)
        } else {
            library.drafts["new"] = NoteDraft(id: UUID(), body: "", categoryID: nil)
        }
    }

    private func finishSaving() {
        isSaving = false
        let waiters = saveWaiters
        saveWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func scheduleDraft() {
        revision += 1
        status = "正在保留草稿…"
        pendingDraft?.cancel()
        pendingDraft = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.flushDraft()
        }
    }

    private func enqueue(_ snapshot: NoteLibrary) async throws {
        let predecessor = writeTail
        let repository = repository
        let job = Task {
            _ = try? await predecessor?.value
            try await repository.save(snapshot)
        }
        writeTail = job
        try await job.value
    }
}
