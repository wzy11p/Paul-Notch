import AppKit
import SwiftUI
@testable import PaulNotchCore

/// The expanded surface must grow from the actual notch, not render a second
/// rounded card below the safe area. Account-free, mounted production views.
@main struct NotchExpansionValidation {
    struct Failure: Error { let message: String }
    @MainActor static func main() {
        do { try run() }
        catch { print("FAIL: \(error)"); fflush(stdout); exit(1) }
    }
    @MainActor static func run() throws {
        precondition(AppEnvironment.isPreview && !AppEnvironment.codexStatusReadsEnabled)
        let app = NSApplication.shared
        let delegate = AppDelegate()
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer {
            delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            app.windows.forEach { $0.orderOut(nil) }
        }
        settle(0.4)
        let window = app.windows.first { $0 is IslandPanel }!
        let shelf = app.windows.first { $0 is AmbientPanel }!
        let container = window.contentView as! WorkspacePanelContainer
        let host = container.workspace as! NSHostingView<IslandView>
        let glance = shelf.contentView as! NSHostingView<AmbientNotchView>
        host.rootView.onCloseWorkspace(); settle(0.4)
        let statusItem = Mirror(reflecting: delegate).children.first { $0.label == "statusItem" }!.value as! NSStatusItem
        let openItem = statusItem.menu!.items.first!
        _ = app.sendAction(openItem.action!, to: openItem.target, from: openItem)
        settle(0.4)
        try require(abs(window.frame.maxY - shelf.screen!.frame.maxY) < 0.6,
                    "The real P-menu action must retain the physical-top anchor")
        host.rootView.navigation.openFromNotch(); settle(0.2)
        print("Docked window \(window.frame), host \(host.frame), safe area \(host.safeAreaInsets)")
        let output = CommandLine.arguments.dropFirst().first ?? NSTemporaryDirectory()
        try save(container, to: output + "/expanded.png")
        // Sample the real mounted drawing, not a nominal frame or shape helper.
        let image = try raster(container)
        let top = color(image, x: 4, y: 2, size: container.bounds.size)
        try require(top.alphaComponent > 0.96 && top.redComponent < 0.08,
                    "Expanded notch must paint black to the physical top, without a rounded detached card / safe-area gap (\(top))")
        for depth in stride(from: 1, through: 55, by: 2) {
            let pixel = color(image, x: container.bounds.midX - 60, y: CGFloat(depth), size: container.bounds.size)
            try require(pixel.alphaComponent > 0.94,
                        "The notch and expanded surface must remain connected through the top band")
        }
        // Empty side padding samples the actual joined background, not a card.
        // A light graphite coat breaks the requested black frosted continuity.
        for depth in [CGFloat(130), 210, 300] {
            let pixel = color(image, x: 6, y: depth, size: container.bounds.size)
            try require(max(pixel.redComponent, pixel.greenComponent, pixel.blueComponent) < 0.18,
                        "Expanded body must remain deep black frost, not a separate gray slab (\(pixel))")
        }
        // Retarget the real open/close path. A slide has full-width content from
        // its first frame; an expansion keeps the top fixed and grows its mask.
        host.rootView.onCloseWorkspace(); settle(0.35)
        glance.rootView.onOpen(); settle(0.035)
        let pose = (container.contentHolder.layer?.mask?.presentation() ?? container.contentHolder.layer?.mask) as? CAShapeLayer
        try require(pose != nil, "Opening must expand a bounded silhouette, not slide a separate full-width card")
        if let bounds = pose?.path?.boundingBoxOfPath {
            try require(bounds.width >= shelf.frame.width - 1 && bounds.width < window.frame.width,
                        "The first expansion pose must grow out of the compact notch width")
            try require(abs(bounds.maxY - container.bounds.maxY) < 0.6,
                        "The expansion anchor must never leave the screen top")
        }
        host.rootView.onCloseWorkspace(); settle(0.035)
        glance.rootView.onOpen(); settle(0.55)
        try require(window.isVisible && container.workspace.frame.origin == .zero && container.contentHolder.layer?.mask == nil,
                    "Rapid reversal must finish in one connected expanded view and release the transient mask")
        host.rootView.onCloseWorkspace(); settle(0.4)
        try require(!window.isVisible && shelf.isVisible, "Collapse must restore only the original compact notch")
        let motion = Mirror(reflecting: delegate).children.first { $0.label == "workspaceMotion" }!.value as! WorkspacePanelMotion
        let notch = shelf.frame.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
        var finished = 0
        motion.expand(container, from: notch, direction: .opening, reduceMotion: true) { finished += 1 }
        try require(finished == 1 && motion.direction == nil && container.contentHolder.layer?.mask == nil,
                    "Reduce Motion must settle immediately without allocating a transition mask")
        motion.expand(container, from: notch, direction: .opening, reduceMotion: false) { finished += 1 }
        motion.cancel(); settle(0.4)
        try require(finished == 1 && container.contentHolder.layer?.mask == nil && !container.isMorphing,
                    "Cancellation must release the mask and prevent the stale completion")
        glance.rootView.onOpen()
        let menu = NSMenu(title: "Expansion menu priority")
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        settle(0.03)
        try require(container.layer?.mask == nil && container.contentHolder.layer?.mask != nil,
                    "Opening during a menu must expand from the screen edge without a full-width transparent cutout")
        settle(0.35)
        try require(container.layer?.mask == nil && container.contentHolder.layer?.mask == nil,
                    "An open menu must not leave a transparent strip after expansion finishes")
        let composed = try composedRaster(container)
        try composed.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output + "/expanded-menu-composed.png"))
        for x in [CGFloat(4), container.bounds.midX, container.bounds.maxX - 4] {
            let pixel = color(composed, x: x, y: 2, size: container.bounds.size)
            try require(pixel.alphaComponent > 0.94 && pixel.redComponent < 0.08,
                        "Actual compositor output must stay black across the complete top edge even while the menu is yielding")
        }
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        settle(0.2)
        try require(container.layer?.mask == nil, "Menu close must restore the joined top silhouette")
        print("PASS: physical-top pixels, anchored expansion, reversal, reduced motion, cancellation and gap-free composed menu state")
    }
    @MainActor static func composedRaster(_ view: NSView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let size = view.bounds.size
        guard let layer = view.layer,
              let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                bitsPerComponent: 8, bytesPerRow: Int(size.width) * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw Failure(message: "composed raster unavailable") }
        layer.render(in: context)
        guard let image = context.makeImage() else { throw Failure(message: "composed image unavailable") }
        return NSBitmapImageRep(cgImage: image)
    }
    @MainActor static func raster(_ view: NSView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Failure(message: "raster unavailable") }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }
    @MainActor static func color(_ rep: NSBitmapImageRep, x: CGFloat, y: CGFloat, size: NSSize) -> NSColor {
        rep.colorAt(x: Int(x * CGFloat(rep.pixelsWide) / size.width),
                    y: Int(y * CGFloat(rep.pixelsHigh) / size.height))!.usingColorSpace(.deviceRGB)!
    }
    @MainActor static func save(_ view: NSView, to path: String) throws {
        try raster(view).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    }
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }
    @MainActor static func settle(_ duration: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(duration)) }
}
