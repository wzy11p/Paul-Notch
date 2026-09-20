import Foundation

/// UI only depends on this protocol. Replace `LocalTaskRepository` with a server-backed
/// implementation later without changing the views or business logic.
protocol TaskRepository: Sendable {
    func load() async throws -> [TaskItem]
    func save(_ tasks: [TaskItem]) async throws
}

actor LocalTaskRepository: TaskRepository {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL customURL: URL? = nil) {
        let folder = customURL?.deletingLastPathComponent() ?? AppEnvironment.dataDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = customURL ?? folder.appendingPathComponent("tasks.json")

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func load() async throws -> [TaskItem] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try decoder.decode([TaskItem].self, from: Data(contentsOf: fileURL))
    }

    func save(_ tasks: [TaskItem]) async throws {
        // Preserve the exact pre-upgrade bytes once; never overwrite the rollback copy.
        let backup = fileURL.deletingLastPathComponent().appendingPathComponent("tasks-before-details-v2.json")
        if FileManager.default.fileExists(atPath: fileURL.path),
           !FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.copyItem(at: fileURL, to: backup)
        }
        try encoder.encode(tasks).write(to: fileURL, options: .atomic)
    }
}

/// Reserved integration point for the future API.
/// Implement load/save using URLSession, then inject this repository in AppDelegate.
actor RemoteTaskRepository: TaskRepository {
    let baseURL: URL

    init(baseURL: URL) { self.baseURL = baseURL }

    func load() async throws -> [TaskItem] {
        throw URLError(.unsupportedURL)
    }

    func save(_ tasks: [TaskItem]) async throws {
        throw URLError(.unsupportedURL)
    }
}
