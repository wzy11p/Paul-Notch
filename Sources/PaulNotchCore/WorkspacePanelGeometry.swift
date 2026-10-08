import AppKit
import SwiftUI

/// Geometry only, in Paul's existing preference suite. No connection data.
@MainActor final class WorkspacePanelGeometry {
    private struct Saved: Codable {
        var centerOffset: Double = 0
        var topOffset: Double = 0
        var sizes: [String: [Double]] = [:]
        var isValid: Bool {
            centerOffset.isFinite && topOffset.isFinite && abs(centerOffset) < 100_000 &&
            topOffset >= 0 && topOffset < 100_000 && sizes.count <= 3 &&
            sizes.allSatisfy { key, size in
                ["quota", "connections", "tools"].contains(key) && size.count == 2 &&
                size.allSatisfy { $0.isFinite && $0 > 0 && $0 < 100_000 }
            }
        }
    }
    private let defaults: UserDefaults
    private static let key = "workspace-panel-geometry-v1"
    private var saved: Saved

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(Saved.self, from: data), decoded.isValid {
            saved = decoded
        } else { saved = Saved() }
    }

    func frame(navigation: WorkspaceNavigation, topInset: CGFloat, screen: NSRect) -> NSRect {
        let standard = WorkspacePanelLayout.size(isQuotaHome: navigation.isQuotaHome,
            isQuotaConnection: navigation.showsQuotaConnections, topInset: topInset, screenWidth: screen.width)
        let size = saved.sizes[navigation.layoutKey].map { NSSize(width: $0[0], height: $0[1]) } ?? standard
        let origin = NSPoint(x: screen.midX + saved.centerOffset - size.width / 2,
                             y: screen.maxY - saved.topOffset - size.height)
        return Self.bounded(NSRect(origin: origin, size: size), on: screen)
    }

    func record(_ frame: NSRect, route: String, screen: NSRect) {
        guard ["quota", "connections", "tools"].contains(route) else { return }
        saved.centerOffset = frame.midX - screen.midX
        saved.topOffset = max(0, screen.maxY - frame.maxY)
        saved.sizes[route] = [frame.width, frame.height]
        guard saved.isValid, let data = try? JSONEncoder().encode(saved) else { return }
        defaults.set(data, forKey: Self.key)
    }

    func reset() { saved = Saved(); defaults.removeObject(forKey: Self.key) }

    static func bounded(_ frame: NSRect, on screen: NSRect) -> NSRect {
        let availableWidth = max(1, screen.width - 24)
        let availableHeight = max(1, screen.height - 12)
        let size = NSSize(width: min(availableWidth, max(min(480, availableWidth), frame.width)),
                          height: min(availableHeight, max(min(360, availableHeight), frame.height)))
        return NSRect(x: min(max(screen.minX + 12, frame.minX), screen.maxX - 12 - size.width),
                      y: min(max(screen.minY + 12, frame.maxY - size.height), screen.maxY - size.height),
                      width: size.width, height: size.height)
    }

    static func resized(_ start: NSRect, delta: NSPoint, on screen: NSRect) -> NSRect {
        let maxWidth = max(1, screen.maxX - 12 - start.minX)
        let maxHeight = max(1, start.maxY - screen.minY - 12)
        let width = min(maxWidth, max(min(480, maxWidth), start.width + delta.x))
        let height = min(maxHeight, max(min(360, maxHeight), start.height - delta.y))
        return NSRect(x: start.minX, y: start.maxY - height, width: width, height: height)
    }
}

struct WorkspaceWindowGrip: NSViewRepresentable {
    let kind: WorkspaceGripView.Kind
    var onBegin: () -> Void = {}
    var onCommit: (NSRect, NSScreen) -> Void = { _, _ in }
    var onReset: () -> Void = {}
    func makeNSView(context: Context) -> WorkspaceGripView { WorkspaceGripView(kind: kind) }
    func updateNSView(_ view: WorkspaceGripView, context: Context) {
        view.onBegin = onBegin; view.onCommit = onCommit; view.onReset = onReset
    }
    static func dismantleNSView(_ view: WorkspaceGripView, coordinator: ()) { view.cancelTracking() }
}

/// Only these small handles own window geometry. Website/card drags remain theirs.
@MainActor final class WorkspaceGripView: NSView {
    enum Kind { case move, resize }
    let kind: Kind
    var onBegin: () -> Void = {}
    var onCommit: (NSRect, NSScreen) -> Void = { _, _ in }
    var onReset: () -> Void = {}
    private var startFrame: NSRect?
    private var startPointer: NSPoint?
    private var screen: NSScreen?
    private var isHovered = false
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        setAccessibilityIdentifier(kind == .move ? "workspace-move-handle" : "workspace-resize-handle")
        setAccessibilityRole(.button)
        setAccessibilityLabel(kind == .move ? "移动面板" : "调整面板大小")
        toolTip = kind == .move ? "拖动移动面板；双击还原大小与位置" : "拖动调整大小；双击还原大小与位置"
        setAccessibilityHelp(toolTip)
        NotificationCenter.default.addObserver(self, selector: #selector(windowLost(_:)),
                                               name: NSWindow.didResignKeyNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowLost(_:)),
                                               name: NSWindow.willCloseNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: kind == .move ? .openHand : .resizeUpDown)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: isHovered ? 0.72 : 0.42, alpha: 1).setStroke()
        if kind == .move {
            NSColor(white: isHovered ? 0.72 : 0.42, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: bounds.midX - 22, y: bounds.midY - 1.5, width: 44, height: 3),
                         xRadius: 1.5, yRadius: 1.5).fill()
        } else {
            let path = NSBezierPath()
            for offset: CGFloat in [0, 5] {
                path.move(to: NSPoint(x: bounds.maxX - 8 - offset, y: bounds.minY + 7))
                path.line(to: NSPoint(x: bounds.maxX - 7, y: bounds.minY + 8 + offset))
            }
            path.lineWidth = 1.5; path.lineCapStyle = .round; path.stroke()
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard let window, window.isVisible, event.window === window, !window.ignoresMouseEvents,
              !isHiddenOrHasHiddenAncestor, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        if event.clickCount == 2 { cancelTracking(); onReset(); return }
        cancelTracking()
        onBegin()
        window.makeKey(); window.makeFirstResponder(self)
        startFrame = window.frame
        startPointer = window.convertPoint(toScreen: event.locationInWindow)
        screen = window.screen ?? NSScreen.main
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window, event.window === window, let startFrame, let startPointer, let screen else { return }
        let pointer = window.convertPoint(toScreen: event.locationInWindow)
        let delta = NSPoint(x: pointer.x - startPointer.x, y: pointer.y - startPointer.y)
        let target = kind == .move
            ? WorkspacePanelGeometry.bounded(startFrame.offsetBy(dx: delta.x, dy: delta.y), on: screen.frame)
            : WorkspacePanelGeometry.resized(startFrame, delta: delta, on: screen.frame)
        window.setFrame(target, display: true)
    }
    override func mouseUp(with event: NSEvent) {
        guard startFrame != nil, let window, let screen else { return }
        mouseDragged(with: event)
        startFrame = nil; startPointer = nil; self.screen = nil
        onCommit(window.frame, screen)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, startFrame != nil { cancelTracking(); return }
        guard let window, let screen = window.screen, [123, 124, 125, 126].contains(event.keyCode) else {
            super.keyDown(with: event); return
        }
        let delta = NSPoint(x: event.keyCode == 123 ? -10 : event.keyCode == 124 ? 10 : 0,
                            y: event.keyCode == 125 ? -10 : event.keyCode == 126 ? 10 : 0)
        onBegin()
        let target = kind == .move
            ? WorkspacePanelGeometry.bounded(window.frame.offsetBy(dx: delta.x, dy: delta.y), on: screen.frame)
            : WorkspacePanelGeometry.resized(window.frame, delta: delta, on: screen.frame)
        window.setFrame(target, display: true); onCommit(window.frame, screen)
    }
    func cancelTracking() {
        if let startFrame { window?.setFrame(startFrame, display: true) }
        startFrame = nil; startPointer = nil; screen = nil
    }
    @objc private func windowLost(_ notification: Notification) {
        if notification.object as? NSWindow === window { cancelTracking() }
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { cancelTracking() }
        super.viewWillMove(toWindow: newWindow)
    }
    override func accessibilityPerformPress() -> Bool { onReset(); return true }
}
