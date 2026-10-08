import AppKit
import SwiftUI
@testable import PaulNotchCore

/// Controlled, offline native windows only. Never operates the installed app.
@main struct WorkspaceGeometryValidation {
    @MainActor static func main() throws {
        precondition(AppEnvironment.isPreview)
        let app = NSApplication.shared
        let delegate = AppDelegate()
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer {
            delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            app.windows.forEach { $0.orderOut(nil) }
        }
        settle(0.4)
        let window = app.windows.first { $0 is IslandPanel }!
        let host = window.contentView as! NSHostingView<IslandView>
        let ambient = app.windows.first { $0 is AmbientPanel }!.contentView as! NSHostingView<AmbientNotchView>
        host.rootView.onCloseWorkspace(); settle(0.6)
        ambient.rootView.onOpen(); settle(0.6)
        guard let move = find("workspace-move-handle", in: host),
              let resize = find("workspace-resize-handle", in: host) else {
            print("FAIL: the real notch has no reachable move/resize handles")
            exit(1)
        }
        let original = window.frame
        func drag(_ view: NSView, dx: CGFloat, dy: CGFloat) {
            let p = window.convertPoint(toScreen: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil))
            func event(_ type: NSEvent.EventType, _ global: NSPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: global), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            }
            view.mouseDown(with: event(.leftMouseDown, p))
            let end = NSPoint(x: p.x + dx, y: p.y + dy)
            view.mouseDragged(with: event(.leftMouseDragged, end))
            view.mouseUp(with: event(.leftMouseUp, end))
            settle(0.08)
        }
        drag(move, dx: 80, dy: -60)
        try require(abs(window.frame.minX - original.minX - 80) < 1 &&
                    abs(window.frame.maxY - original.maxY + 60) < 1,
                    "dragging the grip moves the existing panel with the pointer")
        try require(window.frame.size == original.size, "moving never resizes the panel")
        let moved = window.frame
        drag(resize, dx: 90, dy: -80)
        try require(abs(window.frame.width - moved.width - 90) < 1 &&
                    abs(window.frame.height - moved.height - 80) < 1,
                    "bottom-right drag grows width and height independently")
        try require(abs(window.frame.minX - moved.minX) < 1 && abs(window.frame.maxY - moved.maxY) < 1,
                    "resizing keeps the opposite top-left corner fixed")
        let resized = window.frame
        let coldGeometry = WorkspacePanelGeometry(defaults: AppEnvironment.defaults)
        try require(coldGeometry.frame(navigation: host.rootView.navigation,
                                       topInset: host.rootView.panelMetrics.topInset,
                                       screen: window.screen!.frame) == resized,
                    "a newly created geometry owner restores the persisted position and size")
        host.rootView.navigation.showQuotaConnections(selectedProvider: "muse"); settle(0.15)
        try require(window.frame.width >= 740 && window.frame.height > resized.height,
                    "connection setup opens a larger workspace without stretching Home cards")
        try require(host === window.contentView, "the connection route never opens a second workspace")
        host.rootView.navigation.closeQuotaConnections(); settle(0.15)
        try require(window.frame == resized, "returning Home restores its own chosen size")
        host.rootView.onCloseWorkspace(); settle(0.6)
        ambient.rootView.onOpen(); settle(0.6)
        try require(window.frame == resized, "collapse/reopen preserves chosen geometry")
        try require(host === window.contentView && app.windows.filter { $0 is IslandPanel }.count == 1,
                    "move, resize and reopen reuse one native workspace and its stores")
        drag(resize, dx: -10000, dy: 10000)
        try require(window.frame.width >= 480 && window.frame.height >= 340,
                    "shrinking cannot make controls unreachable")
        drag(move, dx: -10000, dy: -10000)
        let screen = window.screen!.frame
        try require(window.frame.minX >= screen.minX && window.frame.minY >= screen.minY &&
                    window.frame.maxX <= screen.maxX && window.frame.maxY <= screen.maxY,
                    "moving cannot lose the panel beyond the display")
        let external = NSRect(x: -1440, y: 0, width: 1440, height: 900)
        let onExternal = coldGeometry.frame(navigation: host.rootView.navigation,
                                           topInset: 32, screen: external)
        try require(onExternal.minX >= -1440 && onExternal.maxX <= 0 &&
                    onExternal.minY >= 0 && onExternal.maxY <= 900,
                    "restoration on a different display stays within that display")
        let smallDisplay = NSRect(x: 0, y: 0, width: 440, height: 300)
        let onSmall = coldGeometry.frame(navigation: host.rootView.navigation,
                                        topInset: 32, screen: smallDisplay)
        try require(onSmall.minX >= 0 && onSmall.maxX <= 440 && onSmall.minY >= 0 && onSmall.maxY <= 300,
                    "a saved large window cannot overflow a small display")
        let p = window.convertPoint(toScreen: move.convert(NSPoint(x: move.bounds.midX, y: move.bounds.midY), to: nil))
        let prior = window.frame
        for (type, point) in [(NSEvent.EventType.leftMouseDown, p), (.leftMouseDragged, NSPoint(x: p.x + 40, y: p.y + 40))] {
            move.mouseDownOrDrag(type, global: point, in: window)
        }
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        move.keyDown(with: escape)
        try require(window.frame == prior, "Escape reverses an unfinished window drag without persisting it")
        let doubleClick = NSEvent.mouseEvent(with: .leftMouseDown, location: move.convert(NSPoint(x: move.bounds.midX, y: move.bounds.midY), to: nil),
            modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil,
            eventNumber: 3, clickCount: 2, pressure: 1)!
        move.mouseDown(with: doubleClick); settle(0.1)
        try require(window.frame == original, "double-click offers an immediate return to the compact notch layout")
        print("PASS: real-shell pointer move/resize, minimums, screen bounds and retained geometry")
    }
    @MainActor static func find(_ id: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == id { return view }
        return view.subviews.lazy.compactMap { find(id, in: $0) }.first
    }
    @MainActor static func settle(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    static func require(_ value: @autoclosure () -> Bool, _ label: String) throws {
        if !value() { throw Failure(label: label) }
    }
    struct Failure: Error { let label: String }
}

private extension NSView {
    @MainActor func mouseDownOrDrag(_ type: NSEvent.EventType, global: NSPoint, in window: NSWindow) {
        let event = NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: global), modifierFlags: [],
            timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1)!
        if type == .leftMouseDown { mouseDown(with: event) } else { mouseDragged(with: event) }
    }
}
