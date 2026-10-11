import AppKit
import SwiftUI
import QuartzCore
@testable import PaulNotchCore

/// Exercises the real shell in an isolated workspace, without account reads.
@main struct FloatingQuotaValidation {
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
        let workspace = app.windows.first { $0 is IslandPanel }!
        let host = (workspace.contentView as! WorkspacePanelContainer).workspace as! NSHostingView<IslandView>
        let ambient = app.windows.first { $0 is AmbientPanel }!
        let ambientHost = ambient.contentView as! NSHostingView<AmbientNotchView>
        // Launch opens the unpinned docked workspace. Deliberately clicking the
        // ambient shelf pins it, so that path cannot expose this exit regression.
        try require(workspace.isVisible, "the launch workspace is open before testing its unpinned setup")
        let launchFrame = workspace.frame
        host.rootView.navigation.showQuotaConnections(selectedProvider: "custom-api")
        workspace.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        settle(1.2)
        try require(workspace.isVisible && host.rootView.navigation.showsQuotaConnections,
                    "an unpinned docked connection form must remain open while copying a Key elsewhere")
        workspace.setFrame(launchFrame, display: false)
        host.rootView.navigation.closeQuotaConnections()
        guard let grip = find("workspace-move-handle", in: host) else { throw Failure("missing move handle") }
        let before = workspace.frame
        let attachedInset = host.rootView.panelMetrics.topInset
        drag(grip, window: workspace, dx: 210, dy: -180)
        let detached = workspace.frame
        var regressions: [String] = []
        try require(abs(detached.height + attachedInset - before.height) < 1,
                    "detaching removes the menu-safe height instead of moving the blank band below the grid")
        try require(detached.minX > before.minX + 150, "the actual workspace follows the move handle")
        let readingViewport = host.bounds.size
        let transitionStart = ProcessInfo.processInfo.systemUptime
        host.rootView.onCloseWorkspace()
        print("Morph preparation: \(Int((ProcessInfo.processInfo.systemUptime - transitionStart) * 1000)) ms")
        let container = workspace.contentView as! WorkspacePanelContainer
        var visualWidths: [CGFloat] = []
        var visualRadii: [CGFloat] = []
        var readingFadedBeforeCircle = false
        var snapshots: [(Int, CGImage)] = []
        for tick in 0..<18 {
            settle(0.015)
            guard let shell = container.layer?.sublayers?.first(where: { $0.name == "quota-bubble-shell" }) else { break }
            if host.bounds.size != readingViewport {
                print("Changed viewport: \(readingViewport) -> \(host.bounds.size), host frame \(host.frame), container \(container.bounds)")
                regressions.append("floating collapse must keep the reading viewport fixed instead of squeezing/reflowing the cards")
                break
            }
            if let visual = shell.presentation() {
                visualWidths.append(visual.bounds.width)
                visualRadii.append(visual.cornerRadius)
                if let visibleReading = container.contentHolder.layer?.presentation(), visibleReading.opacity > 0.1 {
                    if abs(visibleReading.frame.midX - visual.frame.midX) > 1 ||
                       abs(visibleReading.frame.midY - visual.frame.midY) > 1 {
                        regressions.append("the animated reading layer must remain centered inside its housing")
                    }
                }
                if visual.bounds.width < 180 && container.contentHolder.layer?.presentation()?.opacity ?? 1 < 0.05 {
                    readingFadedBeforeCircle = true
                }
            }
            let sampleTime = Int((ProcessInfo.processInfo.systemUptime - transitionStart) * 1000)
            if ProcessInfo.processInfo.environment["PAUL_MORPH_EVIDENCE"] != nil,
               [0, 3, 7, 12, 17].contains(tick), let image = raster(container.layer?.presentation(), size: container.bounds.size) {
                snapshots.append((sampleTime, image))
            }
        }
        if let path = ProcessInfo.processInfo.environment["PAUL_MORPH_EVIDENCE"] {
            try contactSheet(snapshots, path: path)
        }
        print("Displayed widths: \(visualWidths.map { Int($0) }); corners: \(visualRadii.map { Int($0) })")
        try require(visualWidths.count >= 8, "the real compositor supplies intermediate frames, not only an endpoint jump")
        if !visualWidths.isEmpty {
            try require(visualWidths.first! > 150 && visualWidths.last! < visualWidths.first! - 100,
                        "the displayed housing contracts continuously through intermediate sizes")
            try require(visualRadii.last! > visualRadii.first! + 8,
                        "the displayed corners soften toward the circle during the same transition")
        }
        try require(readingFadedBeforeCircle,
                    "reading text disappears before the housing becomes tiny, rather than remaining squeezed inside")
        settle(0.55)
        try require(ambient.isVisible && !workspace.isVisible && ambient.frame.width <= 100 && ambient.frame.height <= 100,
                    "a detached workspace collapses into a small circle instead of returning to the notch")
        try require(abs(ambient.frame.midX - detached.midX) < 2 && ambient.frame.midY < before.maxY - 100,
                    "collapse retains the owner's detached position")
        try require(host.rootView.panelMetrics.topInset == 0,
                    "a floating workspace does not retain the physical-notch spacer")
        guard let bubble = find("floating-quota-handle", in: ambientHost) else { throw Failure("missing bubble drag target") }
        try require(bubble.isAccessibilityElement(),
                    "the small circle exposes its open action as a native accessibility target")
        let bubbleBefore = ambient.frame
        drag(bubble, window: ambient, dx: -85, dy: -75)
        try require(!workspace.isVisible && abs(ambient.frame.minX - bubbleBefore.minX + 85) < 2,
                    "dragging the circle moves it without also opening the workspace")
        let movedBubble = ambient.frame
        let restored = QuotaFloatingPlacement(defaults: AppEnvironment.defaults)
        try require(restored.isFloating && restored.bubbleFrame(on: ambient.screen!) == movedBubble,
                    "cold placement restoration preserves the circle without reconnecting any source")
        ambientHost.rootView.onOpen()
        host.rootView.navigation.showQuotaConnections(selectedProvider: "muse")
        settle(0.65)
        try require(workspace.frame.width >= 750,
                    "a connection route selected during floating opening receives its full viewport")
        settle(1.7)
        try require(workspace.isVisible,
                    "an active connection/login page never auto-collapses while the pointer is elsewhere")
        host.rootView.navigation.closeQuotaConnections()
        settle(0.15)
        try require(workspace.isVisible && !ambient.isVisible,
                    "opening from the bubble shows one workspace without a duplicate quota surface")
        try require(abs(workspace.frame.midX - movedBubble.midX) < 2,
                    "the workspace expands from the moved circle")
        host.rootView.onCloseWorkspace(); settle(0.08)
        let housing = container.layer?.sublayers?.first { $0.name == "quota-bubble-shell" }
        let reversingFrame = housing?.presentation()?.frame
        ambientHost.rootView.onOpen(); settle(0.003)
        let reversedFrame = housing?.presentation()?.frame
        try require(reversingFrame != nil && reversedFrame != nil &&
                    abs(reversingFrame!.midX - reversedFrame!.midX) < 20 &&
                    abs(reversingFrame!.width - reversedFrame!.width) < 40,
                    "a mid-collapse reversal starts from the visible housing, not from a circle or expanded endpoint")
        settle(0.65)
        host.rootView.onCloseWorkspace(); settle(0.45)
        try require(ambient.frame == movedBubble, "repeated expansion does not drift the circle")
        for _ in 0..<8 {
            ambientHost.rootView.onOpen()
            host.rootView.onCloseWorkspace()
            ambientHost.rootView.onOpen()
        }
        settle(0.5)
        try require(workspace.isVisible && !ambient.isVisible && !workspace.ignoresMouseEvents,
                    "rapid floating reversals cannot leave a hidden or unclickable workspace")
        host.rootView.onCloseWorkspace(); settle(0.4)
        ambientHost.rootView.onOpen(); settle(0.65)
        let currentGrip = find("workspace-move-handle", in: host)!
        let screen = workspace.screen!
        let floatingHeight = workspace.frame.height
        // A near-notch drop is intentionally not exact; docking owns the snap.
        drag(currentGrip, window: workspace, dx: screen.frame.midX + 64 - workspace.frame.midX,
             dy: screen.frame.maxY - 14 - workspace.frame.maxY)
        settle(0.5)
        if abs(workspace.frame.midX - screen.frame.midX) > 0.5 || abs(workspace.frame.maxY - screen.frame.maxY) > 0.5 {
            regressions.append("near-notch drop must snap the expanded panel to the exact hardware center and top, without a protruding offset")
        }
        try require(abs(workspace.frame.height - host.rootView.panelMetrics.topInset - floatingHeight) < 1,
                    "docking preserves the manually chosen usable height")
        host.rootView.onCloseWorkspace(); settle(0.45)
        try require(ambient.isVisible && ambient.frame.width > 100 && ambient.frame.height <= 36,
                    "dragging back to top center restores the compact notch")
        ambientHost.rootView.onOpen(); settle(0.4)
        let bubbleDockGrip = find("workspace-move-handle", in: host)!
        drag(bubbleDockGrip, window: workspace, dx: 170, dy: -140)
        let bubbleDockResize = find("workspace-resize-handle", in: host)!
        drag(bubbleDockResize, window: workspace, dx: 60, dy: -50)
        let chosenFloatingSize = workspace.frame.size
        host.rootView.onCloseWorkspace(); settle(0.4)
        let returningBubble = find("floating-quota-handle", in: ambientHost)!
        drag(returningBubble, window: ambient, dx: screen.frame.midX + 45 - ambient.frame.midX,
             dy: screen.frame.maxY - 10 - ambient.frame.maxY)
        ambientHost.rootView.onOpen(); settle(0.4)
        try require(abs(workspace.frame.width - chosenFloatingSize.width) < 1 &&
                    abs(workspace.frame.height - host.rootView.panelMetrics.topInset - chosenFloatingSize.height) < 1,
                    "returning the circle to the notch preserves chosen dimensions instead of resetting every route")
        try require(abs(workspace.frame.midX - screen.frame.midX) < 0.5 &&
                    abs(workspace.frame.maxY - screen.frame.maxY) < 0.5,
                    "circle docking also restores the exact hardware center and top")
        host.rootView.onCloseWorkspace(); settle(0.4)
        ambientHost.rootView.onOpen()
        host.rootView.navigation.showQuotaConnections(selectedProvider: "custom-api")
        settle(0.4)
        // The physical pointer remains untouched. Put only this isolated test
        // window outside its location so the real hover timer takes the exit path.
        workspace.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        settle(1.2)
        try require(workspace.isVisible && host.rootView.navigation.showsQuotaConnections,
                    "a docked connection form must not lose its input when the pointer leaves to copy a Key")
        host.rootView.onCloseWorkspace(); settle(0.4)
        try require(!workspace.isVisible && ambient.isVisible,
                    "the protected docked setup still obeys explicit Collapse")
        try require(app.windows.filter { $0 is IslandPanel }.count == 1 && app.windows.filter { $0 is AmbientPanel }.count == 1,
                    "docking and floating reuse the existing windows and service owners")
        if !regressions.isEmpty {
            regressions.forEach { print("FAIL: \($0)") }
            throw Failure(regressions.joined(separator: "; "))
        }
        print("PASS: detached collapse with fixed reading viewport, circle dragging, cold restoration, rapid reversals, expansion anchor and exact re-docking")
    }
    @MainActor static func drag(_ view: NSView, window: NSWindow, dx: CGFloat, dy: CGFloat) {
        let point = window.convertPoint(toScreen: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil))
        for (type, p) in [(NSEvent.EventType.leftMouseDown, point),
                          (.leftMouseDragged, NSPoint(x: point.x + dx, y: point.y + dy)),
                          (.leftMouseUp, NSPoint(x: point.x + dx, y: point.y + dy))] {
            let event = NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: p), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            switch type { case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseDragged: view.mouseDragged(with: event)
            default: view.mouseUp(with: event) }
        }
        settle(0.06)
    }
    @MainActor static func find(_ id: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == id { return view }
        return view.subviews.lazy.compactMap { find(id, in: $0) }.first
    }
    @MainActor static func settle(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    @MainActor static func raster(_ layer: CALayer?, size: NSSize) -> CGImage? {
        guard let layer, let context = CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: 2, y: 2)
        layer.render(in: context)
        return context.makeImage()
    }
    @MainActor static func contactSheet(_ captures: [(Int, CGImage)], path: String) throws {
        let canvas = NSImage(size: NSSize(width: max(1, captures.count) * 240, height: 200))
        canvas.lockFocus()
        NSColor(white: 0.58, alpha: 1).setFill()
        NSRect(origin: .zero, size: canvas.size).fill()
        for (index, capture) in captures.enumerated() {
            let image = NSImage(cgImage: capture.1, size: NSSize(width: capture.1.width, height: capture.1.height))
            let ratio = min(220 / image.size.width, 162 / image.size.height)
            image.draw(in: NSRect(x: CGFloat(index * 240 + 10), y: 24, width: image.size.width * ratio, height: image.size.height * ratio))
            ("\(capture.0) ms" as NSString).draw(at: NSPoint(x: CGFloat(index * 240 + 10), y: 5),
                withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black])
        }
        canvas.unlockFocus()
        let bitmap = NSBitmapImageRep(data: canvas.tiffRepresentation!)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    }
    static func require(_ value: @autoclosure () -> Bool, _ label: String) throws {
        if !value() { throw Failure(label) }
    }
    struct Failure: Error { let label: String; init(_ label: String) { self.label = label } }
}
