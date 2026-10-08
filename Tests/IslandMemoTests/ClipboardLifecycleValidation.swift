import AppKit
import SwiftUI

@main
struct ClipboardLifecycleValidation {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let settings = AppSettingsStore()
        let store = ClipboardStore(base: root, defaults: AppEnvironment.defaults, pasteboard: board)
        defer { store.stopMonitoring() }
        settings.onClipboardConfigurationChanged = { [weak store] in store?.applyPreferences() }
        func copy(_ value: String) { board.clearContents(); board.setString(value, forType: .string) }
        func tick() { RunLoop.main.run(until: Date().addingTimeInterval(0.8)) }
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            precondition(condition(), name); print("PASS: \(name)")
        }
        if CommandLine.arguments[1] == "restart" {
            check(settings.clipboardCapturePaused && settings.clipboardCaptureText, "saved choices survive another process")
            store.startMonitoring()
            check(store.captureState == .paused, "restart stays paused")
            let previous = store.entries
            copy("restart ignored fixture"); tick()
            check(store.entries == previous, "restart does not collect while paused")
            settings.clipboardCapturePaused = false
            tick()
            check(store.entries == previous, "resume skips already copied value")
            copy("restart fresh fixture"); tick()
            check(store.entries.first?.text == "restart fresh fixture", "real timer resumes after restart")
            return
        }

        store.startMonitoring()
        check(store.captureState == .disabled, "new defaults remain disabled")
        copy("before consent fixture"); tick()
        check(store.entries.isEmpty, "no pre-consent capture")
        check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("clipboard-history.json").path), "disabled startup does not write history")
        try capture(store, settings, root, "disabled")
        settings.clipboardCaptureText = true
        tick()
        check(store.captureState == .recording && store.entries.isEmpty, "opt in starts without importing old value")
        try capture(store, settings, root, "recording-empty")
        copy("合成记录一 · 测试文字"); tick()
        check(store.entries.count == 1, "actual scheduled timer records text")
        try capture(store, settings, root, "recording-content")
        copy("合成记录一 · 测试文字"); tick()
        check(store.entries.count == 1, "deduplicates repeated content")
        settings.clipboardCapturePaused = true
        let prior = store.entries
        copy("paused fixture"); tick()
        check(store.captureState == .paused && store.entries == prior, "pause stops capture and retains history")
        try capture(store, settings, root, "paused")
        settings.clipboardCapturePaused = false
        tick()
        check(store.entries == prior, "resume does not backfill paused clipboard")
        for type in SensitivePasteboard.excludedTypes {
            copy("sensitive fixture"); board.setString("", forType: type); store.pollPasteboard()
        }
        check(store.entries == prior, "all supported sensitive markers excluded")
        settings.clipboardCaptureText = false
        copy("disabled fixture"); tick()
        check(store.captureState == .disabled && store.entries == prior, "turning off both types stops without deleting")
        settings.clipboardCaptureImages = true
        copy("text excluded fixture"); tick()
        check(store.entries == prior, "image-only choice excludes text")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        board.clearContents(); board.setData(bitmap.representation(using: .png, properties: [:])!, forType: .png); tick()
        check(store.entries.first?.kind == .image, "real timer records opted-in image")
        settings.clipboardCaptureImages = false
        settings.clipboardCaptureText = true
        settings.clipboardMaxItems = 5
        for i in 0..<7 { copy("limit fixture \(i)"); store.pollPasteboard() }
        check(store.entries.count == 5, "retention bound still works")

        let corruptRoot = root.appendingPathComponent("corrupt", isDirectory: true)
        try FileManager.default.createDirectory(at: corruptRoot, withIntermediateDirectories: true)
        let corruptURL = corruptRoot.appendingPathComponent("clipboard-history.json")
        let original = Data("invalid history fixture".utf8)
        try original.write(to: corruptURL)
        let corrupt = ClipboardStore(base: corruptRoot, defaults: AppEnvironment.defaults, pasteboard: board)
        corrupt.startMonitoring(); defer { corrupt.stopMonitoring() }
        check(corrupt.captureState == .failed && corrupt.errorMessage != nil, "corrupt file reports failure")
        copy("not replacing corrupt history"); corrupt.pollPasteboard()
        let retainedCorrupt = try Data(contentsOf: corruptURL)
        check(retainedCorrupt == original, "corrupt history bytes preserved")
        try capture(corrupt, settings, root, "failed")

        let failingRoot = root.appendingPathComponent("write-failure", isDirectory: true)
        let failing = ClipboardStore(base: failingRoot, defaults: AppEnvironment.defaults, pasteboard: board)
        failing.startMonitoring(); defer { failing.stopMonitoring() }
        try FileManager.default.createDirectory(at: failingRoot.appendingPathComponent("clipboard-history.json"), withIntermediateDirectories: true)
        copy("unsaved fixture"); failing.pollPasteboard()
        check(failing.captureState == .failed && failing.entries.isEmpty, "failed commit is not displayed as saved")
        settings.clipboardCapturePaused = true
        check(AppEnvironment.defaults.synchronize(), "test preferences flushed")
    }

    @MainActor static func capture(_ store: ClipboardStore, _ settings: AppSettingsStore,
                                   _ root: URL, _ name: String) throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: ClipboardHistoryView(store: store, settings: settings)
            .padding(24).frame(width: 820, height: 370).background(Color.black)
            .foregroundStyle(Color.white).environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 820, height: 370),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No fixture bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(name + ".png"))
        window.orderOut(nil)
    }
}
