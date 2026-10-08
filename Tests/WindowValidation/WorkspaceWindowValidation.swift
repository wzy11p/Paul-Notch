import AppKit
import SwiftUI
#if canImport(PaulNotchCore)
@testable import PaulNotchCore
#elseif canImport(IslandMemo)
@testable import PaulNotchCore
#endif

/// Uses the real application shell, without imposing a test-only SwiftUI frame.
/// Clipboard capture, live Codex reads and other integrations stay disabled.
@main struct WorkspaceWindowValidation {
    @MainActor static func main() {
        do { try run() } catch { print("FAIL: \(error)"); exit(1) }
    }
    @MainActor static func run() throws {
        precondition(AppEnvironment.isPreview)
        let app = NSApplication.shared
        let delegate = AppDelegate()
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer {
            delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            app.windows.forEach { $0.orderOut(nil) }
        }
        settle(0.4)
        guard let window = app.windows.first(where: { $0 is IslandPanel }),
              let host = window.contentView as? NSHostingView<IslandView>,
              let shelf = app.windows.first(where: { $0 is AmbientPanel }),
              let ambient = shelf.contentView as? NSHostingView<AmbientNotchView>,
              let motion = Mirror(reflecting: delegate).children.first(where: { $0.label == "workspaceMotion" })?.value as? WorkspacePanelMotion else {
            throw Failure(message: "Missing real workspace/shelf")
        }
        let initialFrame = window.frame
        try require(initialFrame.height < 550, "initial workspace is compact")
        try require(host.rootView.navigation.isQuotaHome, "the existing notch opens on quota Home")
        try require(host.rootView.codexStatusStore === ambient.rootView.codexStatus,
                    "quota Home and the shelf must share the same Codex store")
        try require(!AppEnvironment.codexStatusReadsEnabled, "isolated tests never start live quota reads")
        try require(app.windows.filter { $0 is IslandPanel }.count == 1, "only one workspace panel is created")
        host.rootView.onCloseWorkspace()
        settle(until: { !window.isVisible })
        ambient.rootView.onOpen() // explicit clicks pin the panel during the tab stress pass
        settle(until: { motion.direction == nil })
        let tabs: [AppTab] = [.clipboard, .links, .recordings, .credentials, .home, .memo]
        for cycle in 0..<10 {
            for tab in tabs {
                host.rootView.navigation.select(tab)
                settle(0.06)
                let expected = WorkspacePanelLayout.size(isQuotaHome: tab == .home,
                    topInset: host.rootView.panelMetrics.topInset, screenWidth: window.screen?.frame.width ?? 1440)
                if abs(window.frame.height - expected.height) >= 0.5 {
                    print("Route: \(host.rootView.navigation.selectedTab), visible: \(window.isVisible), layout callback: \(host.rootView.navigation.onLayoutChange != nil)")
                    print(Mirror(reflecting: delegate).children.filter {
                        ["isAnimatingIn", "isAnimatingOut", "panelPresentationMode"].contains($0.label ?? "")
                    }.map { "\($0.label!): \($0.value)" })
                }
                try require(abs(window.frame.height - expected.height) < 0.5,
                            "\(tab.rawValue), cycle \(cycle): height \(window.frame.height), expected \(expected.height); min \(window.contentMinSize)")
                try require(abs(window.frame.width - expected.width) < 0.5, "each route keeps its bounded working width")
                try require(abs(window.frame.maxY - initialFrame.maxY) < 0.5, "top edge stays attached")
            }
        }
        print("PASS: 60 real-shell tab transitions keep bounded route sizes and top edge")
        host.rootView.navigation.showToolsHome()
        settle(0.1)
        try require(tabStrip(in: host) != nil, "original tools remain reachable")

        // Every deliberate click counts, including reversal during dismissal.
        // An older completion must not hide the newly reopened workspace.
        for cycle in 0..<12 {
            host.rootView.navigation.select(.links)
            settle(until: { motion.direction == nil })
            settle(0.06)
            let frameBeforeReversal = window.frame
            host.rootView.onCloseWorkspace()
            settle(0.04)
            let releasedClosingHitArea = window.ignoresMouseEvents
            guard let positionBeforeReversal = host.layer?.presentation()?.position else {
                throw Failure(message: "Expected a real Core Animation presentation layer during closing")
            }
            ambient.rootView.onOpen()
            settle(0.004)
            guard let positionAfterReversal = host.layer?.presentation()?.position else {
                throw Failure(message: "Expected a real presentation layer during reversal")
            }
            try require(abs(positionAfterReversal.y - positionBeforeReversal.y) < 45,
                        "reversal continues from the displayed position, not a restarted entrance")
            settle(until: { motion.direction == nil })
            settle(0.25) // An older closing callback must remain harmless afterward.
            try require(window.isVisible && !window.ignoresMouseEvents,
                        "a click during dismissal reopens and restores interaction, cycle \(cycle)")
            try require(releasedClosingHitArea, "closing content must stop intercepting clicks")
            try require(host.rootView.navigation.selectedTab == .links && window.frame == frameBeforeReversal,
                        "cycle \(cycle): reversal retains page/geometry; route \(host.rootView.navigation.selectedTab), before \(frameBeforeReversal), after \(window.frame)")
            ambient.rootView.onOpen()
            settle(until: { !window.isVisible })
            ambient.rootView.onOpen()
            if cycle.isMultiple(of: 2) {
                settle(0.02)
                ambient.rootView.onOpen()
                settle(until: { !window.isVisible })
                let flags = Mirror(reflecting: delegate).children.filter {
                    ["isAnimatingIn", "isAnimatingOut", "panelPresentationMode"].contains($0.label ?? "")
                }.map { "\($0.label!): \($0.value)" }
                try require(!window.isVisible, "close during opening completes; \(flags)")
                ambient.rootView.onOpen()
            }
            settle(until: { motion.direction == nil })
            try require(window.isVisible && shelf.isVisible, "workspace opens with shelf retained")
            try require(host.rootView.navigation.isQuotaHome, "each notch opening returns to quota Home")
            try require(abs(window.frame.height - initialFrame.height) < 0.5, "reopening retains compact height")
            try require(host.frame.origin == .zero, "animation returns content to origin")
        }
        print("PASS: 12 repeated close/reopen cycles, including reversal in both directions")

        // Toggle against the latest intent, not against an old animation state.
        for count in [2, 3, 8, 9, 20] {
            host.rootView.onCloseWorkspace()
            settle(until: { !window.isVisible })
            for _ in 0..<count {
                ambient.rootView.onOpen()
                settle(0.012)
            }
            settle(0.6)
            try require(window.isVisible == !count.isMultiple(of: 2),
                        "\(count) rapid clicks settle to the final intent")
            try require(shelf.isVisible, "rapid clicks retain the quota shelf")
            if window.isVisible {
                try require(host.frame.origin == .zero && !window.ignoresMouseEvents,
                            "the last open state has no translated or unclickable content")
            }
        }
        print("PASS: rapid 2/3/8/9/20-click bursts respect the last intent")

        ambient.rootView.onOpen()
        settle(0.02)
        try require(NSApp.sendAction(NSSelectorFromString("togglePresentationMode"), to: delegate, from: nil),
                    "presentation mode action is available")
        settle(0.7)
        try require(!window.isVisible && !shelf.isVisible,
                    "an old opening completion cannot resurrect presentation-hidden windows")
        _ = NSApp.sendAction(NSSelectorFromString("togglePresentationMode"), to: delegate, from: nil)
        ambient.rootView.onOpen()
        settle(0.4)
        try require(window.isVisible && !window.ignoresMouseEvents && host.frame.origin == .zero,
                    "leaving presentation mode restores a fully interactive workspace")
        print("PASS: presentation-mode conceal during opening cancels stale callbacks")
        try require(!host.rootView.appSettings.clipboardCaptureText && !host.rootView.appSettings.clipboardCaptureImages,
                    "window tests never enable clipboard capture")
        print("PASS: clipboard capture remains off")
    }

    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }
    @MainActor static func settle(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
    @MainActor static func settle(until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(1)
        while !condition() && Date() < deadline { settle(0.02) }
    }
    @MainActor static func tabStrip(in view: NSView) -> TabStripDocumentView? {
        if let strip = view as? TabStripDocumentView { return strip }
        return view.subviews.lazy.compactMap { tabStrip(in: $0) }.first
    }
}
