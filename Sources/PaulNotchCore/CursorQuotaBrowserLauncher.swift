import AppKit
import Combine

/// Opens only a fresh, owned PKCE login link. Opening the browser is not authentication.
@MainActor final class CursorQuotaBrowserLauncher: ObservableObject {
    enum Phase: Equatable { case idle, opening, opened, failed(String) }
    @Published private(set) var phase: Phase = .idle
    private let allowsOpening: Bool
    private let opener: @MainActor (URL) async throws -> Void
    private var task: Task<Void, Never>?
    private var generation = 0

    init(allowsOpening: Bool = AppEnvironment.ownedQuotaConnectionsEnabled,
         opener: @escaping @MainActor (URL) async throws -> Void = CursorQuotaBrowserLauncher.launchInChrome) {
        self.allowsOpening = allowsOpening; self.opener = opener
    }

    func open(_ url: URL) {
        guard task == nil else { return }
        guard allowsOpening else { phase = .failed("隔离预览不会打开真实登录。请在正式版连接。"); return }
        guard Self.permits(url) else { phase = .failed("登录链接无效，请取消后重新连接。"); return }
        generation += 1
        let revision = generation
        phase = .opening
        task = Task { @MainActor [weak self, opener] in
            do {
                try await opener(url)
                guard let self, generation == revision, !Task.isCancelled else { return }
                phase = .opened; task = nil
            } catch {
                guard let self, generation == revision, !Task.isCancelled else { return }
                phase = .failed(error is ChromeMissing
                    ? "未找到 Google Chrome，请安装后重试；也可复制登录链接到浏览器。"
                    : "Chrome 没有成功打开。请重试，或复制登录链接到浏览器地址栏。"); task = nil
            }
        }
    }

    func cancel() {
        generation += 1; task?.cancel(); task = nil; phase = .idle
    }

    @discardableResult func copyLink(_ url: URL, to board: NSPasteboard = .general) -> Bool {
        guard allowsOpening, Self.permits(url) else { return false }
        board.clearContents()
        return board.setString(url.absoluteString, forType: .string)
    }

    static func permits(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host?.lowercased() == "cursor.com",
              parts.percentEncodedPath == "/loginDeepControl", parts.port == nil,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              let items = parts.queryItems, items.count == 4,
              Set(items.map(\.name)) == ["challenge", "uuid", "mode", "redirectTarget"],
              items.allSatisfy({ $0.value != nil }) else { return false }
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value!) })
        guard let challenge = values["challenge"], challenge.utf8.count == 43,
              challenge.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                  || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              values["uuid"].flatMap(UUID.init(uuidString:)) != nil else { return false }
        return values["mode"] == "login" && values["redirectTarget"] == "cli"
    }

    private struct ChromeMissing: Error {}
    private struct ChromeOpenFailed: Error {}
    private static func launchInChrome(_ url: URL) async throws {
        guard let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else {
            throw ChromeMissing()
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.promptsUserIfNeeded = false
        configuration.addsToRecentItems = false
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open([url], withApplicationAt: chrome, configuration: configuration) { application, error in
                if application != nil && error == nil { continuation.resume() }
                else { continuation.resume(throwing: ChromeOpenFailed()) }
            }
        }
    }
}
