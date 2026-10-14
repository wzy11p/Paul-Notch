import AppKit
@testable import PaulNotchCore

/// Exercises the shipped native input owner, not a parallel preview gesture.
/// The regression is the first click opening/unmounting the orb before its
/// second click can invoke the existing return-to-notch command.
@main struct FloatingQuotaInputValidation {
    struct Failure: Error { let message: String }
    @MainActor static func main() {
        do { try run() } catch { print("FAIL: \(error)"); exit(1) }
    }

    @MainActor static func run() throws {
        _ = NSApplication.shared
        let window = NSPanel(contentRect: NSRect(x: 250, y: 300, width: 92, height: 92),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let input = FloatingQuotaInputView(frame: NSRect(x: 0, y: 0, width: 92, height: 92))
        window.contentView = input
        window.orderFrontRegardless()
        defer { input.cancelTracking(); window.orderOut(nil) }
        var opens = 0, docks = 0, moves = 0
        input.onOpen = { opens += 1 }
        input.onDock = { docks += 1 }
        input.onMove = { _, _ in moves += 1 }
        let wait = NSEvent.doubleClickInterval + 0.08

        click(input, window: window, count: 1)
        try require(opens == 0, "first click must leave the orb mounted until double-click recognition finishes")
        click(input, window: window, count: 2)
        settle(wait)
        try require(docks == 1 && opens == 0, "double-click docks exactly once, without also opening the workspace")

        click(input, window: window, count: 1)
        settle(wait)
        try require(opens == 1 && docks == 1, "an ordinary single click still opens exactly once")

        click(input, window: window, count: 1)
        input.cancelTracking()
        settle(wait)
        try require(opens == 1, "cancelled click cannot open later")

        click(input, window: window, count: 1)
        window.orderOut(nil)
        settle(wait)
        try require(opens == 1, "a hidden orb cannot reopen the workspace at an old click deadline")
        window.orderFrontRegardless()

        click(input, window: window, count: 1)
        input.mouseDown(with: event(.leftMouseDown, window: window, count: 2))
        input.mouseDragged(with: event(.leftMouseDragged, window: window, count: 2, point: NSPoint(x: 70, y: 46)))
        input.mouseUp(with: event(.leftMouseUp, window: window, count: 2))
        settle(wait)
        try require(moves == 1 && docks == 1 && opens == 1,
                    "dragging the second press cancels the pending click and never invokes either click command")

        let menu = input.menu(for: event(.rightMouseDown, window: window, count: 1))
        let item = menu?.items.first { $0.title == "回到刘海" }
        try require(item != nil && item?.target === input && item?.action != nil,
                    "the orb exposes a plainly named native return command, not only an undiscoverable gesture")
        click(input, window: window, count: 1)
        guard let item, let action = item.action else { throw Failure(message: "return action missing") }
        NSApplication.shared.sendAction(action, to: item.target, from: item)
        settle(wait)
        try require(docks == 2 && opens == 1, "the context-menu return cancels pending single-click work")

        click(input, window: window, count: 1)
        window.contentView = NSView(frame: input.frame)
        settle(wait)
        try require(opens == 1, "unmounting the input cancels delayed opening")
        window.contentView = input
        try require(input.accessibilityPerformPress(), "the accessibility open action remains available")
        try require(opens == 2, "accessibility press opens immediately without mouse double-click delay")
        print("PASS: single/double click, drag precedence, explicit return, hidden/cancel/unmount and accessibility")
    }

    @MainActor static func click(_ view: NSView, window: NSWindow, count: Int) {
        view.mouseDown(with: event(.leftMouseDown, window: window, count: count))
        view.mouseUp(with: event(.leftMouseUp, window: window, count: count))
    }
    @MainActor static func event(_ type: NSEvent.EventType, window: NSWindow, count: Int,
                                point: NSPoint = NSPoint(x: 46, y: 46)) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: count, pressure: 0)!
    }
    @MainActor static func settle(_ duration: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(duration)) }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
}
