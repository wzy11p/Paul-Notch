import AppKit
import ApplicationServices
import Foundation

/// 统一管理各音乐播放器。Apple Music 与 Spotify 使用应用自身的脚本命令，
/// QQ 音乐菜单控制和汽水音乐快捷键需要辅助功能；打开播放器本身不需要。
@MainActor
final class MusicService: ObservableObject {
    enum Action: String, Sendable {
        case play
        case pause
        case next
        case previous
    }

    enum Provider: String, CaseIterable, Identifiable, Codable, Sendable {
        case soda
        case appleMusic
        case spotify
        case qqMusic

        var id: String { rawValue }

        var name: String {
            switch self {
            case .soda: return "汽水音乐"
            case .appleMusic: return "Apple Music"
            case .spotify: return "Spotify"
            case .qqMusic: return "QQ 音乐"
            }
        }

        var bundleID: String {
            switch self {
            case .soda: return "com.soda.music"
            case .appleMusic: return "com.apple.Music"
            case .spotify: return "com.spotify.client"
            case .qqMusic: return "com.tencent.QQMusicMac"
            }
        }

        var fallbackPath: String? {
            switch self {
            case .soda: return "/Applications/汽水音乐.app"
            case .appleMusic: return "/System/Applications/Music.app"
            case .spotify: return "/Applications/Spotify.app"
            case .qqMusic: return "/Applications/QQMusic.app"
            }
        }

        var controlDescription: String {
            switch self {
            case .soda: return "桌面快捷键 · 需要辅助功能权限"
            case .appleMusic, .spotify: return "播放器原生控制"
            case .qqMusic: return "原生播放菜单 · 读取当前歌名与播放状态 · 需要辅助功能权限"
            }
        }
    }

    private enum PreferenceKey {
        static let enabledProviders = "music.enabledProviders.v1"
        static let defaultProvider = "music.defaultProvider.v1"
    }

    @Published private(set) var installedProviders: Set<Provider> = []
    @Published private(set) var runningProviders: Set<Provider> = []
    @Published private(set) var playingProviders: Set<Provider> = []
    @Published private(set) var enabledProviders: Set<Provider>
    @Published private(set) var defaultProvider: Provider
    @Published var errorMessage: String?
    @Published private(set) var isOpening = false
    @Published private(set) var openError: String?
    @Published private(set) var permissionSnapshot: MusicPermissionSnapshot?
    @Published private(set) var isCheckingConnection = false
    @Published private(set) var lastQQMusicError: String?
    @Published private(set) var qqNowPlaying: QQNowPlaying?
    @Published private(set) var nowPlayingIssue: String?
    private var readingQQ = false
    private var providerGeneration = 0

    var connectionIssue: String? {
        openError ?? errorMessage ?? (activeProvider == .qqMusic ? nowPlayingIssue : nil)
    }
    var playbackActionLabel: String {
        if activeProvider == .qqMusic { return qqNowPlaying?.actionLabel ?? "播放/暂停" }
        return isPlaying ? "暂停" : "播放"
    }
    var playbackActionSymbol: String {
        if activeProvider == .qqMusic { return qqNowPlaying?.actionSymbol ?? "playpause.fill" }
        return isPlaying ? "pause.fill" : "play.fill"
    }

    /// SwiftUI cancels this task when the music surface leaves. Hidden panels never read the player.
    func workspaceDidOpen() {
        // NSPanel orderOut/orderFront does not remount SwiftUI's .task.
        // Refresh immediately on reveal instead of waiting for the next poll.
        Task { await refreshQQNowPlaying() }
    }

    func observeVisiblePlayback() async {
        while !Task.isCancelled {
            if NSApp.windows.contains(where: { $0 is IslandPanel && $0.isVisible }) {
                await refreshQQNowPlaying()
            }
            do { try await Task.sleep(for: .milliseconds(1500)) } catch { return }
        }
    }

    private func refreshQQNowPlaying() async {
        guard activeProvider == .qqMusic, !readingQQ else { return }
        readingQQ = true
        defer { readingQQ = false }
        let generation = providerGeneration
        let result = await Task.detached(priority: .utility) { QQNowPlayingReader.read() }.value
        guard !Task.isCancelled, generation == providerGeneration, activeProvider == .qqMusic else { return }
        switch result {
        case .available(let snapshot):
            if qqNowPlaying != snapshot { qqNowPlaying = snapshot }
            if nowPlayingIssue != nil { nowPlayingIssue = nil }
            if !runningProviders.contains(.qqMusic) { runningProviders.insert(.qqMusic) }
            if snapshot.isPlaying == true, !playingProviders.contains(.qqMusic) { playingProviders.insert(.qqMusic) }
            if snapshot.isPlaying != true, playingProviders.contains(.qqMusic) { playingProviders.remove(.qqMusic) }
        case .notRunning:
            if qqNowPlaying != nil { qqNowPlaying = nil }
            if nowPlayingIssue != nil { nowPlayingIssue = nil }
            if runningProviders.contains(.qqMusic) { runningProviders.remove(.qqMusic) }
            if playingProviders.contains(.qqMusic) { playingProviders.remove(.qqMusic) }
        case .unavailable(let issue):
            if qqNowPlaying != nil { qqNowPlaying = nil }
            if playingProviders.contains(.qqMusic) { playingProviders.remove(.qqMusic) }
            if nowPlayingIssue != issue { nowPlayingIssue = issue }
        }
    }

    func checkQQMusicConnection() {
        guard !isCheckingConnection else { return }
        isCheckingConnection = true
        Task { @MainActor in
            permissionSnapshot = await Task.detached(priority: .userInitiated) {
                MusicPermissionSnapshot.read()
            }.value
            isCheckingConnection = false
        }
    }

    /// Reopen the player without playback automation or control permission requests.
    func openPlayer() {
        guard !isOpening else { return }
        refreshStatus()
        guard let provider = activeProvider, let url = applicationURL(for: provider) else {
            openError = "找不到播放器，请先安装并在音乐设置中启用。"
            return
        }
        openError = nil
        isOpening = true
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, error in
            let failure = error?.localizedDescription
            Task { @MainActor in
                guard let self else { return }
                self.isOpening = false
                self.refreshStatus()
                if let failure { self.openError = "无法打开\(provider.name)：\(failure)" }
            }
        }
    }

    init(defaults: UserDefaults = AppEnvironment.defaults) {
        if let stored = defaults.array(forKey: PreferenceKey.enabledProviders) as? [String] {
            enabledProviders = Set(stored.compactMap(Provider.init(rawValue:)))
        } else {
            enabledProviders = Set(Provider.allCases)
        }

        if let rawValue = defaults.string(forKey: PreferenceKey.defaultProvider),
           let provider = Provider(rawValue: rawValue) {
            defaultProvider = provider
        } else if FileManager.default.fileExists(atPath: Provider.soda.fallbackPath ?? "") {
            // 延续旧版本：已经使用汽水音乐的用户升级后仍默认控制汽水。
            defaultProvider = .soda
        } else {
            defaultProvider = .appleMusic
        }
        refreshStatus()
    }

    var activeProvider: Provider? {
        if enabledProviders.contains(defaultProvider), isInstalled(defaultProvider) {
            return defaultProvider
        }
        return Provider.allCases.first { enabledProviders.contains($0) && isInstalled($0) }
    }

    var displayName: String { activeProvider?.name ?? "音乐" }
    var isInstalled: Bool { activeProvider != nil }
    var isRunning: Bool { activeProvider.map(runningProviders.contains) ?? false }
    var isPlaying: Bool {
        if activeProvider == .qqMusic { return qqNowPlaying?.isPlaying == true }
        return activeProvider.map(playingProviders.contains) ?? false
    }
    var usesToggleControl: Bool { activeProvider == .qqMusic }

    var icon: NSImage? {
        guard let provider = activeProvider, let url = applicationURL(for: provider) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 20, height: 20)
        return icon
    }

    func isInstalled(_ provider: Provider) -> Bool { installedProviders.contains(provider) }
    func isRunning(_ provider: Provider) -> Bool { runningProviders.contains(provider) }
    func isPlaying(_ provider: Provider) -> Bool { playingProviders.contains(provider) }
    func isEnabled(_ provider: Provider) -> Bool { enabledProviders.contains(provider) }

    func icon(for provider: Provider) -> NSImage? {
        guard let url = applicationURL(for: provider) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 24, height: 24)
        return icon
    }

    func setEnabled(_ provider: Provider, enabled: Bool) {
        providerGeneration += 1
        if enabled { enabledProviders.insert(provider) } else { enabledProviders.remove(provider) }
        AppEnvironment.defaults.set(enabledProviders.map(\.rawValue).sorted(), forKey: PreferenceKey.enabledProviders)

        if !enabledProviders.contains(defaultProvider),
           let replacement = Provider.allCases.first(where: { enabledProviders.contains($0) && isInstalled($0) }) {
            setDefault(replacement)
        }
    }

    func setDefault(_ provider: Provider) {
        guard enabledProviders.contains(provider), isInstalled(provider) else { return }
        defaultProvider = provider
        providerGeneration += 1
        qqNowPlaying = nil
        nowPlayingIssue = nil
        openError = nil
        AppEnvironment.defaults.set(provider.rawValue, forKey: PreferenceKey.defaultProvider)
        errorMessage = nil
        refreshPlaybackState(for: provider)
    }

    func refreshStatus() {
        installedProviders = Set(Provider.allCases.filter { applicationURL(for: $0) != nil })
        runningProviders = Set(Provider.allCases.filter {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleID).isEmpty
        })
        playingProviders.formIntersection(runningProviders)
    }

    func control(_ action: Action) {
        refreshStatus()
        guard let provider = activeProvider else {
            errorMessage = "没有可用的音乐服务，请在设置 → 音乐服务中启用已安装的播放器"
            return
        }
        guard isInstalled(provider) else {
            errorMessage = "未安装\(provider.name)"
            return
        }

        if !isRunning(provider) {
            guard action == .play else {
                errorMessage = "\(provider.name)未在运行"
                return
            }
            launch(provider) { [weak self] launched in
                guard launched else {
                    Task { @MainActor in self?.errorMessage = "\(provider.name)启动失败" }
                    return
                }
                let delay = provider == .soda ? 3.0 : 1.0
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.send(action, to: provider)
                }
            }
            return
        }
        send(action, to: provider)
    }

    private func applicationURL(for provider: Provider) -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: provider.bundleID) { return url }
        guard let path = provider.fallbackPath, FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func launch(_ provider: Provider, completion: @escaping @Sendable (Bool) -> Void) {
        guard let url = applicationURL(for: provider) else {
            completion(false)
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            completion(error == nil)
        }
    }

    private func send(_ action: Action, to provider: Provider) {
        errorMessage = nil
        switch provider {
        case .soda: sendSodaShortcut(action)
        case .appleMusic, .spotify: sendScriptableAction(action, to: provider)
        case .qqMusic: sendQQMusicAction(action)
        }
    }

    private func sendScriptableAction(_ action: Action, to provider: Provider) {
        let command: String
        switch action {
        case .play, .pause: command = "playpause"
        case .next: command = "next track"
        case .previous: command = "previous track"
        }
        let script = "tell application id \"\(provider.bundleID)\" to \(command)"
        runOSA(language: nil, script: script) { [weak self] succeeded, _ in
            guard let self else { return }
            if succeeded {
                self.runningProviders.insert(provider)
                if action == .play { self.playingProviders.insert(provider) }
                if action == .pause { self.playingProviders.remove(provider) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    self?.refreshPlaybackState(for: provider)
                }
            } else {
                self.errorMessage = "无法控制\(provider.name)，请在系统设置 → 隐私与安全性 → 自动化中允许Paul Notch控制该播放器"
            }
        }
    }

    private func refreshPlaybackState(for provider: Provider) {
        guard provider != .soda, provider != .qqMusic, isRunning(provider) else { return }
        let script = "tell application id \"\(provider.bundleID)\" to return (player state as text)"
        runOSA(language: nil, script: script) { [weak self] succeeded, output in
            guard let self, succeeded else { return }
            if output.lowercased().contains("playing") { self.playingProviders.insert(provider) }
            else { self.playingProviders.remove(provider) }
        }
    }

    private func sendQQMusicAction(_ action: Action) {
        // QQMusic 11.8.1 exposes these commands in its Chinese native menu,
        // not a scripting dictionary. No key injection or track-state guessing.
        let target: String
        switch action {
        case .play, .pause: target = "menu item 1"
        case .next: target = "menu item \"下一首\""
        case .previous: target = "menu item \"上一首\""
        }
        let script = """
        with timeout of 5 seconds
            tell application "System Events"
                set player to first application process whose bundle identifier is "com.tencent.QQMusicMac"
                tell player
                    tell menu "播放控制" of menu bar item "播放控制" of menu bar 1
                        click \(target)
                    end tell
                end tell
            end tell
        end timeout
        """
        runOSA(language: nil, script: script) { [weak self] succeeded, diagnostic in
            guard let self else { return }
            if succeeded {
                self.runningProviders.insert(.qqMusic)
                self.lastQQMusicError = nil
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(250))
                    await self?.refreshQQNowPlaying()
                }
            } else {
                self.lastQQMusicError = diagnostic.isEmpty ? "脚本未提供错误详情" : String(diagnostic.prefix(4096))
                self.errorMessage = MusicPermissionSnapshot.failureMessage(raw: diagnostic, trusted: AXIsProcessTrusted())
                self.checkQQMusicConnection()
            }
        }
    }

    private func sendSodaShortcut(_ action: Action) {
        let keyCode: Int
        let usesCommand: Bool
        switch action {
        case .play, .pause: keyCode = 49; usesCommand = false
        case .next: keyCode = 124; usesCommand = true
        case .previous: keyCode = 123; usesCommand = true
        }
        let script = """
        function run(argv) {
          const keyCode = Number(argv[0]);
          const usesCommand = String(argv[1] || '') === '1';
          const processes = Application('System Events').applicationProcesses.whose({ bundleIdentifier: '\(Provider.soda.bundleID)' })();
          if (!processes.length) return 'missing';
          processes[0].frontmost = true;
          delay(0.35);
          const systemEvents = Application('System Events');
          systemEvents.keyCode(53);
          delay(0.15);
          if (usesCommand) systemEvents.keyCode(keyCode, { using: 'command down' });
          else systemEvents.keyCode(keyCode);
          return 'ok';
        }
        """
        runOSA(language: "JavaScript", script: script, arguments: [String(keyCode), usesCommand ? "1" : "0"]) { [weak self] succeeded, output in
            guard let self else { return }
            if succeeded, output == "ok" {
                self.runningProviders.insert(.soda)
                if action == .play { self.playingProviders.insert(.soda) }
                if action == .pause { self.playingProviders.remove(.soda) }
            } else if output == "missing" {
                self.runningProviders.remove(.soda)
                self.playingProviders.remove(.soda)
            } else {
                self.errorMessage = "控制失败：需要在系统设置 → 隐私与安全性 → 辅助功能中允许Paul Notch"
            }
        }
    }

    private func runOSA(
        language: String?,
        script: String,
        arguments: [String] = [],
        completion: @escaping @MainActor (Bool, String) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            var processArguments: [String] = []
            if let language { processArguments += ["-l", language] }
            processArguments += ["-e", script]
            if !arguments.isEmpty { processArguments += ["--"] + arguments }
            process.arguments = processArguments
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            do {
                try process.run()
                process.waitUntilExit()
                let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let diagnostic = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                Task { @MainActor in completion(process.terminationStatus == 0,
                    process.terminationStatus == 0 ? output : diagnostic) }
            } catch {
                Task { @MainActor in completion(false, error.localizedDescription) }
            }
        }
    }
}
