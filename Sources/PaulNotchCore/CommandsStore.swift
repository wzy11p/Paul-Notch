import AppKit
import Foundation

struct QuickCommand: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var text: String
    var createdAt: Date

    init(id: UUID = UUID(), text: String, createdAt: Date = .now) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}

/// 常用指令：保存高频 prompt / 命令片段，点击复制到剪贴板。
/// Ported from TO-DO-Panel workspace.js 常用指令模块。
@MainActor
final class CommandsStore: ObservableObject {
    @Published private(set) var commands: [QuickCommand] = []
    @Published private(set) var errorMessage: String?
    private var loadFailure: String?

    private let fileURL: URL

    init() {
        let base = AppEnvironment.dataDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("commands.json")
        load()
    }

    @discardableResult
    func add(text: String) -> Bool {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }
        if commands.contains(where: { $0.text == cleaned }) { return true }
        return commit([QuickCommand(text: cleaned)] + commands)
    }

    func delete(_ command: QuickCommand) {
        _ = commit(commands.filter { $0.id != command.id })
    }

    func copy(_ command: QuickCommand) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(command.text, forType: .string)
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            commands = try decoder.decode([QuickCommand].self, from: Data(contentsOf: fileURL))
        } catch CocoaError.fileReadNoSuchFile {
            return
        } catch {
            loadFailure = "常用指令读取失败，原文件已保留；请恢复文件后重新打开应用。"
            errorMessage = loadFailure
        }
    }

    private func commit(_ candidate: [QuickCommand]) -> Bool {
        guard loadFailure == nil else { errorMessage = loadFailure; return false }
        // Small explicit edits commit in order before becoming visible. Independent
        // detached writes could finish out of order or be lost on immediate quit.
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(candidate).write(to: fileURL, options: .atomic)
            commands = candidate
            errorMessage = nil
            return true
        } catch {
            errorMessage = "常用指令未能保存，请检查磁盘空间和访问权限；输入内容已保留，可重试。"
            return false
        }
    }
}
