import AppKit
import SwiftUI

/// Nonsecret placement only. The existing stores remain the sole quota readers.
@MainActor final class QuotaFloatingPlacement {
    static let bubbleSize = NSSize(width: 92, height: 92)
    private struct Saved: Codable {
        let display: UInt32
        let x, y: Double
        var isValid: Bool { x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y) }
    }
    private static let key = "quota-floating-placement-v1"
    private let defaults: UserDefaults
    private var saved: Saved?
    var isFloating: Bool { saved != nil }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), let decoded = try? JSONDecoder().decode(Saved.self, from: data),
           decoded.isValid { saved = decoded }
    }

    func preferredScreen(fallback: NSScreen?) -> NSScreen? {
        saved.flatMap { entry in NSScreen.screens.first { Self.displayID($0) == entry.display } } ?? fallback
    }

    func detach(at center: NSPoint, on screen: NSScreen) {
        let bounds = screen.visibleFrame
        let frame = Self.boundedBubble(center: center, on: bounds)
        saved = Saved(display: Self.displayID(screen),
            x: (frame.midX - bounds.minX) / max(1, bounds.width),
            y: (frame.midY - bounds.minY) / max(1, bounds.height))
        if let saved, let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: Self.key) }
    }

    func dock() { saved = nil; defaults.removeObject(forKey: Self.key) }

    func bubbleFrame(on screen: NSScreen) -> NSRect {
        let bounds = screen.visibleFrame
        let center = saved.map { NSPoint(x: bounds.minX + $0.x * bounds.width, y: bounds.minY + $0.y * bounds.height) }
            ?? NSPoint(x: bounds.midX, y: bounds.maxY - 60)
        return Self.boundedBubble(center: center, on: bounds)
    }

    func workspaceFrame(size: NSSize, on screen: NSScreen,
                        minimumSize: NSSize = NSSize(width: 480, height: 320)) -> NSRect {
        let bubble = bubbleFrame(on: screen)
        let frame = NSRect(x: bubble.midX - size.width / 2, y: bubble.maxY - size.height,
                           width: size.width, height: size.height)
        return WorkspacePanelGeometry.bounded(frame, on: screen.visibleFrame, minimumSize: minimumSize)
    }

    static func shouldDock(_ frame: NSRect, on screen: NSRect) -> Bool {
        abs(frame.midX - screen.midX) <= 120 && frame.maxY >= screen.maxY - 28
    }

    static func boundedBubble(center: NSPoint, on bounds: NSRect) -> NSRect {
        let size = NSSize(width: min(bubbleSize.width, bounds.width), height: min(bubbleSize.height, bounds.height))
        return NSRect(x: min(max(bounds.minX, center.x - size.width / 2), bounds.maxX - size.width),
                      y: min(max(bounds.minY, center.y - size.height / 2), bounds.maxY - size.height),
                      width: size.width, height: size.height)
    }

    private static func displayID(_ screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

struct FloatingQuotaInput: NSViewRepresentable {
    let summary: String
    let onOpen: () -> Void
    let onMove: (NSRect, NSScreen) -> Void
    let onDock: () -> Void
    var motion: QuotaOrbMotionRelay? = nil
    func makeNSView(context: Context) -> FloatingQuotaInputView { FloatingQuotaInputView() }
    func updateNSView(_ view: FloatingQuotaInputView, context: Context) {
        view.onOpen = onOpen; view.onMove = onMove; view.onDock = onDock
        view.motion = motion
        view.setAccessibilityLabel(summary)
        view.setAccessibilityHelp("单击展开；拖动移动；拖回屏幕顶部中央恢复刘海")
        view.toolTip = summary
    }
    static func dismantleNSView(_ view: FloatingQuotaInputView, coordinator: ()) { view.cancelTracking() }
}

/// One native tracker owns click OR drag; invisible circle corners pass through.
@MainActor final class FloatingQuotaInputView: NSView {
    var onOpen: () -> Void = {}
    var onMove: (NSRect, NSScreen) -> Void = { _, _ in }
    var onDock: () -> Void = {}
    weak var motion: QuotaOrbMotionRelay?
    private var startFrame: NSRect?
    private var startPoint: NSPoint?
    private var destinationScreen: NSScreen?
    private var isDragging = false
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("floating-quota-handle")
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard !isHidden, hypot(local.x - bounds.midX, local.y - bounds.midY) <= 39 else { return nil }
        return self
    }
    override func resetCursorRects() { addCursorRect(bounds.insetBy(dx: 7, dy: 7), cursor: .openHand) }
    override func mouseDown(with event: NSEvent) {
        guard let window, window.isVisible, !window.ignoresMouseEvents, event.window === window else { return }
        cancelTracking()
        startFrame = window.frame
        startPoint = window.convertPoint(toScreen: event.locationInWindow)
        destinationScreen = window.screen ?? NSScreen.main
        motion?.begin(x: window.frame.midX, at: event.timestamp)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window, event.window === window, let startFrame, let startPoint else { return }
        let pointer = window.convertPoint(toScreen: event.locationInWindow)
        let delta = NSPoint(x: pointer.x - startPoint.x, y: pointer.y - startPoint.y)
        if !isDragging && hypot(delta.x, delta.y) < 6 { return }
        isDragging = true
        destinationScreen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? destinationScreen
        guard let destinationScreen else { return }
        let center = NSPoint(x: startFrame.midX + delta.x, y: startFrame.midY + delta.y)
        window.setFrame(QuotaFloatingPlacement.boundedBubble(center: center, on: destinationScreen.frame), display: true)
        motion?.move(x: window.frame.midX, at: event.timestamp)
    }
    override func mouseUp(with event: NSEvent) {
        guard startFrame != nil, let window else { return }
        mouseDragged(with: event)
        let dragged = isDragging
        let screen = destinationScreen
        let frame = window.frame
        if dragged { motion?.end(at: event.timestamp) }
        else { motion?.cancel() }
        startFrame = nil; startPoint = nil; destinationScreen = nil; isDragging = false
        if dragged, let screen { onMove(frame, screen) }
        else if hypot(event.locationInWindow.x - bounds.midX, event.locationInWindow.y - bounds.midY) <= 39 { onOpen() }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelTracking() } else { super.keyDown(with: event) }
    }
    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let item = menu.addItem(withTitle: "放回顶部刘海", action: #selector(dockFromMenu), keyEquivalent: "")
        item.target = self
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    @objc private func dockFromMenu() { cancelTracking(); onDock() }
    override func accessibilityPerformPress() -> Bool { onOpen(); return true }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { cancelTracking() }
        super.viewWillMove(toWindow: newWindow)
    }
    func cancelTracking() {
        motion?.cancel()
        if let startFrame { window?.setFrame(startFrame, display: true) }
        startFrame = nil; startPoint = nil; destinationScreen = nil; isDragging = false
    }
}
