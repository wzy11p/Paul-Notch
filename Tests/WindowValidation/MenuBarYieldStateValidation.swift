import AppKit
#if canImport(PaulNotchCore)
@testable import PaulNotchCore
#endif

@main struct MenuBarYieldStateValidation {
    struct Failure: Error { let message: String }
    @MainActor final class MenuProbe { var isOpen = false; var calls = 0 }
    @MainActor static func main() {
        do { try run() }
        catch { print("FAIL: \(error)"); fflush(stdout); exit(1) }
    }
    @MainActor static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(message: message) }
    }
    @MainActor static func settle(_ duration: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(duration))
    }
    @MainActor static func run() throws {
        _ = NSApplication.shared
        let ambient = NSPanel(contentRect: NSRect(x: 600, y: 924, width: 275, height: 32),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let workspace = NSPanel(contentRect: NSRect(x: 300, y: 456, width: 800, height: 500),
                                styleMask: [.borderless], backing: .buffered, defer: false)
        ambient.contentView = NSView(frame: NSRect(origin: .zero, size: ambient.frame.size))
        workspace.contentView = NSView(frame: NSRect(origin: .zero, size: workspace.frame.size))
        ambient.contentView!.wantsLayer = true; workspace.contentView!.wantsLayer = true
        ambient.contentView!.layer!.cornerRadius = 16
        workspace.contentView!.layer!.backgroundColor = NSColor.red.cgColor
        workspace.level = .statusBar
        var point = NSPoint(x: 600, y: 800)
        var pressed = 0
        let probe = MenuProbe()
        var context = MenuBarYieldController.Context(enabled: true,
            screenFrame: NSRect(x: 0, y: 0, width: 1470, height: 956), menuHeight: 33,
            workspaceAcceptsInput: false)
        let controller = MenuBarYieldController(ambient: ambient, workspace: workspace,
            pointer: { point }, buttons: { pressed }, reduceMotion: { true },
            menuIsOpen: { _ in probe.calls += 1; return probe.isOpen }, context: { context })
        controller.start()
        defer { controller.stop() }
        func hidden() -> Bool { ambient.contentView!.layer!.opacity == 0 }
        let originalFrame = ambient.frame
        for _ in 0..<1000 { controller.refresh() }
        try check(probe.calls == 0 && !hidden(), "Ordinary pointer motion must not scan windows or hide the glance")
        point = NSPoint(x: 625, y: 940); controller.refresh()
        try check(hidden() && ambient.ignoresMouseEvents,
                  "Entering the black wing directly from below must shrink it and release native menu clicks")
        point.x = 1090; controller.refresh()
        try check(hidden() && ambient.ignoresMouseEvents,
                  "Entering the surrounding native menu bar must yield drawing and input immediately")
        point.x = 625; controller.refresh()
        try check(hidden() && ambient.ignoresMouseEvents,
                  "Crossing from the menu bar behind a hidden wing must not steal the native click")
        context.workspaceAcceptsInput = true; controller.refresh()
        try check(!workspace.ignoresMouseEvents,
                  "A visible expanded black top must receive input instead of clicking an obscured menu item")
        try check(ambient.contentView!.layer!.animation(forKey: "menu-bar-yield") == nil,
                  "Reduce Motion must skip the compositor animation")
        try check(ambient.frame == originalFrame, "Yield must not change the top geometry")
        let layer = workspace.contentView!.layer!
        let raster = CGContext(data: nil, width: 800, height: 500, bitsPerComponent: 8, bytesPerRow: 800 * 4,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        layer.render(in: raster)
        let pixels = raster.data!.assumingMemoryBound(to: UInt8.self)
        // CALayer's bitmap rows run top-to-bottom, unlike the AppKit path above.
        try check(pixels[(20 * 800 + 400) * 4 + 3] > 240,
                  "An expanded surface must remain opaque at the screen edge during menu yielding, not expose a desktop strip")
        try check(pixels[(200 * 800 + 400) * 4 + 3] > 240,
                  "Actual composed workspace pixels must remain opaque below the menu band")
        try check(workspace.level == .statusBar,
                  "Yielding must not put the expanded black top behind the desktop-backed menu bar")
        point.y = 922; controller.refresh()
        try check(!hidden(), "Leaving the menu band by 1pt must restore in the same event, without a dwell timer")
        try check(probe.calls == 1, "The first exit must check native menus exactly once")
        point = NSPoint(x: 601, y: 925); controller.refresh()
        try check(hidden() && ambient.ignoresMouseEvents,
                  "A clipped empty lower corner must not become an invisible Paul hit target")
        point = NSPoint(x: 625, y: 922); controller.refresh()
        point.y = 940; controller.refresh()
        try check(hidden() && ambient.ignoresMouseEvents,
                  "Direct re-entry must yield again rather than retaining a black-wing exception")
        for x: CGFloat in [625, 737, 850, 1090] {
            point = NSPoint(x: x, y: 922); controller.refresh()
            try check(!hidden() && ambient.ignoresMouseEvents,
                      "Restored docked wings must still pass through a rapid first menu click")
            point.y = 940; controller.refresh()
            try check(hidden() && ambient.ignoresMouseEvents,
                      "Every menu-band entry must yield: left wing, center, right wing and native menu")
        }
        point = NSPoint(x: 1090, y: 940); controller.refresh(); settle(0.8)
        try check(hidden(), "Re-entry must immediately yield again, without a stale restore callback")
        point.y = 800; controller.refresh()
        try check(!hidden() && workspace.contentView!.layer!.mask == nil && !workspace.ignoresMouseEvents,
                  "Leaving must restore the reading and remove the workspace exclusion")
        try check(workspace.level == .statusBar, "Returning must restore the original workspace level")

        point = NSPoint(x: 1090, y: 940); controller.refresh()
        point.y = 800; pressed = 1; controller.refresh(); settle(0.8)
        try check(hidden(), "Dragging or holding a native menu must not restore underneath it")
        pressed = 0; probe.isOpen = true; controller.refresh(); settle(0.85)
        try check(hidden(), "An external native menu must hold the yield after pointer exit")
        let heldProbes = probe.calls
        settle(1.2)
        try check(probe.calls == heldProbes, "An open menu must not start idle window polling")
        controller.refresh()
        let activeProbes = probe.calls
        for _ in 0..<1000 { controller.refresh() }
        try check(probe.calls == activeProbes, "A held external menu must not scan once per mouse move")
        settle(0.2)
        probe.isOpen = false; controller.refresh(); settle(0.85)
        try check(!hidden(), "The next pointer event after an external menu closes must restore")

        point.y = 940; controller.refresh()
        context.enabled = false; controller.refresh()
        try check(!hidden() && !ambient.ignoresMouseEvents && !workspace.ignoresMouseEvents,
                  "Detaching/entering presentation mode must restore floating interaction")
        try check(workspace.contentView!.layer!.mask == nil, "Floating transitions must not retain the top mask")
        context.enabled = true; controller.refresh()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        point.y = 800; controller.refresh(); settle(0.8)
        let sleepProbes = probe.calls
        settle(0.8)
        try check(probe.calls == sleepProbes, "Sleep must cancel all delayed menu probes")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        settle(0.8)
        point.y = 940; controller.refresh()
        point.y = 800; controller.refresh(); controller.stop(); settle(0.8)
        try check(!hidden() && !ambient.ignoresMouseEvents, "Stop must cancel callbacks and clear input suppression")

        // Hand-derived geometry on negative-origin and vertically stacked screens.
        let other = NSRect(x: -1920, y: 1057, width: 1920, height: 23)
        try check(MenuBarYieldController.contains(NSPoint(x: -100, y: 1079), band: other),
                  "A second display must use its own coordinates")
        try check(!MenuBarYieldController.contains(NSPoint(x: 100, y: 1079), band: other),
                  "Another display must not hide this display's notch")
        try check(MenuBarYieldController.isMenuLike(frame: NSRect(x: 900, y: 700, width: 250, height: 223),
                  level: Int(CGWindowLevelForKey(.popUpMenuWindow)), band: context.menuBand), "Native popup must be recognized")
        try check(!MenuBarYieldController.isMenuLike(frame: context.menuBand,
                  level: Int(CGWindowLevelForKey(.mainMenuWindow)), band: context.menuBand), "The permanent menu bar is not a popup")
        print("PASS: immediate exit, rapid re-entry, input, gap-free expanded pixels, bounded menu holds, no idle probes, floating, sleep, stop and display bounds")
    }
}
