import Foundation
import Darwin

struct NoteItem: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var body: String
    var categoryID: String?
    var createdAt: Date
    var updatedAt: Date
    var trashedAt: Date?

    var title: String {
        let firstLine = body.split(whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return firstLine.map { String($0.trimmingCharacters(in: .whitespaces).prefix(80)) } ?? "无标题笔记"
    }

    var preview: String {
        let lines = body.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let content = lines.count > 1 ? lines.dropFirst().joined(separator: " ") : (lines.first ?? "")
        return String(content.prefix(160))
    }
}

struct NoteDraft: Codable, Equatable, Sendable {
    var id: UUID
    var body: String
    var categoryID: String?
}

struct NoteLibrary: Codable, Equatable, Sendable {
    var schemaVersion: Int = 1
    var notes: [NoteItem] = []
    var drafts: [String: NoteDraft] = [:]
}

enum NoteRepositoryError: LocalizedError {
    case notLoaded
    case unsupportedVersion(Int)
    case invalidLibrary(String)
    case oversizedFile
    case unsafeFile
    case changedOnDisk
    case backupConflict

    var errorDescription: String? {
        switch self {
        case .notLoaded: return "请先成功读取笔记，再尝试保存。"
        case .unsupportedVersion(let version): return "笔记文件版本 \(version) 暂不支持，原文件已保留。"
        case .invalidLibrary(let reason): return "笔记文件未通过校验：\(reason)。"
        case .oversizedFile: return "笔记文件超过 32 MB，原文件已保留。"
        case .unsafeFile: return "笔记路径不是普通文件或文件夹，未进行写入。"
        case .changedOnDisk: return "笔记文件已在其他位置修改或移除。请先复制未保存的草稿；恢复原文件后可重试。"
        case .backupConflict: return "已有迁移备份与旧笔记不一致，请保留两份内容后再处理。"
        }
    }
}

/// One actor owns this library. Call `load` successfully before the first `save`.
/// Dates use Codable's reference-date seconds to retain subsecond precision exactly.
actor LocalNoteRepository {
    static let maximumBodyBytes = 1_048_576
    static let maximumFileBytes = 33_554_432
    static let maximumNotes = 10_000

    private let directory: URL
    private let fileURL: URL
    private let legacyBackupURL: URL
    private let editBackupURL: URL
    private let beforeCommit: @Sendable () throws -> Void
    private var hasLoaded = false
    private var loadedBytes: Data?

    /// The hook supports deterministic disk-failure tests; normal callers omit it.
    /// Construction does not read preferences, create directories, or write files.
    init(directory: URL, beforeCommit: @escaping @Sendable () throws -> Void = {}) {
        self.directory = directory
        fileURL = directory.appendingPathComponent("notes-v1.json")
        legacyBackupURL = directory.appendingPathComponent("quick-note-before-library-v1.txt")
        editBackupURL = directory.appendingPathComponent("notes-before-first-edit-v1.json")
        self.beforeCommit = beforeCommit
    }

    func load(legacyText: String? = nil) async throws -> NoteLibrary {
        hasLoaded = false
        try checkDirectory()
        if let bytes = try readFileIfPresent(fileURL) {
            let library = try decode(bytes)
            loadedBytes = bytes
            hasLoaded = true
            return library
        }

        var library = NoteLibrary()
        if let legacyText, !legacyText.isEmpty {
            let now = Date()
            library.notes = [NoteItem(id: UUID(), body: legacyText, categoryID: nil,
                                      createdAt: now, updatedAt: now, trashedAt: nil)]
            let bytes = try encode(library)
            try createDirectoryIfNeeded()
            let legacyBytes = Data(legacyText.utf8)
            if let backup = try readFileIfPresent(legacyBackupURL) {
                guard backup == legacyBytes else { throw NoteRepositoryError.backupConflict }
            } else {
                try atomicWrite(legacyBytes, to: legacyBackupURL, replacing: false)
            }
            try beforeCommit()
            guard try readFileIfPresent(fileURL) == nil else { throw NoteRepositoryError.changedOnDisk }
            try atomicWrite(bytes, to: fileURL, replacing: false)
            loadedBytes = bytes
        } else {
            loadedBytes = nil
        }
        hasLoaded = true
        return library
    }

    func save(_ library: NoteLibrary) async throws {
        guard hasLoaded else { throw NoteRepositoryError.notLoaded }
        let bytes = try encode(library)
        try checkUnchangedOnDisk()
        guard bytes != loadedBytes else { return }
        try createDirectoryIfNeeded()
        if let original = loadedBytes {
            // Keep the first existing library verbatim, including whitespace/key order.
            // Never replace an earlier rollback copy, even after future edits/restarts.
            if try readFileIfPresent(editBackupURL) == nil {
                try atomicWrite(original, to: editBackupURL, replacing: false)
            }
        }
        try beforeCommit()
        try checkUnchangedOnDisk()
        try atomicWrite(bytes, to: fileURL, replacing: loadedBytes != nil)
        loadedBytes = bytes
    }

    private func checkUnchangedOnDisk() throws {
        // Keep the last trusted snapshot after a failed check. A later save must
        // independently match those exact bytes, so restored access can recover
        // without reloading over the caller's unsaved drafts. Changed files stay blocked.
        try checkDirectory()
        guard try readFileIfPresent(fileURL) == loadedBytes else {
            throw NoteRepositoryError.changedOnDisk
        }
    }

    private func decode(_ bytes: Data) throws -> NoteLibrary {
        struct Version: Decodable { var schemaVersion: Int }
        let decoder = JSONDecoder()
        let version = try decoder.decode(Version.self, from: bytes).schemaVersion
        guard version == 1 else { throw NoteRepositoryError.unsupportedVersion(version) }
        let library = try decoder.decode(NoteLibrary.self, from: bytes)
        try validate(library)
        return library
    }

    private func encode(_ library: NoteLibrary) throws -> Data {
        try validate(library)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bytes = try encoder.encode(library)
        guard bytes.count <= Self.maximumFileBytes else { throw NoteRepositoryError.oversizedFile }
        return bytes
    }

    private func validate(_ library: NoteLibrary) throws {
        guard library.schemaVersion == 1 else { throw NoteRepositoryError.unsupportedVersion(library.schemaVersion) }
        guard library.notes.count <= Self.maximumNotes, library.drafts.count <= Self.maximumNotes + 1 else {
            throw NoteRepositoryError.invalidLibrary("笔记或草稿数量超过 10,000 条上限")
        }
        var ids = Set<UUID>()
        for note in library.notes {
            guard ids.insert(note.id).inserted else { throw NoteRepositoryError.invalidLibrary("笔记 ID 重复") }
            try validateText(note.body, categoryID: note.categoryID)
            guard note.createdAt.timeIntervalSinceReferenceDate.isFinite,
                  note.updatedAt.timeIntervalSinceReferenceDate.isFinite,
                  note.trashedAt?.timeIntervalSinceReferenceDate.isFinite ?? true else {
                throw NoteRepositoryError.invalidLibrary("日期无效")
            }
        }
        for (key, draft) in library.drafts {
            try validateText(draft.body, categoryID: draft.categoryID)
            if key == "new" {
                guard !ids.contains(draft.id) else { throw NoteRepositoryError.invalidLibrary("新草稿 ID 与已记下的笔记重复") }
            } else {
                guard key == draft.id.uuidString, ids.contains(draft.id) else {
                    throw NoteRepositoryError.invalidLibrary("草稿标识或关联笔记无效")
                }
            }
        }
    }

    private func validateText(_ body: String, categoryID: String?) throws {
        guard body.utf8.count <= Self.maximumBodyBytes else {
            throw NoteRepositoryError.invalidLibrary("单条笔记或草稿超过 1 MB，正文未被截断")
        }
        if let categoryID {
            guard !categoryID.isEmpty, categoryID.utf8.count <= 256 else {
                throw NoteRepositoryError.invalidLibrary("分类标识无效")
            }
        }
    }

    private func checkDirectory() throws {
        guard directory.isFileURL else { throw NoteRepositoryError.unsafeFile }
        if let attributes = try attributesIfPresent(directory), attributes[.type] as? FileAttributeType != .typeDirectory {
            throw NoteRepositoryError.unsafeFile
        }
    }

    private func createDirectoryIfNeeded() throws {
        try checkDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    private func attributesIfPresent(_ url: URL) throws -> [FileAttributeKey: Any]? {
        do { return try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { return nil }
    }

    private func readFileIfPresent(_ url: URL) throws -> Data? {
        guard let attributes = try attributesIfPresent(url) else { return nil }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw NoteRepositoryError.unsafeFile }
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? Int64.max
        guard fileSize <= Int64(Self.maximumFileBytes) else {
            throw NoteRepositoryError.oversizedFile
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: Self.maximumFileBytes + 1) ?? Data()
        guard bytes.count <= Self.maximumFileBytes else { throw NoteRepositoryError.oversizedFile }
        return bytes
    }

    /// A fully written sibling is published with rename (replace) or link (exclusive create).
    /// Both operations are atomic on this filesystem; failed commits retain the old file.
    private func atomicWrite(_ bytes: Data, to destination: URL, replacing: Bool) throws {
        let staging = directory.appendingPathComponent(".notes-\(UUID().uuidString).tmp")
        let descriptor = staging.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: staging)
        }
        try handle.write(contentsOf: bytes)
        try handle.synchronize()
        let result = staging.path.withCString { source in
            destination.path.withCString { target in
                replacing ? Darwin.rename(source, target) : Darwin.link(source, target)
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
