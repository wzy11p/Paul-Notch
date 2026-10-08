import Foundation

/// Holds only synthetic writes, with a deadline so a regression cannot hang the runner.
private final class StoreCommitProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSignal = DispatchSemaphore(value: 0)
    private var failWrites = false
    private var blockNextWrite = false
    private var entered = false

    var isBlocked: Bool { lock.withLock { entered } }

    func fail(_ value: Bool) { lock.withLock { failWrites = value } }

    func blockNext() {
        lock.withLock {
            blockNextWrite = true
            entered = false
        }
    }

    func release() { releaseSignal.signal() }

    func beforeCommit() throws {
        let shouldBlock = lock.withLock {
            let result = blockNextWrite
            blockNextWrite = false
            if result { entered = true }
            return result
        }
        if shouldBlock {
            guard releaseSignal.wait(timeout: .now() + 5) == .success else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        if lock.withLock({ failWrites }) { throw CocoaError(.fileWriteNoPermission) }
    }
}

@main
@MainActor
struct NoteStoreValidation {
    static func require(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }

    static func folder(_ name: String, in root: URL) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func waitUntil(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        require(condition(), message)
    }

    static func sample(_ body: String) -> NoteItem {
        let date = Date(timeIntervalSinceReferenceDate: 810_530_456.125)
        return NoteItem(id: UUID(), body: body, categoryID: "daily", createdAt: date,
                        updatedAt: date, trashedAt: nil)
    }

    static func writeFixture(_ library: NoteLibrary, to directory: URL) throws -> Data {
        let bytes = try JSONEncoder().encode(library)
        try bytes.write(to: directory.appendingPathComponent("notes-v1.json"), options: .atomic)
        return bytes
    }

    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Pass a synthetic fixture directory") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try await rapidDraftAndRestart(in: root)
        try await independentDraftsAndCommit(in: root)
        try await categoryCallbackIdentity(in: root)
        try await failedPersistence(in: root)
        try await failedLoad(in: root)
        try await safeRetry(in: root)
        try await flushThenCommit(in: root)
        try await terminationFlush(in: root)
        print("PASS: NoteStore rapid autosave, exact Unicode, independent drafts/restart, category callback identity, commit/retry identity, failure retention, duplicate prevention, ordered flush/commit and termination flush during commit/trash")
    }

    static func rapidDraftAndRestart(in root: URL) async throws {
        let directory = try folder("rapid-draft", in: root)
        let store = NoteStore(repository: LocalNoteRepository(directory: directory))
        require(!store.canCommit, "Unloaded stores cannot commit")
        await store.load()
        require(store.isLoaded && !store.isLoading && store.errorMessage == nil, "Empty load completes")
        let draftID = store.draft.id
        require(!store.canCommit, "Empty draft cannot commit")
        store.updateBody(" \t\r\n")
        require(!store.canCommit, "Whitespace-only draft cannot commit")
        for index in 0..<150 { store.updateBody("输入中：第 \(index) 次\n第二行") }
        let exact = " \r\n中文标题 日本語 한국어\n正文 👩🏽‍💻 e\u{301}\r\n\t末行  \n"
        store.updateBody(exact)
        store.updateCategory("work")
        let file = directory.appendingPathComponent("notes-v1.json")
        try await waitUntil("Debounced draft autosave must finish without explicit flush") {
            FileManager.default.fileExists(atPath: file.path)
        }
        let saved = try await LocalNoteRepository(directory: directory).load()
        require(saved.notes.isEmpty, "Autosave must not implicitly commit a note")
        require(saved.drafts["new"] == NoteDraft(id: draftID, body: exact, categoryID: "work"),
                "Rapid changes autosave the exact final text, category and stable draft ID")
        require(saved.drafts["new"].map { Data($0.body.utf8) } == Data(exact.utf8),
                "Persistence preserves exact UTF-8, including decomposed accents, CRLF and whitespace")
        await store.flushDraft()
        let restarted = NoteStore(repository: LocalNoteRepository(directory: directory))
        await restarted.load()
        require(restarted.draft == store.draft && restarted.hasDraftChanges && restarted.canCommit,
                "Restart restores the complete pending new draft")
        await restarted.load()
        require(restarted.draft.id == draftID, "Repeated load does not replace restored draft identity")
    }

    static func independentDraftsAndCommit(in root: URL) async throws {
        let directory = try folder("independent-drafts", in: root)
        let first = sample("第一条\n原始正文")
        let second = sample("第二条\n原始正文")
        _ = try writeFixture(NoteLibrary(notes: [first, second]), to: directory)
        let store = NoteStore(repository: LocalNoteRepository(directory: directory))
        await store.load()
        let newBody = "尚未记下的新草稿\n留到下一次"
        store.updateBody(newBody)
        store.updateCategory("ideas")
        let newDraft = store.draft
        store.select(first)
        require(!store.hasDraftChanges && store.draft.body == first.body, "Selecting a note starts from its saved body")
        let firstBody = "第一条修订\n正文修改\n最后换行\n"
        store.updateBody(firstBody)
        store.updateCategory("work")
        require(store.hasDraft(for: first), "Edited note reports a retained draft")
        store.select(second)
        store.updateBody("第二条修订\n单独保留")
        store.updateCategory(nil)
        let secondDraft = store.draft
        store.select(nil)
        require(store.draft == newDraft, "Switching back to new restores its separate draft")
        require(store.library.notes == [first, second], "Per-note draft edits leave saved notes intact")
        await store.flushDraft()

        let restarted = NoteStore(repository: LocalNoteRepository(directory: directory))
        await restarted.load()
        require(restarted.draft == newDraft, "New draft survives restart alongside note drafts")
        restarted.select(second)
        require(restarted.draft == secondDraft, "Second note retains its own body and nil category")
        restarted.select(first)
        require(restarted.draft.body == firstBody && restarted.draft.categoryID == "work", "First note draft survives restart")
        require(await restarted.commit(), "Existing note commit succeeds")
        let edited = restarted.library.notes.first { $0.id == first.id }
        require(edited?.body == firstBody && edited?.categoryID == "work" && edited?.createdAt == first.createdAt,
                "Committing edits updates one note while retaining its identity and creation date")
        require(restarted.library.notes.count == 2 && restarted.library.drafts[first.id.uuidString] == nil,
                "Existing note commit does not duplicate a note and removes only its draft")
        require(restarted.draft == newDraft && restarted.library.drafts[second.id.uuidString] == secondDraft,
                "Existing note commit returns to the retained new draft and preserves another note draft")
        require(await restarted.commit(), "Retained new draft commits successfully")
        require(restarted.isNew && restarted.draft.body.isEmpty && restarted.draft.id != newDraft.id,
                "Successful new commit resets the composer with a new identity")
        require(!(await restarted.commit()), "Second commit of the cleared composer must be ignored")
        let saved = try await LocalNoteRepository(directory: directory).load()
        require(saved.notes.count == 3 && saved.notes.filter { $0.id == newDraft.id }.count == 1,
                "Committed new note survives restart exactly once")
        require(saved.notes.first { $0.id == newDraft.id }?.body == newBody,
                "Committed new note retains exact text")
        require(saved.drafts[second.id.uuidString] == secondDraft, "Uncommitted other-note draft remains on disk")
    }

    static func categoryCallbackIdentity(in root: URL) async throws {
        let directory = try folder("category-callback-identity", in: root)
        let first = sample("先前选中的笔记")
        let second = sample("后来选中的笔记")
        _ = try writeFixture(NoteLibrary(notes: [first, second]), to: directory)
        let store = NoteStore(repository: LocalNoteRepository(directory: directory))
        await store.load()
        store.select(first)
        let priorNoteDraftID = store.draft.id
        store.updateCategory("work", forDraftID: priorNoteDraftID)
        require(store.draft.categoryID == "work", "Matching captured existing-note draft ID can update its category")
        store.select(second)
        let secondDraftID = store.draft.id
        let beforeStaleNoteCallback = store.library
        store.updateCategory("wrong-note", forDraftID: priorNoteDraftID)
        require(store.library == beforeStaleNoteCallback,
                "Delayed callback for a prior note cannot mutate another selected note's draft")
        store.updateCategory(nil, forDraftID: secondDraftID)
        require(store.draft.categoryID == nil, "Matching current draft ID can also clear a category")

        store.select(nil)
        store.updateBody("新笔记记下后，旧菜单不能修改下一条")
        let committedDraftID = store.draft.id
        let beforeStaleNewCallback = store.library
        store.updateCategory("wrong-new", forDraftID: priorNoteDraftID)
        require(store.library == beforeStaleNewCallback,
                "Delayed callback for an existing note cannot assign a category to the new composer")
        store.updateCategory("ideas", forDraftID: committedDraftID)
        require(await store.commit(), "New draft with matching category callback commits")
        require(store.library.notes.first { $0.id == committedDraftID }?.categoryID == "ideas",
                "Matching new-draft category is included in the committed note")
        require(store.draft.id != committedDraftID, "Successful commit creates a different current draft ID")
        let beforeCommittedCallback = store.library
        store.updateCategory("too-late", forDraftID: committedDraftID)
        require(store.library == beforeCommittedCallback,
                "Delayed callback for an already committed new draft cannot alter the next composer")
        store.select(second)
        let beforeOtherDraftCallback = store.library
        store.updateCategory("too-late", forDraftID: committedDraftID)
        require(store.library == beforeOtherDraftCallback,
                "Delayed callback for a committed draft cannot alter another currently selected note")
        store.updateCategory("personal", forDraftID: secondDraftID)
        require(store.draft.categoryID == "personal", "Matching callback remains usable after ignored stale callbacks")
        await store.flushDraft()
        let saved = try await LocalNoteRepository(directory: directory).load()
        require(saved == store.library, "Only categories accepted for the matching drafts persist across restart")
    }

    static func failedPersistence(in root: URL) async throws {
        let directory = try folder("failed-persistence", in: root)
        let note = sample("原笔记\n不能覆盖")
        let original = try writeFixture(NoteLibrary(notes: [note]), to: directory)
        let probe = StoreCommitProbe()
        let store = NoteStore(repository: LocalNoteRepository(directory: directory, beforeCommit: { try probe.beforeCommit() }))
        await store.load()
        store.select(note)
        store.updateBody("失败后仍保留\n中文编辑正文\n")
        store.updateCategory("work")
        let editDraft = store.draft
        probe.fail(true)
        await store.flushDraft()
        require(store.errorMessage != nil && store.draft == editDraft && store.selectedNote == note,
                "Failed autosave retains draft text and original saved note")
        require(!(await store.commit()), "Injected commit failure returns false")
        require(!store.isSaving && store.canCommit && store.draft == editDraft && store.selectedKey == note.id.uuidString,
                "Failed commit re-enables retry without clearing text or changing selection")
        let file = directory.appendingPathComponent("notes-v1.json")
        require(try Data(contentsOf: file) == original, "Failed draft and note commits preserve the exact original bytes")
        probe.fail(false)
        require(await store.commit(), "Existing-note commit retries after disk recovery")
        require(store.library.notes.count == 1 && store.library.notes[0].body == editDraft.body,
                "Retry updates the original note exactly once")
        require(store.errorMessage == nil, "Successful retry clears the persistence error")

        store.updateBody("新笔记失败重试\n同一个 ID")
        let newDraft = store.draft
        let beforeNewCommit = try Data(contentsOf: file)
        probe.fail(true)
        require(!(await store.commit()), "New-note commit also reports a disk failure")
        require(store.draft == newDraft && store.library.notes.count == 1,
                "Failed new-note commit retains stable retry identity without publishing a phantom note")
        require(try Data(contentsOf: file) == beforeNewCommit, "Failed new commit leaves the latest saved library exact")
        probe.fail(false)
        require(await store.commit(), "New-note commit retries successfully")
        require(!(await store.commit()), "Immediate duplicate retry is rejected after success")
        let saved = try await LocalNoteRepository(directory: directory).load()
        require(saved.notes.count == 2 && saved.notes.filter { $0.id == newDraft.id }.count == 1,
                "Failed new commit followed by retry stores exactly one note")
    }

    static func failedLoad(in root: URL) async throws {
        let directory = try folder("failed-load", in: root)
        let file = directory.appendingPathComponent("notes-v1.json")
        let damaged = Data("{ broken synthetic JSON".utf8)
        try damaged.write(to: file)
        let store = NoteStore(repository: LocalNoteRepository(directory: directory), legacyText: { "Do not import over a damaged file" })
        await store.load()
        require(!store.isLoaded && !store.isLoading && store.errorMessage != nil, "Damaged file leaves the store unloaded with an error")
        store.updateBody("Must not overwrite damaged bytes")
        await store.flushDraft()
        require(!(await store.commit()) && !store.canCommit, "Failed load blocks writing and committing")
        require(try Data(contentsOf: file) == damaged, "Failed load and attempted edits preserve damaged original bytes")
    }

    static func safeRetry(in root: URL) async throws {
        let directory = try folder("safe-retry", in: root)
        let note = sample("原始笔记\n保存版本")
        let originalBytes = try writeFixture(NoteLibrary(notes: [note]), to: directory)
        let file = directory.appendingPathComponent("notes-v1.json")
        let store = NoteStore(repository: LocalNoteRepository(directory: directory))
        await store.load()
        store.select(note)
        store.updateBody("RAM 中的修改\n不能因重试丢失")
        let pending = store.library
        let selectedKey = store.selectedKey
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        await store.retrySaving()
        require(store.isLoaded && store.errorMessage != nil && store.library == pending && store.selectedKey == selectedKey,
                "Temporary read failure retains loaded RAM drafts and selection")
        await store.retrySaving()
        require(store.errorMessage != nil && store.library == pending, "Failed retry does not clear RAM drafts")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        require(try Data(contentsOf: file) == originalBytes, "Failed retry leaves original exact bytes intact")
        await store.retrySaving()
        require(store.errorMessage == nil && store.library == pending && store.selectedKey == selectedKey,
                "Restored read access makes the same Retry action succeed without reloading over RAM")
        require(try await LocalNoteRepository(directory: directory).load() == pending,
                "Successful retry saves drafts without implicitly committing them")

        let trustedBytes = try Data(contentsOf: file)
        store.updateBody("磁盘外部修改时的新草稿\n仍要保留")
        let conflictDrafts = store.library
        var external = pending
        external.notes[0].body = "另一个编辑器保存的版本\n不可覆盖"
        let externalBytes = try writeFixture(external, to: directory)
        await store.retrySaving()
        await store.retrySaving()
        require(store.errorMessage != nil && store.library == conflictDrafts && store.selectedKey == selectedKey,
                "Retries of a real conflict retain all RAM notes and drafts")
        require(try Data(contentsOf: file) == externalBytes,
                "Retries of a real conflict retain the external disk version exactly")
        // Restoration is an explicit fixture action, never performed by Retry.
        try trustedBytes.write(to: file, options: .atomic)
        await store.retrySaving()
        require(store.errorMessage == nil && store.library == conflictDrafts,
                "Explicit restoration of exact trusted bytes unlocks Retry without dropping drafts")
        require(try await LocalNoteRepository(directory: directory).load() == conflictDrafts,
                "Retry persists the retained drafts after exact-byte restoration")
    }

    static func flushThenCommit(in root: URL) async throws {
        let directory = try folder("flush-then-commit", in: root)
        let probe = StoreCommitProbe()
        let store = NoteStore(repository: LocalNoteRepository(directory: directory, beforeCommit: { try probe.beforeCommit() }))
        await store.load()
        store.updateBody("较早的草稿快照")
        let draftID = store.draft.id
        probe.blockNext()
        defer { probe.release() }
        let earlierFlush = Task { await store.flushDraft() }
        try await waitUntil("Earlier draft flush must enter repository write") { probe.isBlocked }
        let finalBody = "等待写入时继续编辑\n最终正文 👨‍👩‍👧‍👦\n"
        store.updateBody(finalBody)
        store.updateCategory("work")
        let commit = Task { await store.commit() }
        try await waitUntil("Commit must become pending behind the draft write") { store.isSaving }
        require(!(await store.commit()), "Concurrent duplicate commit must return false while a commit is active")
        probe.release()
        await earlierFlush.value
        require(await commit.value, "Commit after an older draft flush succeeds")
        let saved = try await LocalNoteRepository(directory: directory).load()
        require(saved.notes.count == 1 && saved.notes[0].id == draftID && saved.notes[0].body == finalBody,
                "Queued commit contains the latest text and older flush cannot overwrite it")
        require(saved.notes[0].categoryID == "work" && saved.drafts["new"] == nil,
                "Queued commit removes the committed draft and retains the latest category")
        require(store.errorMessage == nil && store.draft.body.isEmpty, "Stale flush completion does not restore old composer contents")
    }

    static func terminationFlush(in root: URL) async throws {
        for action in ["commit", "trash", "restore"] {
            let directory = try folder("termination-\(action)", in: root)
            var note = sample("已记下\n保留正文")
            if action == "restore" { note.trashedAt = Date(timeIntervalSinceReferenceDate: 810_531_000) }
            _ = try writeFixture(NoteLibrary(notes: [note]), to: directory)
            let probe = StoreCommitProbe()
            let store = NoteStore(repository: LocalNoteRepository(directory: directory, beforeCommit: { try probe.beforeCommit() }))
            await store.load()
            store.select(note)
            if action != "restore" { store.updateBody("未提交修订\n终止时不能丢失") }
            let retainedDraft = store.draft
            probe.blockNext()
            let criticalWrite = Task {
                if action == "commit" { return await store.commit() }
                await store.setTrashed(action == "trash", note: note)
                return store.errorMessage == nil
            }
            try await waitUntil("Critical \(action) write must enter repository") { probe.isBlocked }
            var flushStarted = false
            var flushFinished = false
            let terminatingFlush = Task {
                flushStarted = true
                await store.flushDraft()
                flushFinished = true
            }
            try await waitUntil("Termination flush must start during \(action)") { flushStarted }
            require(store.isSaving && !flushFinished, "Termination flush must await the active \(action) write")
            probe.release()
            require(await criticalWrite.value, "Critical \(action) write must succeed")
            await terminatingFlush.value
            require(flushFinished && !store.isSaving && store.errorMessage == nil,
                    "Termination flush returns only after critical \(action) and final draft persistence")
            let saved = try await LocalNoteRepository(directory: directory).load()
            require(saved == store.library, "Termination flush persists the post-\(action) library, not an obsolete snapshot")
            require(saved.notes.count == 1 && saved.notes[0].id == note.id, "Critical \(action) retains one stable note identity")
            if action == "commit" {
                require(saved.notes[0].body == retainedDraft.body && saved.drafts[note.id.uuidString] == nil,
                        "Termination during commit cannot resurrect the pre-commit note or draft")
            } else {
                require((saved.notes[0].trashedAt != nil) == (action == "trash"), "Termination retains the completed trash/restore state")
                require(saved.notes[0].body == note.body && saved.drafts[note.id.uuidString] == retainedDraft,
                        "Trash/restore retains both original body and any separate note draft")
            }
        }
    }
}
