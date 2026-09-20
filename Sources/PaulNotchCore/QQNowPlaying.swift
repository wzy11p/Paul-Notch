import AppKit
import ApplicationServices

struct QQNowPlaying: Equatable, Sendable {
    let title: String?
    let artist: String?
    let isPlaying: Bool?

    var actionSymbol: String {
        switch isPlaying {
        case .some(true): return "pause.fill"
        case .some(false): return "play.fill"
        case .none: return "playpause.fill"
        }
    }

    var actionLabel: String {
        switch isPlaying {
        case .some(true): return "暂停"
        case .some(false): return "播放"
        case .none: return "播放/暂停"
        }
    }

    static func parse(trackLabel: String?, buttonLabels: [String]) -> Self {
        let labels = Set(buttonLabels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        let pause = !labels.isDisjoint(with: ["暂停播放", "暂停", "Pause"])
        let play = !labels.isDisjoint(with: ["播放", "继续播放", "Play"])
        // Conflicting or unfamiliar controls are unknown, not a guessed pause state.
        let playing: Bool? = pause == play ? nil : pause
        var title: String?
        var artist: String?
        if let raw = trackLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
           let prefix = ["歌曲名：", "歌曲名:"].first(where: { raw.hasPrefix($0) }) {
            let body = String(raw.dropFirst(prefix.count))
            let separator = [" - 歌手名：", " - 歌手名:"].compactMap { body.range(of: $0) }.first
            let song = separator.map { String(body[..<$0.lowerBound]) } ?? body
            title = song.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            if let separator {
                artist = String(body[separator.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            }
        }
        return Self(title: title, artist: artist, isPlaying: playing)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

enum QQNowPlayingRead: Sendable {
    case available(QQNowPlaying)
    case notRunning
    case unavailable(String)
}

/// Only the known main window's playback group is read. Never traverses playlists, account areas, files or web content.
enum QQNowPlayingReader {
    // Retain the AX handle, not a song/state snapshot: QQ can omit background
    // windows from the application list while its transport remains readable.
    private final class WindowCache: @unchecked Sendable {
        let lock = NSLock()
        var pid: pid_t?
        var window: AXUIElement?
    }
    private static let cache = WindowCache()

    static func read() -> QQNowPlayingRead {
        cache.lock.lock()
        defer { cache.lock.unlock() }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.tencent.QQMusicMac").first else {
            cache.pid = nil
            cache.window = nil
            return .notRunning
        }
        guard AXIsProcessTrusted() else { return .unavailable("当前版本的辅助功能授权未生效，无法读取歌名和播放状态。") }
        let reader = BoundedReader()
        let previousWindow = cache.pid == app.processIdentifier ? cache.window : nil
        cache.pid = app.processIdentifier
        cache.window = nil
        reader.lastError = nil
        let application = AXUIElementCreateApplication(app.processIdentifier)
        var windows = reader.elements(application, kAXWindowsAttribute)
        // A window identifier is optional in AX. Do not confuse a missing identifier
        // or an unsupported array-count operation with the player having no window.
        if windows.isEmpty {
            windows = [reader.element(application, kAXMainWindowAttribute),
                       reader.element(application, kAXFocusedWindowAttribute)].compactMap { $0 }
        }
        if windows.isEmpty {
            // Some player accessibility bridges expose windows only as application children.
            // Inspect roles at this single level; never walk application menus or content.
            windows = reader.elements(application, kAXChildrenAttribute).filter {
                let role = reader.string($0, kAXRoleAttribute)
                return role != kAXMenuBarRole && role != kAXMenuRole
            }
        }
        if windows.isEmpty, let previousWindow { windows = [previousWindow] }
        guard !windows.isEmpty else {
            return .unavailable(reader.lastError == nil
                ? "QQ 音乐未提供播放器窗口。点歌名区域打开播放器后会自动重试。" + reader.windowDiagnostic
                : "QQ 音乐窗口读取未完成。" + reader.errorSuffix)
        }
        var playbackGroup: AXUIElement?
        var playbackWindow: AXUIElement?
        for window in windows.prefix(8) {
            playbackGroup = reader.elements(window, kAXChildrenAttribute).first(where: { child in
                // QQ exposes this as a pane in some versions, not AXGroup.
                // The exact label and direct-window-child boundary identify the transport.
                return reader.labels(child).contains("播放控制栏")
            })
            if playbackGroup != nil { playbackWindow = window; break }
        }
        guard let controls = playbackGroup else {
            return .unavailable("QQ 音乐窗口已找到，但播放控制栏暂时无法读取。" + reader.errorSuffix)
        }
        let result = readControls(controls, reader: reader)
        if case .available = result { cache.window = playbackWindow }
        return result
    }

    private static func readControls(_ controls: AXUIElement, reader: BoundedReader) -> QQNowPlayingRead {
        // Selector failures in another window do not invalidate an identified control group.
        reader.lastError = nil
        var buttons: [String] = []
        var track: String?
        // Read direct children only: this group contains transport buttons and current-track text.
        for child in reader.elements(controls, kAXChildrenAttribute) {
            let strings = reader.strings(child)
            buttons += strings
            track = strings.first(where: { $0.hasPrefix("歌曲名：") || $0.hasPrefix("歌曲名:") }) ?? track
        }
        guard reader.lastError == nil else { return .unavailable("读取 QQ 音乐状态未完成。" + reader.errorSuffix) }
        let result = QQNowPlaying.parse(trackLabel: track, buttonLabels: buttons)
        guard result.isPlaying != nil else { return .unavailable("QQ 音乐的播放按钮状态暂时无法识别。") }
        return .available(result)
    }

    private final class BoundedReader {
        private let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        var lastError: AXError?
        private var windowReads: [String] = []
        var windowDiagnostic: String { "（" + windowReads.joined(separator: ", ") + "）" }
        var errorSuffix: String { lastError.map { "（AX \($0.rawValue)）" } ?? "" }

        private func ready(_ element: AXUIElement) -> Bool {
            guard ContinuousClock.now < deadline else { lastError = .cannotComplete; return false }
            AXUIElementSetMessagingTimeout(element, 0.35)
            return true
        }

        func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
            guard ready(element) else { return [] }
            // These arrays are only application windows or direct window/playback children,
            // never playlist/table rows. Some third-party bridges do not implement count/paging.
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            if attribute == kAXWindowsAttribute || attribute == kAXChildrenAttribute {
                if windowReads.count < 4 { windowReads.append("\(attribute):\(result.rawValue)/\((value as? [AXUIElement])?.count ?? -1)") }
            }
            if result == .attributeUnsupported || result == .noValue { return [] }
            guard result == .success else { lastError = result; return [] }
            guard let values = value as? [AXUIElement] else { lastError = .illegalArgument; return [] }
            guard values.count <= 64 else { lastError = .illegalArgument; return [] }
            return values
        }

        func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
            guard ready(element) else { return nil }
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            if result == .attributeUnsupported || result == .noValue { return nil }
            guard result == .success else { lastError = result; return nil }
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }

        func string(_ element: AXUIElement, _ attribute: String) -> String? {
            guard ready(element) else { return nil }
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            if result == .attributeUnsupported || result == .noValue { return nil }
            guard result == .success else { lastError = result; return nil }
            return (value as? String).map { String($0.prefix(1024)) }
        }

        func strings(_ element: AXUIElement) -> [String] {
            [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute].compactMap { string(element, $0) }
        }

        func labels(_ element: AXUIElement) -> [String] {
            [kAXTitleAttribute, kAXDescriptionAttribute].compactMap { string(element, $0) }
        }
    }
}
