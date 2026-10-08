import AppKit
import SwiftUI
@testable import PaulNotchCore

// Only the external notification's public app identity is synthetic. The real
// AppDelegate observer, shared stores, window lifecycle and shelf AX are used.
// Never launch/activate a vendor app, read its windows, or query a real account.
private final class ForegroundApplicationFixture: NSRunningApplication, @unchecked Sendable {
    private let identifier: String
    init(_ identifier: String) { self.identifier = identifier; super.init() }
    override var bundleIdentifier: String? { identifier }
}

@main struct AmbientForegroundNativeValidation {
    struct Failure: Error, CustomStringConvertible { let description: String }
    @MainActor static func main() {
        do { try run() } catch { print("FAIL: \(error)"); exit(1) }
    }
    @MainActor static func run() throws {
        guard AppEnvironment.isPreview, !AppEnvironment.codexStatusReadsEnabled else {
            throw Failure(description: "A fresh no-account preview is required")
        }
        let app = NSApplication.shared, delegate = AppDelegate()
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        var terminated = false
        defer {
            if !terminated { delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }
            app.windows.forEach { $0.orderOut(nil) }
        }
        settle()
        guard let shelf = app.windows.first(where: { $0 is AmbientPanel }),
              let ambient = shelf.contentView as? NSHostingView<AmbientNotchView>,
              let workspace = app.windows.first(where: { $0 is IslandPanel }),
              let home = workspace.contentView as? NSHostingView<IslandView> else {
            throw Failure(description: "Missing the real shared shelf/workspace")
        }
        home.rootView.onCloseWorkspace()
        // Real Core Animation completion can be delayed; the production fallback
        // is 430ms. Waiting a fixed 320ms can assert before a correct close ends.
        settle(until: { !workspace.isVisible })
        guard !workspace.isVisible else { throw Failure(description: "Workspace did not finish closing before the foreground pass") }
        activate("com.openai.codex")
        guard ambient.rootView.accessibilitySummary.contains("Codex") else {
            throw Failure(description: "BLOCKED: the real shelf's accessibility label was not obtained")
        }
        let originalWidth = shelf.frame.width
        for (bundle, name) in [
            ("com.anysphere.sand", "Grok Bot"),
            ("com.work.pc.doubao", "豆包工作"),
            ("com.todesktop.230313mzl4w4u92", "Cursor"),
            ("com.meta.endo", "Muse"),
            ("com.openai.codex", "Codex")
        ] {
            // The supplied event must select immediately. Do not pretend the
            // fixture changed the actual OS foreground app: running the loop
            // can legitimately deliver a newer real activation/Space event.
            activate(bundle)
            let summary = ambient.rootView.accessibilitySummary
            guard summary.contains(name) else {
                throw Failure(description: "Foreground \(name) must replace the shelf's Codex-only binding; actual AX: \(summary)")
            }
            guard shelf.frame.width == originalWidth, shelf.isVisible, !workspace.isVisible else {
                throw Failure(description: "Switching service must not widen/open the notch: \(name), width \(shelf.frame.width) vs \(originalWidth), shelf visible \(shelf.isVisible), workspace visible \(workspace.isVisible), fullscreen \(ambient.rootView.presentation.isFrontmostAppFullScreen)")
            }
            if name != "Codex", summary.contains("个 Codex 任务") {
                throw Failure(description: "Another provider must not inherit Codex task counts")
            }
            settle()
        }
        activate("com.work.pc.doubao")
        for bundle in ["local.paul.home-preview-20260905", "com.apple.finder", "com.google.Chrome"] {
            activate(bundle)
            guard ambient.rootView.accessibilitySummary.contains("豆包工作") else {
                throw Failure(description: "Paul/ordinary apps must retain the last AI service; actual: \(ambient.rootView.accessibilitySummary)")
            }
        }
        guard ambient.rootView.codexStatus === home.rootView.codexStatusStore,
              ambient.rootView.connections === home.rootView.quotaConnections,
              !home.rootView.quotaConnections.allowsConnections else {
            throw Failure(description: "The shelf must retain canonical stores and preview privacy")
        }
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        terminated = true
        activate("com.openai.codex")
        guard ambient.rootView.accessibilitySummary.contains("豆包工作") else {
            throw Failure(description: "Termination must detach the foreground observer")
        }
        print("PASS: foreground native shelf switching, real observer/AX-label presentation, shared stores, geometry, last-service retention and termination; no live account or vendor activation")
    }
    @MainActor static func activate(_ bundle: String) {
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification,
            object: nil, userInfo: [NSWorkspace.applicationUserInfoKey: ForegroundApplicationFixture(bundle)])
    }
    @MainActor static func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.32)) }
    @MainActor static func settle(until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }
}
