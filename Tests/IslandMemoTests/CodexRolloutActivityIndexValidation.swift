import Foundation

@main
struct CodexRolloutActivityIndexValidation {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            FileHandle.standardError.write(Data("验证失败：\(message)\n".utf8))
            Foundation.exit(1)
        }
    }

    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("paul-notch-rollout-validation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let rollout = directory.appendingPathComponent("rollout.jsonl")
        FileManager.default.createFile(atPath: rollout.path, contents: nil)
        let index = IslandCodexRolloutActivityIndex()
        let task = CodexTaskSummary(
            id: "thread-1",
            title: "Validation",
            state: .idle,
            updatedAt: .now,
            source: "vscode",
            rolloutPath: rollout.path
        )

        try append(event: "task_started", turnID: "turn-1", to: rollout)
        var states = await index.latestStates(for: [task])
        require(states[task.id]?.state == .inProgress, "未识别 task_started")
        require(states[task.id]?.taskState() == .working, "task_started 时间未被识别为当前运行态")

        // Tool output may itself contain serialized lifecycle-looking JSON. It
        // must not override the outer rollout event type.
        try append(object: [
            "timestamp": ISO8601DateFormatter().string(from: .now),
            "type": "response_item",
            "payload": [
                "type": "custom_tool_call_output",
                "output": "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\"}}",
            ],
        ], to: rollout)
        states = await index.latestStates(for: [task])
        require(states[task.id]?.state == .inProgress, "误把工具输出当成任务完成事件")

        try append(event: "task_complete", turnID: "turn-1", to: rollout)
        states = await index.latestStates(for: [task])
        require(states[task.id]?.state == .completed, "未识别 task_complete")

        print("Codex rollout activity validation passed")
    }

    private static func append(event: String, turnID: String, to url: URL) throws {
        let now = Date()
        try append(object: [
            "timestamp": ISO8601DateFormatter().string(from: now),
            "type": "event_msg",
            "payload": [
                "type": event,
                "turn_id": turnID,
                event == "task_started" ? "started_at" : "completed_at": now.timeIntervalSince1970,
            ],
        ], to: url)
    }

    private static func append(object: [String: Any], to url: URL) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
