import AppKit
import QuartzCore
@testable import PaulNotchCore

/// Inject only AppKit's animation/completion boundary to drop, delay, duplicate,
/// and reorder callbacks. The real-window suite separately exercises AppKit.
@main struct WorkspaceMotionValidation {
    @MainActor static func main() {
        _ = NSApplication.shared
        do { try run() } catch { print("FAIL: \(error)"); exit(1) }
    }

    @MainActor static func run() throws {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 470))
        var callbacks: [@Sendable () -> Void] = []
        var durations: [TimeInterval] = []
        let motion = WorkspacePanelMotion { view, origin, duration, _, finished in
            view.setFrameOrigin(origin)
            durations.append(duration)
            callbacks.append(finished)
        }
        var completed: [String] = []

        motion.move(view, to: NSPoint(x: 0, y: 428), direction: .closing, reduceMotion: false) { completed.append("old close") }
        motion.move(view, to: .zero, direction: .opening, reduceMotion: false) { completed.append("new open") }
        callbacks[0](); settle(0.02)
        try expect(completed.isEmpty && motion.direction == .opening, "old completion cannot settle a newer opening")
        callbacks[1](); callbacks[1](); settle(0.02)
        try expect(completed == ["new open"] && motion.direction == nil, "latest completion is accepted exactly once")
        settle(0.6)
        try expect(completed == ["new open"] && view.frame.origin == .zero, "canceled watchdog cannot close or translate a reopened view")
        print("PASS: stale, duplicated and reordered completions are harmless")

        callbacks.removeAll(); completed.removeAll()
        for index in 0..<50 {
            motion.move(view, to: NSPoint(x: 0, y: index.isMultiple(of: 2) ? 428 : 0),
                        direction: index.isMultiple(of: 2) ? .closing : .opening,
                        reduceMotion: false) { completed.append("\(index)") }
        }
        for callback in callbacks.reversed() { callback() }
        settle(0.03)
        try expect(completed == ["49"] && motion.direction == nil && view.frame.origin == .zero,
                   "50 reversals leave exactly the final state and one completion")
        print("PASS: 50 reversals with reverse-order callback delivery")

        callbacks.removeAll(); completed.removeAll(); durations.removeAll()
        motion.move(view, to: NSPoint(x: 0, y: 428), direction: .closing, reduceMotion: false) { completed.append("fallback close") }
        // Intentionally never deliver AppKit's callback.
        settle(0.65)
        try expect(completed == ["fallback close"] && motion.direction == nil && view.frame.origin.y == 428,
                   "missing native callback has a bounded close fallback")
        callbacks[0](); settle(0.02)
        try expect(completed.count == 1 && durations.last == 0, "late callback cannot repeat fallback side effects")
        print("PASS: lost close callback settles; late delivery does not repeat it")

        completed.removeAll(); callbacks.removeAll()
        motion.move(view, to: .zero, direction: .opening, reduceMotion: false) { completed.append("fallback open") }
        settle(0.7)
        try expect(completed == ["fallback open"] && motion.direction == nil && view.frame.origin == .zero,
                   "missing opening callback also recovers")
        print("PASS: lost opening callback settles without stranded content")

        completed.removeAll(); callbacks.removeAll()
        motion.move(view, to: NSPoint(x: 0, y: 428), direction: .closing, reduceMotion: false) { completed.append("canceled") }
        motion.cancel()
        callbacks[0](); settle(0.65)
        try expect(completed.isEmpty && motion.direction == nil, "conceal/termination cancellation invalidates callbacks and timers")
        print("PASS: conceal/termination cancels all pending lifecycle effects")

        completed.removeAll(); callbacks.removeAll(); durations.removeAll()
        motion.move(view, to: .zero, direction: .opening, reduceMotion: true) { completed.append("reduce open") }
        try expect(motion.direction == nil && completed == ["reduce open"] && view.frame.origin == .zero,
                   "reduced-motion opening settles synchronously")
        motion.move(view, to: NSPoint(x: 0, y: 428), direction: .closing, reduceMotion: true) { completed.append("reduce close") }
        try expect(motion.direction == nil && completed == ["reduce open", "reduce close"] && durations == [0, 0],
                   "reduced-motion closing has no artificial wait or watchdog")
        callbacks.forEach { $0() }; settle(0.65)
        try expect(completed.count == 2, "zero-duration callbacks cannot duplicate completions")
        print("PASS: reduced motion is immediate in both directions")

        completed.removeAll(); callbacks.removeAll()
        motion.move(view, to: .zero, direction: .opening, reduceMotion: false) {
            completed.append("open")
            motion.move(view, to: NSPoint(x: 0, y: 428), direction: .closing, reduceMotion: false) { completed.append("close") }
        }
        callbacks[0](); settle(0.02)
        callbacks[1](); settle(0.02)
        try expect(completed == ["open", "close"] && motion.direction == nil,
                   "a completion may start the next transition without losing its state")
        print("PASS: reentrant completion can safely start the next transition")

        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 92, height: 92),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let bubble = window.frame
        let expanded = NSRect(x: bubble.midX - 260, y: bubble.maxY - 336, width: 520, height: 336)
        completed.removeAll()
        motion.morph(window, to: bubble, direction: .closing, reduceMotion: false) { completed.append("stale") }
        motion.morph(window, to: expanded, direction: .opening, reduceMotion: false) { completed.append("expanded") }
        settle(0.65)
        try expect(completed == ["expanded"] && window.frame == expanded && motion.direction == nil,
                   "a stale floating close cannot hide a reopened workspace")
        motion.morph(window, to: bubble, direction: .closing, reduceMotion: true) { completed.append("circle") }
        try expect(window.frame == bubble && completed == ["expanded", "circle"] && motion.direction == nil,
                   "floating reduced motion settles to the exact circle synchronously")
        print("PASS: floating window reversal and reduced-motion collapse preserve final intent")

        let readingView = NSView(frame: NSRect(origin: .zero, size: expanded.size))
        readingView.wantsLayer = true
        readingView.layer?.backgroundColor = NSColor.darkGray.cgColor
        let container = WorkspacePanelContainer(workspace: readingView)
        window.contentView = container
        window.setFrame(expanded, display: false)
        motion.morph(window, to: bubble, direction: .closing, reduceMotion: false) {}
        settle(0.05)
        try expect(container.layer?.sublayers?.first(where: { $0.name == "quota-bubble-shell" })?.shadowOpacity == 0,
                   "the closing housing targets a shadow-free circle instead of keeping an outer halo")
        try expect(readingView.bounds.size == expanded.size && container.contentHolder.layer?.opacity == 0,
                   "compositor collapse freezes the mounted reading view rather than relayout on each frame")
        motion.morph(window, to: expanded, direction: .opening, reduceMotion: false) {}
        try expect(container.layer?.sublayers?.first(where: { $0.name == "quota-bubble-shell" })?.shadowOpacity ?? 0 > 0,
                   "reversing into the reading panel restores its ordinary depth without changing the circle")
        motion.cancel()
        try expect(window.frame == expanded && container.contentHolder.layer?.opacity == 1 && container.layer?.sublayers?.count == 1,
                   "cancel/reversal restores the same view and releases all transition layers")
        try expect(container.contentHolder.layer?.frame == NSRect(origin: .zero, size: expanded.size),
                   "restoring the reading layer must not leave its content shifted by half the panel")
        completed.removeAll()
        motion.morph(window, to: bubble, direction: .closing, reduceMotion: true) { completed.append("quiet") }
        try expect(window.frame == bubble && completed == ["quiet"] && container.layer?.sublayers?.count == 1,
                   "reduced motion creates no snapshot animation and settles immediately")
        print("PASS: fixed compositor viewport, cancellation cleanup and snapshot-free reduced motion")
    }

    struct Failure: Error { let message: String }
    static func expect(_ passed: @autoclosure () -> Bool, _ message: String) throws {
        if !passed() { throw Failure(message: message) }
    }
    @MainActor static func settle(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
}
