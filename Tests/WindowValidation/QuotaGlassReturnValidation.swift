import AppKit
import QuartzCore
import SwiftUI
@testable import PaulNotchCore

/// Real transparent pixels and the existing native return command, isolated
/// from accounts. No desktop capture or personal input is used.
@main struct QuotaGlassReturnValidation {
    struct Failure: Error { let message: String }
    @MainActor static func main() {
        do {
            guard AppEnvironment.isPreview else { throw Failure(message: "isolated preview required") }
            _ = NSApplication.shared
            if CommandLine.arguments.contains("--glass") { try glass() }
            else if CommandLine.arguments.contains("--lifecycle") { try lifecycle() }
            else { try returnToNotch() }
        } catch { print("FAIL: \(error)"); exit(1) }
    }
    @MainActor static func glass() throws {
        for percent: Int? in [nil, 100] {
            let view = QuotaLiquidOrbView(frame: NSRect(x: 0, y: 0, width: 78, height: 78))
            view.configure(level: QuotaLiquidLevel(value: percent.map { .percent($0) }), reducedMotion: true)
            view.layoutSubtreeIfNeeded()
            guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw Failure(message: "native glass raster unavailable")
            }
            view.cacheDisplay(in: view.bounds, to: image)
            var transmission: [CGFloat] = []
            var waterChroma: [CGFloat] = []
            for y in stride(from: 25, to: 55, by: 3) {
                for x in stride(from: 25, to: 55, by: 3) {
                    let color = image.colorAt(x: x * image.pixelsWide / 78, y: y * image.pixelsHigh / 78)!
                    // Compositing the same real RGBA pixel on black vs white
                    // transmits exactly this fraction of the backdrop contrast.
                    transmission.append(1 - color.alphaComponent)
                    let rgb = color.usingColorSpace(.deviceRGB)!
                    waterChroma.append((rgb.blueComponent - rgb.redComponent) * rgb.alphaComponent)
                }
            }
            transmission.sort()
            let median = transmission[transmission.count / 2]
            waterChroma.sort()
            let chroma = waterChroma[waterChroma.count / 2]
            print("Backdrop contrast transmitted \(percent == nil ? "air" : "water"): \(median)")
            if percent != nil {
                print("Water blue/red separation: \(chroma)")
                try require(chroma >= 0.20, "liquid must retain visible blue/violet saturation, not wash out into the light glass")
            }
            try require(median > (percent == nil ? 0.65 : 0.35),
                        "the \(percent == nil ? "air shell" : "liquid") must reveal meaningful backdrop contrast, not an almost solid coating")
            view.stop()
        }
        print("PASS: real native glass/water pixels transmit the background without another window or screen capture")
    }
    @MainActor static func returnToNotch() throws {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer {
            delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            app.windows.forEach { $0.orderOut(nil) }
        }
        settle(0.35)
        let workspace = app.windows.first { $0 is IslandPanel }!
        let host = (workspace.contentView as! WorkspacePanelContainer).workspace as! NSHostingView<IslandView>
        let ambient = app.windows.first { $0 is AmbientPanel }!
        let ambientHost = ambient.contentView as! NSHostingView<AmbientNotchView>
        let screen = workspace.screen!
        let dockedFrame = ambient.frame
        let grip = find("workspace-move-handle", in: host)!
        // Drag to the physical top, then release: do not bypass input by onDock.
        drag(grip, window: workspace, dx: -210, dy: -230)
        host.rootView.onCloseWorkspace(); settle(0.5)
        guard let draggedInput = find("floating-quota-handle", in: ambientHost) else {
            throw Failure(message: "mounted drag input is missing")
        }
        let offCenter = ambient.frame
        drag(draggedInput, window: ambient, dx: dockedFrame.midX - 200 - offCenter.midX,
             dy: screen.frame.maxY - offCenter.maxY + 20)
        settle(0.1)
        try require(QuotaFloatingPlacement(defaults: AppEnvironment.defaults).isFloating,
                    "dragging beside the notch must not magnetize unrelated menu positions")
        let dragStart = ambient.frame
        drag(draggedInput, window: ambient, dx: dockedFrame.midX - dragStart.midX,
             dy: screen.frame.maxY - dragStart.maxY + 20)
        settle(0.8)
        try require(!QuotaFloatingPlacement(defaults: AppEnvironment.defaults).isFloating && ambient.frame == dockedFrame,
                    "physical drag/release must attach to the same top target as double-click")
        print("PASS: actual mounted drag/release docks at the physical top")
        ambientHost.rootView.onOpen(); settle(0.4)
        drag(grip, window: workspace, dx: -210, dy: -230)
        host.rootView.onCloseWorkspace(); settle(0.5)
        let original = ambient.frame
        try require(original.size == QuotaFloatingPlacement.bubbleSize, "a detached sphere is the return source")
        guard let input = find("floating-quota-handle", in: ambientHost) else {
            throw Failure(message: "mounted orb input is missing")
        }
        click(input, window: ambient, count: 1)
        try require(!workspace.isVisible, "first click cannot remove the orb before a possible double-click")
        click(input, window: ambient, count: 2)
        try require(QuotaFloatingPlacement(defaults: AppEnvironment.defaults).isFloating,
                    "return must retain the flying circle before committing docked placement, not teleport immediately")
        try require(ambientHost.window === ambient && ambientHost.isDescendant(of: ambient.contentView!) &&
                    ambientHost.bounds.size == QuotaFloatingPlacement.bubbleSize,
                    "the flight carries the same mounted content at a fixed viewport")
        var samples: [CGPoint] = []
        for _ in 0..<15 {
            settle(0.022)
            if let carrier = layer("quota-dock-return-flight", in: ambient.contentView?.layer)?.presentation() {
                samples.append(CGPoint(x: ambient.frame.minX + carrier.position.x,
                                       y: ambient.frame.minY + carrier.position.y))
            }
        }
        try require(samples.count >= 6, "return has real compositor intermediate positions")
        try require(samples.last!.y > samples.first!.y + 60,
                    "the actual circle travels upward instead of merely crossfading at the destination")
        settle(0.4)
        try require(!QuotaFloatingPlacement(defaults: AppEnvironment.defaults).isFloating,
                    "arrival commits docked placement")
        print("Dock frames initial=\(dockedFrame) arrived=\(ambient.frame) screen=\(screen.frame)")
        // An odd-width native window may be rounded by AppKit by half a point.
        try require(abs(ambient.frame.midX - screen.frame.midX) <= 0.5 &&
                    abs(ambient.frame.maxY - screen.frame.maxY) <= 0.5 && ambient.frame == dockedFrame,
                    "arrival restores the exact existing notch without protruding or changing geometry")
        try require(ambient.contentView === ambientHost && ambient.alphaValue == 1,
                    "arrival returns the same live glance without another overlay")
        try require(ambient.ignoresMouseEvents,
                    "arrival restores docked click-through for automatic menu yielding per ADR-072")
        try require(app.windows.filter { $0 is AmbientPanel }.count == 1,
                    "return reuses the existing panel, not another overlay window")
        ambientHost.rootView.onOpen(); settle(0.4)
        drag(find("workspace-move-handle", in: host)!, window: workspace, dx: 180, dy: -190)
        host.rootView.onCloseWorkspace(); settle(0.5)
        guard let nextInput = find("floating-quota-handle", in: ambientHost),
              let menu = nextInput.menu(for: NSEvent.mouseEvent(with: .rightMouseDown,
                  location: NSPoint(x: 46, y: 46), modifierFlags: [],
                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: ambient.windowNumber,
                  context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!),
              let item = menu.items.first(where: { $0.title == "回到刘海" }), let action = item.action else {
            throw Failure(message: "mounted orb return menu is missing")
        }
        NSApplication.shared.sendAction(action, to: item.target, from: item)
        let flightLayer = layer("quota-dock-return-flight", in: ambient.contentView?.layer)
        ambientHost.rootView.onDock()
        try require(layer("quota-dock-return-flight", in: ambient.contentView?.layer) === flightLayer,
                    "repeated return does not stack flights")
        ambientHost.rootView.onOpen(); settle(0.35)
        let opened = workspace.frame
        workspace.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        settle(0.9)
        try require(workspace.isVisible && !workspace.ignoresMouseEvents,
                    "opening during return retains the docked click intent after the old flight deadline")
        workspace.setFrame(opened, display: false)
        print("PASS: native return travels, merges, restores exact geometry and releases temporary composition")
    }
    @MainActor static func layer(_ name: String, in root: CALayer?) -> CALayer? {
        guard let root else { return nil }
        if root.name == name { return root }
        return (root.sublayers ?? []).lazy.compactMap { layer(name, in: $0) }.first
    }
    @MainActor static func lifecycle() throws {
        let screen = NSScreen.main!
        let source = NSRect(x: screen.visibleFrame.midX - 180, y: screen.visibleFrame.midY, width: 92, height: 92)
        let target = NSRect(x: screen.frame.midX - 110, y: screen.frame.maxY - 28, width: 220, height: 28)
        let window = NSWindow(contentRect: source, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.isOpaque = false; window.backgroundColor = .clear
        let content = NSView(frame: NSRect(origin: .zero, size: source.size))
        content.wantsLayer = true; content.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
        window.contentView = content; window.orderFrontRegardless()
        let motion = QuotaDockReturnMotion()
        defer { motion.cancel(); window.orderOut(nil) }
        var completed = 0
        motion.start(window, to: target, reduceMotion: true) { completed += 1 }
        try require(completed == 1 && !motion.isRunning && window.contentView === content,
                    "Reduce Motion confirms immediately without spatial animation or a delayed callback")
        motion.start(window, to: target, reduceMotion: false) { completed += 1 }
        motion.start(window, to: target, reduceMotion: false) { completed += 100 }
        settle(0.05); motion.cancel(); settle(0.6)
        try require(completed == 1 && !motion.isRunning && window.frame == source &&
                    window.contentView === content && !window.ignoresMouseEvents,
                    "cancel/repeated return releases its host and never commits a stale arrival")
        motion.start(window, to: target, reduceMotion: false) { completed += 1 }
        window.orderOut(nil); settle(0.6)
        try require(completed == 1 && !motion.isRunning && !window.isVisible,
                    "hiding cancels the flight without reopening the panel at its old deadline")
        window.orderFrontRegardless()
        motion.start(window, to: target, reduceMotion: false) { completed += 1 }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        settle(0.6)
        try require(completed == 1 && !motion.isRunning && window.contentView === content,
                    "sleep removes active composition without committing a return")
        motion.start(window, to: target, reduceMotion: false) { completed += 1 }
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        settle(0.6)
        try require(completed == 2 && !motion.isRunning && window.contentView === content,
                    "display changes resolve once and release obsolete screen geometry")
        print("PASS: reduced motion, repeated input, cancel, hidden, sleep and display lifecycle")
    }
    @MainActor static func find(_ id: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == id { return view }
        return view.subviews.lazy.compactMap { find(id, in: $0) }.first
    }
    @MainActor static func drag(_ view: NSView, window: NSWindow, dx: CGFloat, dy: CGFloat) {
        let origin = window.convertPoint(toScreen: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil))
        for (type, point) in [(NSEvent.EventType.leftMouseDown, origin),
                              (.leftMouseDragged, NSPoint(x: origin.x + dx, y: origin.y + dy)),
                              (.leftMouseUp, NSPoint(x: origin.x + dx, y: origin.y + dy))] {
            let event = NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: point), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
            switch type { case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseDragged: view.mouseDragged(with: event)
            default: view.mouseUp(with: event) }
        }
    }
    @MainActor static func click(_ view: NSView, window: NSWindow, count: Int) {
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: count, pressure: 0)!
            if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
        }
    }
    @MainActor static func settle(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
}
