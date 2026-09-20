import Foundation
import Network
import UserNotifications

struct TaskCompletion: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let source: String
    let title: String
    let project: String
    let receivedAt: Date

    init(id: UUID = UUID(), source: String, title: String, project: String, receivedAt: Date = .now) {
        self.id = id
        self.source = source
        self.title = title
        self.project = project
        self.receivedAt = receivedAt
    }
}

/// 本机 AI 完成提醒：只监听 127.0.0.1:43821 的 /notify/<source>，
/// 来源白名单 codex / claude / gpt / windsurf / cursor，其余一律 404。
/// 移植自 TO-DO-Panel main.js startTaskNotificationServer + taskNotificationIdentity。
@MainActor
final class AgentNotifyServer: ObservableObject {
    @Published private(set) var recentCompletions: [TaskCompletion] = []
    @Published private(set) var isRunning = false

    private static let allowedSources: Set<String> = ["codex", "claude", "gpt", "windsurf", "cursor"]
    private static let fallbackTitles: [String: String] = [
        "codex": "Codex 已完成任务",
        "claude": "Claude 已完成任务",
        "gpt": "GPT 已完成任务",
        "windsurf": "Windsurf 已完成任务",
        "cursor": "Cursor 已完成任务",
    ]

    private var listener: NWListener?
    private static let historyKey = "agent-completion-history-v1"

    init() {
        if let data = AppEnvironment.defaults.data(forKey: Self.historyKey),
           let saved = try? JSONDecoder().decode([TaskCompletion].self, from: data) {
            recentCompletions = Array(saved.prefix(20))
        }
    }

    func start() {
        guard listener == nil else { return }
        guard !AppEnvironment.usesIsolatedWorkspace, let port = NWEndpoint.Port(rawValue: 43821) else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        guard let listener = try? NWListener(using: parameters) else { return }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                // Defense in depth in addition to the explicit loopback bind.
                guard Self.isLoopback(connection.endpoint) else {
                    connection.cancel()
                    return
                }
                self?.handle(connection)
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.isRunning = state == .ready
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - Minimal HTTP/1.1 handling

    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            return String(describing: address).hasPrefix("127.")
        case .ipv6(let address):
            let text = String(describing: address)
            return text == "::1" || text.hasPrefix("::ffff:127.")
        case .name(let name, _):
            return name == "localhost"
        @unknown default:
            return false
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, _ in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                var buffer = buffer
                if let content { buffer.append(content) }
                guard buffer.count <= NotificationHTTPPolicy.maximumBodyBytes + NotificationHTTPPolicy.maximumHeaderBytes else {
                    connection.cancel(); return
                }
                if let headerEnd = buffer.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) {
                    let headerData = buffer[buffer.startIndex..<headerEnd.lowerBound]
                    let header = String(data: headerData, encoding: .utf8) ?? ""
                    guard headerData.count <= NotificationHTTPPolicy.maximumHeaderBytes,
                          let contentLength = NotificationHTTPPolicy.contentLength(of: header) else {
                        Self.write(connection: connection, status: 400, body: "Invalid request length")
                        return
                    }
                    let bodyStart = headerEnd.upperBound
                    let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
                    if available >= contentLength {
                        let body = buffer[bodyStart..<buffer.index(bodyStart, offsetBy: min(contentLength, available))]
                        self.respond(on: connection, header: header, body: Data(body))
                        return
                    }
                    if isComplete { connection.cancel(); return }
                }
                if isComplete || (buffer.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) == nil
                                  && buffer.count > NotificationHTTPPolicy.maximumHeaderBytes) {
                    Self.write(connection: connection, status: 400, body: #"{"error":"bad_request"}"#)
                    return
                }
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(on connection: NWConnection, header: String, body: Data) {
        let lines = header.components(separatedBy: "\r\n")
        let requestLine = lines.first ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0].uppercased() == "POST" else {
            Self.write(connection: connection, status: 404, body: #"{"error":"not_found"}"#)
            return
        }
        let path = String(parts[1])
        guard path.hasPrefix("/notify/") else {
            Self.write(connection: connection, status: 404, body: #"{"error":"not_found"}"#)
            return
        }
        let source = String(path.dropFirst("/notify/".count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        guard Self.allowedSources.contains(source) else {
            Self.write(connection: connection, status: 404, body: #"{"error":"not_found"}"#)
            return
        }
        guard let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            Self.write(connection: connection, status: 400, body: #"{"error":"invalid_json"}"#)
            return
        }
        // 子代理结束不弹提醒（agent_id 存在即视为子代理，与参考项目一致）。
        if payload["agent_id"] != nil || payload["agentId"] != nil {
            Self.write(connection: connection, status: 200, body: #"{"ok":true,"ignored":"subagent"}"#)
            return
        }

        let identity = Self.identity(from: payload, source: source)
        let completion = TaskCompletion(source: source, title: identity.title, project: identity.project)
        record(completion, sendsNotification: true)
        Self.write(connection: connection, status: 200, body: #"{"ok":true}"#)
    }

    func sendTestCompletion() {
        record(TaskCompletion(
            source: "codex",
            title: "Paul Notch已成功接收 AI 任务",
            project: "连接测试"
        ), sendsNotification: false)
    }

    func clearHistory() {
        recentCompletions.removeAll()
        persistHistory()
    }

    private func record(_ completion: TaskCompletion, sendsNotification: Bool) {
        recentCompletions.insert(completion, at: 0)
        if recentCompletions.count > 20 { recentCompletions.removeLast() }
        persistHistory()
        if sendsNotification { sendSystemNotification(completion) }
    }

    private func persistHistory() {
        if let data = try? JSONEncoder().encode(recentCompletions) {
            AppEnvironment.defaults.set(data, forKey: Self.historyKey)
        }
    }

    private func sendSystemNotification(_ completion: TaskCompletion) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = "Paul Notch"
        content.subtitle = completion.project.isEmpty
            ? completion.title
            : "\(completion.project) · \(completion.title)"
        content.body = "AI 任务已完成"
        content.sound = .default
        center.add(UNNotificationRequest(
            identifier: "agent-\(completion.id.uuidString)",
            content: content,
            trigger: nil
        ))
    }

    private static func write(connection: NWConnection, status: Int, body: String) {
        let reason = status == 200 ? "OK" : status == 400 ? "Bad Request" : "Not Found"
        let bodyData = Data(body.utf8)
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(bodyData)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Payload normalization (ported from main-services.js taskNotificationIdentity)

    static func identity(from payload: [String: Any], source: String) -> (title: String, project: String) {
        func firstText(_ keys: [String]) -> String {
            for key in keys {
                if let value = payload[key] as? String, !value.trimmingCharacters(in: .whitespaces).isEmpty {
                    return value
                }
                if let value = payload[key] as? NSNumber {
                    return value.stringValue
                }
            }
            return ""
        }

        let cwd = firstText(["cwd", "working_directory", "working-directory"])
        var project = firstText(["project", "project_name", "project-name", "projectName"])
        if project.isEmpty, !cwd.isEmpty, cwd.hasPrefix("/") {
            project = URL(fileURLWithPath: cwd).lastPathComponent
        }
        project = cleanLine(project, maxLength: 48)

        let concrete = firstText([
            "last_assistant_message", "last-assistant-message", "lastAssistantMessage",
            "task_title", "task-title", "taskTitle",
            "task_name", "task-name", "taskName",
            "last_user_message", "last-user-message", "lastUserMessage",
            "prompt", "user_prompt", "user-prompt", "userPrompt",
            "message", "title",
        ])
        let title = cleanLine(concrete, maxLength: 120)
        let fallback = fallbackTitles[source] ?? "任务已完成"
        return (title.isEmpty ? fallback : title, project)
    }

    private static func cleanLine(_ value: String, maxLength: Int) -> String {
        let line = value.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        var cleaned = line.replacingOccurrences(of: #"^[#>*`_~\-\s]+"#, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"[`*_~]"#, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return String(cleaned.prefix(maxLength))
    }
}
