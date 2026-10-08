import Foundation

private final class CommitFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false

    func set(_ value: Bool) { lock.withLock { enabled = value } }
    func check() throws {
        if lock.withLock({ enabled }) { throw CocoaError(.fileWriteNoPermission) }
    }
}

@main
struct NoteRepositoryValidation {
    static func require(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }

    static func fails(_ message: String, _ action: () async throws -> Void) async {
        do {
            try await action()
            preconditionFailure(message)
        } catch { }
    }

    static func folder(_ name: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func sample(body: String = "标题\n正文 👩🏽‍💻 e\u{301}") -> NoteItem {
        let date = Date(timeIntervalSinceReferenceDate: 810_530_456.125)
        return NoteItem(id: UUID(), body: body, categoryID: "daily", createdAt: date, updatedAt: date, trashedAt: nil)
    }

    static func writeFixture(_ library: NoteLibrary, to directory: URL) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        let bytes = try encoder.encode(library)
        try bytes.write(to: directory.appendingPathComponent("notes-v1.json"), options: .atomic)
        return bytes
    }

    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Pass a synthetic fixture directory") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try await emptyLibrary(in: root)
        try await migration(in: root)
        try await roundTrip(in: root)
        try await damagedFiles(in: root)
        try await invalidModels(in: root)
        try await writeFailures(in: root)
        try await externalChanges(in: root)
        try await transientReadRecovery(in: root)
        try await fileBoundaries(in: root)
        print("PASS: notes migration, exact backups/rollback, restart/drafts, Unicode, validation, fail-closed reads, write retry, external changes, trash/restore")
    }

    static func emptyLibrary(in root: URL) async throws {
        let directory = root.appendingPathComponent("initially-absent")
        let repository = LocalNoteRepository(directory: directory)
        require(!FileManager.default.fileExists(atPath: directory.path), "Initializer must not create a directory")
        await fails("Saving before a successful load must fail") { try await repository.save(NoteLibrary()) }
        let empty = try await repository.load()
        require(empty == NoteLibrary(), "Missing file loads empty v1")
        require(!FileManager.default.fileExists(atPath: directory.path), "Empty load must not create a directory")
        try await repository.save(empty)
        require(try await LocalNoteRepository(directory: directory).load() == empty, "Empty library restarts")
        require(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("notes-before-first-edit-v1.json").path),
                "First creation has no prior library to back up")
        let file = directory.appendingPathComponent("notes-v1.json")
        let before = try Data(contentsOf: file)
        try await repository.save(empty)
        require(try Data(contentsOf: file) == before, "Unchanged saves leave bytes alone")
    }

    static func migration(in root: URL) async throws {
        let directory = try folder("migration", in: root)
        let exactText = " \r\n\t旧笔记 📝  \r\n第二行\n\n组合 e\u{301} 和 👨‍👩‍👧‍👦\n\t"
        let repository = LocalNoteRepository(directory: directory)
        let migrated = try await repository.load(legacyText: exactText)
        require(migrated.schemaVersion == 1 && migrated.notes.count == 1 && migrated.drafts.isEmpty, "One legacy note migrates to schema v1")
        require(migrated.notes[0].body == exactText, "Migration must retain exact legacy body")
        require(migrated.notes[0].title == "旧笔记 📝", "Title uses the first nonblank line")
        let backup = directory.appendingPathComponent("quick-note-before-library-v1.txt")
        require(try Data(contentsOf: backup) == Data(exactText.utf8), "Legacy backup is exact UTF-8, including whitespace")
        let file = directory.appendingPathComponent("notes-v1.json")
        let firstBytes = try Data(contentsOf: file)
        let reloaded = try await LocalNoteRepository(directory: directory).load(legacyText: "old preference changed")
        require(reloaded == migrated, "Existing library never reimports legacy preference")
        require(try Data(contentsOf: file) == firstBytes, "Repeated load does not rewrite library")
        require(try Data(contentsOf: backup) == Data(exactText.utf8), "Migration backup never overwritten")

        let conflictDirectory = try folder("migration-backup-conflict", in: root)
        let originalBackup = Data("previous exact text".utf8)
        let conflictBackup = conflictDirectory.appendingPathComponent("quick-note-before-library-v1.txt")
        try originalBackup.write(to: conflictBackup)
        let conflictRepository = LocalNoteRepository(directory: conflictDirectory)
        await fails("Mismatched migration backup must block migration") { _ = try await conflictRepository.load(legacyText: exactText) }
        await fails("Failed migration must leave saving blocked") { try await conflictRepository.save(NoteLibrary()) }
        require(try Data(contentsOf: conflictBackup) == originalBackup, "Conflicting backup preserved")
        require(!FileManager.default.fileExists(atPath: conflictDirectory.appendingPathComponent("notes-v1.json").path), "No library created on migration conflict")
    }

    static func roundTrip(in root: URL) async throws {
        let directory = try folder("roundtrip", in: root)
        let note = sample()
        let initial = NoteLibrary(notes: [note])
        let originalBytes = try writeFixture(initial, to: directory)
        let repository = LocalNoteRepository(directory: directory)
        var library = try await repository.load()
        let second = sample(body: "另一个想法\n可搜索的长正文\n第三行")
        library.notes.append(second)
        let newDraft = NoteDraft(id: UUID(), body: "还没记下\n🚀\r\n保留最后换行\n", categoryID: nil)
        library.drafts["new"] = newDraft
        library.drafts[note.id.uuidString] = NoteDraft(id: note.id, body: note.body + "\n未提交修改", categoryID: "work")
        try await repository.save(library)
        let restarted = LocalNoteRepository(directory: directory)
        let restored = try await restarted.load(legacyText: "must not remigrate")
        require(restored == library, "Notes, categories, exact dates and per-note/new drafts survive restart")
        require(restored.drafts["new"]?.id == newDraft.id, "New draft retains stable retry identity")
        require(restored.notes[0].body == note.body, "Draft does not alter canonical note body")
        require(second.preview == "可搜索的长正文 第三行", "Preview uses later nonblank lines")
        var longTitle = sample(body: String(repeating: "👨‍👩‍👧‍👦", count: 90))
        require(longTitle.title.count == 80, "Titles bound by characters without splitting emoji")
        longTitle.body = " \n\t"
        require(longTitle.title == "无标题笔记" && longTitle.preview.isEmpty, "Blank title and preview are sensible")

        let backup = directory.appendingPathComponent("notes-before-first-edit-v1.json")
        require(try Data(contentsOf: backup) == originalBytes, "First-edit backup keeps exact pre-change JSON bytes")
        library.notes[0].trashedAt = Date(timeIntervalSinceReferenceDate: 810_531_000.25)
        try await restarted.save(library)
        require(try await LocalNoteRepository(directory: directory).load() == library, "Trash and retained draft round trip")
        library.notes[0].trashedAt = nil
        try await restarted.save(library)
        require(try await LocalNoteRepository(directory: directory).load() == library, "Restore round trip")
        require(try Data(contentsOf: backup) == originalBytes, "Later edits never replace rollback backup")
        let rollback = try folder("rollback-copy", in: root)
        try Data(contentsOf: backup).write(to: rollback.appendingPathComponent("notes-v1.json"), options: .atomic)
        require(try await LocalNoteRepository(directory: rollback).load() == initial, "Exact backup can restore initial note count and content")
    }

    static func damagedFiles(in root: URL) async throws {
        let fixtures = ["corrupt": "{ broken JSON", "future": "{\"schemaVersion\":2}",
                        "missing-version": "{\"notes\":[],\"drafts\":{}}", "old-version": "{\"schemaVersion\":0}"]
        for (name, content) in fixtures {
            let directory = try folder(name, in: root)
            let file = directory.appendingPathComponent("notes-v1.json")
            let bytes = Data(content.utf8)
            try bytes.write(to: file)
            let repository = LocalNoteRepository(directory: directory)
            await fails("Corrupt or unknown version must fail closed: \(name)") { _ = try await repository.load(legacyText: "do not migrate") }
            await fails("Failed load must never permit overwrite: \(name)") { try await repository.save(NoteLibrary()) }
            require(try Data(contentsOf: file) == bytes, "Invalid existing bytes stay exact: \(name)")
            require(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("quick-note-before-library-v1.txt").path),
                    "Invalid existing library never triggers migration")
        }
    }

    static func invalidModels(in root: URL) async throws {
        let note = sample()
        let oversized = NoteDraft(id: UUID(), body: String(repeating: "x", count: LocalNoteRepository.maximumBodyBytes + 1), categoryID: nil)
        let fixtures: [String: NoteLibrary] = [
            "duplicate-note": NoteLibrary(notes: [note, note]),
            "bad-draft-key": NoteLibrary(drafts: ["../new": NoteDraft(id: UUID(), body: "retained", categoryID: nil)]),
            "orphan-draft": NoteLibrary(drafts: [note.id.uuidString: NoteDraft(id: note.id, body: "retained", categoryID: nil)]),
            "draft-id-mismatch": NoteLibrary(notes: [note], drafts: [note.id.uuidString: NoteDraft(id: UUID(), body: "retained", categoryID: nil)]),
            "duplicate-new-id": NoteLibrary(notes: [note], drafts: ["new": NoteDraft(id: note.id, body: "retained", categoryID: nil)]),
            "oversized-body": NoteLibrary(drafts: ["new": oversized]),
            "empty-category": NoteLibrary(drafts: ["new": NoteDraft(id: UUID(), body: "retained", categoryID: "")])
        ]
        for (name, invalid) in fixtures {
            let directory = try folder(name, in: root)
            let original = try writeFixture(invalid, to: directory)
            let repository = LocalNoteRepository(directory: directory)
            await fails("Invalid persisted models must be rejected: \(name)") { _ = try await repository.load() }
            await fails("Invalid model must not overwrite file: \(name)") { try await repository.save(NoteLibrary()) }
            require(try Data(contentsOf: directory.appendingPathComponent("notes-v1.json")) == original, "Invalid file retained without truncation")
        }
        let directory = try folder("invalid-save", in: root)
        let repository = LocalNoteRepository(directory: directory)
        _ = try await repository.load()
        await fails("Oversized in-memory draft must fail without truncation") { try await repository.save(NoteLibrary(drafts: ["new": oversized])) }
        require(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("notes-v1.json").path), "Invalid save must not create a file")
    }

    static func writeFailures(in root: URL) async throws {
        let directory = try folder("write-failure", in: root)
        let originalLibrary = NoteLibrary(notes: [sample()])
        let original = try writeFixture(originalLibrary, to: directory)
        let failure = CommitFailure()
        let repository = LocalNoteRepository(directory: directory, beforeCommit: { try failure.check() })
        var candidate = try await repository.load()
        let draftID = UUID()
        candidate.notes.append(NoteItem(id: draftID, body: "失败后重试\n不能重复创建", categoryID: nil,
                                       createdAt: .now, updatedAt: .now, trashedAt: nil))
        failure.set(true)
        await fails("Injected commit failure must throw") { try await repository.save(candidate) }
        let file = directory.appendingPathComponent("notes-v1.json")
        require(try Data(contentsOf: file) == original, "Commit failure retains original exact file")
        require(try await LocalNoteRepository(directory: directory).load() == originalLibrary, "Failed write leaves a decodable original")
        require(try Data(contentsOf: directory.appendingPathComponent("notes-before-first-edit-v1.json")) == original, "Failed write preserves exact rollback backup")
        failure.set(false)
        try await repository.save(candidate)
        try await repository.save(candidate)
        let afterRetry = try await LocalNoteRepository(directory: directory).load()
        require(afterRetry == candidate && afterRetry.notes.filter({ $0.id == draftID }).count == 1, "Retry succeeds once with stable ID")
        require(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.hasSuffix(".tmp") }, "No staging files remain after commit")

        let migrationDirectory = try folder("migration-write-failure", in: root)
        let migrationFailure = CommitFailure()
        migrationFailure.set(true)
        let migrating = LocalNoteRepository(directory: migrationDirectory, beforeCommit: { try migrationFailure.check() })
        let legacy = "迁移失败也保留\n旧正文"
        await fails("Migration commit failure must throw") { _ = try await migrating.load(legacyText: legacy) }
        require(try Data(contentsOf: migrationDirectory.appendingPathComponent("quick-note-before-library-v1.txt")) == Data(legacy.utf8), "Legacy text backed up before failed commit")
        require(!FileManager.default.fileExists(atPath: migrationDirectory.appendingPathComponent("notes-v1.json").path), "Failed migration creates no partial library")
        migrationFailure.set(false)
        let retry = try await migrating.load(legacyText: legacy)
        require(retry.notes.count == 1 && retry.notes[0].body == legacy, "Migration retry imports exactly once")

        let readOnlyDirectory = try folder("real-disk-write-failure", in: root)
        let readOnlyOriginal = try writeFixture(originalLibrary, to: readOnlyDirectory)
        try readOnlyOriginal.write(to: readOnlyDirectory.appendingPathComponent("notes-before-first-edit-v1.json"))
        let readOnlyRepository = LocalNoteRepository(directory: readOnlyDirectory)
        _ = try await readOnlyRepository.load()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnlyDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readOnlyDirectory.path) }
        await fails("Real filesystem denial must fail the save") { try await readOnlyRepository.save(candidate) }
        require(try Data(contentsOf: readOnlyDirectory.appendingPathComponent("notes-v1.json")) == readOnlyOriginal,
                "Actual disk-write failure retains exact original bytes")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readOnlyDirectory.path)
        try await readOnlyRepository.save(candidate)
        require(try await LocalNoteRepository(directory: readOnlyDirectory).load() == candidate,
                "Write retries after filesystem access recovers")
    }

    static func externalChanges(in root: URL) async throws {
        let directory = try folder("outside-change", in: root)
        let repository = LocalNoteRepository(directory: directory)
        _ = try await repository.load()
        let original = NoteLibrary(notes: [sample()])
        try await repository.save(original)
        let external = NoteLibrary(notes: [sample(body: "outside editor latest")])
        let externalBytes = try writeFixture(external, to: directory)
        await fails("Outside modification must block stale save") { try await repository.save(original) }
        require(try Data(contentsOf: directory.appendingPathComponent("notes-v1.json")) == externalBytes, "Outside modifications remain exact")
        await fails("Conflict stays blocked while disk bytes differ") { try await repository.save(original) }
        require(try await repository.load() == external, "Explicit load recovers current disk version")
        var changed = external
        changed.notes[0].body += "\nreloaded safely"
        try await repository.save(changed)
        require(try await LocalNoteRepository(directory: directory).load() == changed, "Saving works after successful reload")
    }

    static func transientReadRecovery(in root: URL) async throws {
        let directory = try folder("transient-read-recovery", in: root)
        let original = NoteLibrary(notes: [sample()])
        let bytes = try writeFixture(original, to: directory)
        let file = directory.appendingPathComponent("notes-v1.json")
        let repository = LocalNoteRepository(directory: directory)
        var candidate = try await repository.load()
        candidate.drafts["new"] = NoteDraft(id: UUID(), body: "读取恢复后重试\n保留 RAM 草稿", categoryID: nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        await fails("Temporary read denial must block save") { try await repository.save(candidate) }
        await fails("Repeated read denial must still block save") { try await repository.save(candidate) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        require(try Data(contentsOf: file) == bytes, "Temporary read denial retains exact original")
        try await repository.save(candidate)
        require(try await LocalNoteRepository(directory: directory).load() == candidate,
                "Read access recovery allows retry without reloading or discarding candidate drafts")
    }

    static func fileBoundaries(in root: URL) async throws {
        let directory = try folder("unreadable-file", in: root)
        let original = try writeFixture(NoteLibrary(notes: [sample()]), to: directory)
        let file = directory.appendingPathComponent("notes-v1.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        let repository = LocalNoteRepository(directory: directory)
        await fails("Unreadable existing file must not load empty") { _ = try await repository.load() }
        await fails("Unreadable file must never be overwritten") { try await repository.save(NoteLibrary()) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        require(try Data(contentsOf: file) == original, "Unreadable original is retained")

        let symlinkDirectory = try folder("symlink", in: root)
        let link = symlinkDirectory.appendingPathComponent("notes-v1.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let linkedRepository = LocalNoteRepository(directory: symlinkDirectory)
        await fails("Symlink file must fail closed") { _ = try await linkedRepository.load() }
        await fails("Symlink file must not be replaced") { try await linkedRepository.save(NoteLibrary()) }
        require(try Data(contentsOf: file) == original, "Symlink target untouched")

        let oversizedDirectory = try folder("oversized-file", in: root)
        let oversizedFile = oversizedDirectory.appendingPathComponent("notes-v1.json")
        require(FileManager.default.createFile(atPath: oversizedFile.path, contents: nil), "Create sparse oversized fixture")
        let handle = try FileHandle(forWritingTo: oversizedFile)
        try handle.truncate(atOffset: UInt64(LocalNoteRepository.maximumFileBytes + 1))
        try handle.close()
        let oversizedRepository = LocalNoteRepository(directory: oversizedDirectory)
        await fails("Oversized file must be rejected before loading") { _ = try await oversizedRepository.load() }
        await fails("Oversized file must never be overwritten") { try await oversizedRepository.save(NoteLibrary()) }
        let size = try FileManager.default.attributesOfItem(atPath: oversizedFile.path)[.size] as? NSNumber
        require(size?.intValue == LocalNoteRepository.maximumFileBytes + 1, "Oversized original retained")
    }
}
