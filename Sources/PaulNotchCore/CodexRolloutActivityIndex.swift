import Foundation

/// Supplements the SQLite runtime index for older Codex tasks that are not
/// represented in `thread_turns`. Only lifecycle markers near the end of each
/// local rollout are inspected; prompts and responses are never retained.
actor IslandCodexRolloutActivityIndex {
    private enum LifecycleMarker: String, CaseIterable {
        case started = "\"type\":\"task_started\""
        case completed = "\"type\":\"task_complete\""
        case aborted = "\"type\":\"turn_aborted\""
    }

    private struct CacheEntry {
        let fileSize: UInt64
        let modificationDate: Date?
        let record: CodexTaskRuntimeRecord?
    }

    private let fileManager: FileManager
    private var cache: [String: CacheEntry] = [:]

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func latestStates(for tasks: [CodexTaskSummary]) -> [String: CodexTaskRuntimeRecord] {
        var result: [String: CodexTaskRuntimeRecord] = [:]
        for task in tasks {
            guard let path = task.rolloutPath, !path.isEmpty else { continue }
            let url = URL(fileURLWithPath: path)
            guard let attributes = try? fileManager.attributesOfItem(atPath: path),
                  let size = (attributes[.size] as? NSNumber)?.uint64Value else {
                continue
            }
            let modificationDate = attributes[.modificationDate] as? Date
            if let cached = cache[path],
               cached.fileSize == size,
               cached.modificationDate == modificationDate {
                if let record = cached.record { result[task.id] = record }
                continue
            }

            let record: CodexTaskRuntimeRecord?
            if let cached = cache[path], size > cached.fileSize {
                // Once a file has been classified, inspect only newly appended
                // bytes. Output-only changes preserve the prior lifecycle state.
                record = latestRecord(
                    in: url,
                    threadID: task.id,
                    startOffset: cached.fileSize > 1_024 ? cached.fileSize - 1_024 : 0,
                    fileSize: size
                ) ?? cached.record
            } else {
                record = latestRecordFromTail(in: url, threadID: task.id, fileSize: size)
            }
            cache[path] = CacheEntry(
                fileSize: size,
                modificationDate: modificationDate,
                record: record
            )
            if let record { result[task.id] = record }
        }
        return result
    }

    private func latestRecordFromTail(
        in url: URL,
        threadID: String,
        fileSize: UInt64
    ) -> CodexTaskRuntimeRecord? {
        // Most completed turns resolve from the first 256 KB. A legacy active
        // turn may have emitted large tool results since task_started, so widen
        // the first read progressively without ever scanning the entire history.
        for maximumTailBytes: UInt64 in [256 * 1_024, 1_024 * 1_024, 4 * 1_024 * 1_024,
                                         16 * 1_024 * 1_024, 64 * 1_024 * 1_024] {
            let startOffset = fileSize > maximumTailBytes ? fileSize - maximumTailBytes : 0
            if let record = latestRecord(
                in: url,
                threadID: threadID,
                startOffset: startOffset,
                fileSize: fileSize
            ) {
                return record
            }
            if startOffset == 0 { break }
        }
        return nil
    }

    private func latestRecord(
        in url: URL,
        threadID: String,
        startOffset: UInt64,
        fileSize: UInt64
    ) -> CodexTaskRuntimeRecord? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: startOffset)
            guard let data = try handle.read(upToCount: Int(fileSize - startOffset)) else { return nil }
            let text = String(decoding: data, as: UTF8.self)
            for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
                guard LifecycleMarker.allCases.contains(where: { line.contains($0.rawValue) }),
                      let metadata = lifecycleMetadata(from: line) else {
                    continue
                }

                let state: CodexTurnRuntimeState
                switch metadata.marker {
                case .started: state = .inProgress
                case .completed: state = .completed
                case .aborted: state = .interrupted
                }
                return CodexTaskRuntimeRecord(
                    threadID: threadID,
                    turnID: metadata.turnID,
                    state: state,
                    startedAt: metadata.marker == .started ? metadata.timestamp : nil,
                    completedAt: metadata.marker == .started ? nil : metadata.timestamp
                )
            }
            return nil
        } catch {
            return nil
        }
    }

    private func lifecycleMetadata(
        from line: Substring
    ) -> (marker: LifecycleMarker, turnID: String, timestamp: Date?)? {
        guard let data = String(line).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "event_msg",
              let payload = object["payload"] as? [String: Any] else {
            return nil
        }
        let marker: LifecycleMarker
        switch payload["type"] as? String {
        case "task_started": marker = .started
        case "task_complete": marker = .completed
        case "turn_aborted": marker = .aborted
        default: return nil
        }
        let turnID = (payload["turn_id"] as? String) ?? (payload["id"] as? String) ?? ""
        guard !turnID.isEmpty else { return nil }
        let epochKey = marker == .started ? "started_at" : "completed_at"
        let timestamp = (payload[epochKey] as? NSNumber)
            .map { Date(timeIntervalSince1970: $0.doubleValue) }
            ?? parseTimestamp(object["timestamp"] as? String)
        return (marker, turnID, timestamp)
    }

    private func parseTimestamp(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}
