import AppKit
import SwiftUI
@testable import PaulNotchCore

/// Run against the debug module with a fresh PAUL_PREVIEW_DIRECTORY. Uses the same
/// isolated startup branch as personal mode, without live accounts or quota fixtures.
/// Notifications are delivered only inside this process; no system Space/display is changed.
@main struct AmbientEnvironmentValidation {
    struct Failure: Error, CustomStringConvertible { let description: String }

    @MainActor static func main() {
        do { try run() }
        catch { print("FAIL: \(error)"); exit(1) }
    }

    @MainActor static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    @MainActor static func settle(_ seconds: TimeInterval = 0.4) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    @MainActor static func value<T>(_ name: String, in object: Any, as type: T.Type) -> T? {
        Mirror(reflecting: object).children.first { $0.label == name }?.value as? T
    }

    @MainActor static func run() throws {
        try require(AppEnvironment.isPreview && AppEnvironment.usesIsolatedWorkspace,
                    "Use a fresh isolated preview, never the installed personal workspace")
        try require(!AppEnvironment.codexStatusReadsEnabled, "Live account reads must stay disabled")
        let app = NSApplication.shared
        let delegate = AppDelegate()
        print("START: real isolated AppDelegate startup"); fflush(stdout)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        var terminated = false
        defer {
            if !terminated {
                delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            }
            app.windows.forEach { $0.orderOut(nil) }
        }
        settle()
        guard let shelf = app.windows.first(where: { $0 is AmbientPanel }),
              let ambient = shelf.contentView as? NSHostingView<AmbientNotchView>,
              let workspace = app.windows.first(where: { $0 is IslandPanel }),
              let host = workspace.contentView as? NSHostingView<IslandView> else {
            throw Failure(description: "Missing real ambient/workspace panels")
        }
        host.rootView.onCloseWorkspace()
        settle()
        try require(!workspace.isVisible && shelf.isVisible, "Collapse keeps the real quota shelf visible")
        try require(ambient.rootView.codexStatus.quota == nil, "No synthetic quota is inserted")
        try require(!host.rootView.notifyServer.isRunning, "Isolation must not start the notification server")
        try require(value("globalHotKey", in: delegate, as: GlobalHotKey.self) == nil,
                    "Isolation must not register the legacy global shortcut")
        try require(value("monitorTimer", in: host.rootView.clipboardStore, as: Timer.self) == nil,
                    "Fresh preview must not start clipboard capture")
        print("PASS: isolated startup keeps background services off and quota unknown")

        let events: [(String, NotificationCenter, Notification.Name)] = [
            ("screen parameters", .default, NSApplication.didChangeScreenParametersNotification),
            ("Space switch", NSWorkspace.shared.notificationCenter, NSWorkspace.activeSpaceDidChangeNotification),
            ("frontmost/full-screen transition", NSWorkspace.shared.notificationCenter, NSWorkspace.didActivateApplicationNotification),
        ]
        for (label, center, name) in events {
            // Simulate geometry left over from an old display/Space. The notification
            // must recompute a real screen-anchored frame, not just register a callback.
            shelf.setFrame(shelf.frame.offsetBy(dx: 90, dy: -90), display: true)
            let stale = shelf.frame
            center.post(name: name, object: nil)
            settle()
            try require(shelf.frame != stale, "\(label): stale shelf geometry was never refreshed")
            guard let screen = shelf.screen else { throw Failure(description: "Shelf has no screen") }
            try require(abs(shelf.frame.maxY - screen.frame.maxY) < 1,
                        "\(label): shelf must attach to the current display top")
            try require(abs(shelf.frame.midX - screen.frame.midX) < 1,
                        "\(label): shelf must recenter on its display")
            try require(shelf.isVisible && !workspace.isVisible,
                        "\(label): refresh must retain collapsed state")

            // Invalidate the cached full-screen flag, then check the same environment
            // produces the previous state. This verifies recomputation, not a real OS
            // full-screen gesture; the physical acceptance steps are documented separately.
            let fullScreen = ambient.rootView.presentation.isFrontmostAppFullScreen
            ambient.rootView.presentation.isFrontmostAppFullScreen = !fullScreen
            center.post(name: name, object: nil)
            settle()
            try require(ambient.rootView.presentation.isFrontmostAppFullScreen == fullScreen,
                        "\(label): stale full-screen presentation must be recomputed")
            print("PASS: \(label) refreshes geometry/full-screen state without reopening workspace")
        }

        // The 120ms settling pass must correct metadata/geometry that changes after
        // the immediate notification, including after a burst of Space changes.
        for _ in 0..<5 {
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        }
        settle(0.04)
        shelf.setFrame(shelf.frame.offsetBy(dx: 70, dy: -70), display: true)
        let stale = shelf.frame
        settle()
        try require(shelf.frame != stale, "The delayed settling pass must repair late geometry")
        print("PASS: rapid Space notifications retain the delayed settling refresh")

        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        terminated = true
        shelf.setFrame(shelf.frame.offsetBy(dx: 60, dy: -60), display: true)
        let stopped = shelf.frame
        for (_, center, name) in events { center.post(name: name, object: nil) }
        settle()
        try require(shelf.frame == stopped, "Termination must cancel pending refresh and remove all observers")
        print("PASS: termination removes observers and cancels pending refresh")
        print("PASS: ambient environment regression complete (in-process notifications; no physical display/Space claim)")
    }
}
