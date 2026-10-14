import AppKit
import SwiftUI
@testable import PaulNotchCore

/// Exercises Paul's real mounted panels, not the user's accounts or other apps.
@main struct MenuBarYieldValidation {
    struct Failure: Error { let message: String }
    @MainActor final class MenuObservation: NSObject {
        let menu: NSMenu
        let window: NSWindow
        var hidden = false
        var began = false
        init(menu: NSMenu, window: NSWindow) { self.menu = menu; self.window = window }
        @objc func finish() {
            hidden = window.contentView?.layer?.opacity == 0 && window.ignoresMouseEvents
            menu.cancelTrackingWithoutAnimation()
        }
        @objc func observed(_ note: Notification) {
            if note.name == NSMenu.didBeginTrackingNotification {
                began = true
                hidden = window.contentView?.layer?.opacity == 0 && window.ignoresMouseEvents
            }
        }
    }
    @MainActor static func main() {
        do { try run() }
        catch { print("FAIL: \(error)"); fflush(stdout); exit(1) }
    }
    @MainActor static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(message: message) }
    }
    @MainActor static func settle(_ duration: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(duration))
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
        let shelf = app.windows.first { $0 is AmbientPanel }!
        let workspace = app.windows.first { $0 is IslandPanel }!
        let root = (workspace.contentView as! WorkspacePanelContainer).workspace as! NSHostingView<IslandView>
        let glance = shelf.contentView as! NSHostingView<AmbientNotchView>
        // Test actual AppKit menu tracking on mounted production windows, but
        // isolate external window metadata and physical pointer movement. The
        // computer-use cursor overlay can otherwise look like a held popup.
        let installedController = Mirror(reflecting: delegate).children.first { $0.label == "menuBarYield" }!.value as! MenuBarYieldController?
        installedController?.stop()
        let mountedScreen = shelf.screen!
        let controller = MenuBarYieldController(ambient: shelf, workspace: workspace,
            pointer: { NSPoint(x: mountedScreen.frame.midX, y: mountedScreen.frame.maxY - 200) },
            buttons: { 0 }, menuIsOpen: { _ in false }, context: {
                .init(enabled: true, screenFrame: mountedScreen.frame,
                      menuHeight: max(mountedScreen.safeAreaInsets.top,
                                      mountedScreen.frame.maxY - mountedScreen.visibleFrame.maxY),
                      workspaceAcceptsInput: workspace.isVisible)
            })
        controller.start()
        defer { controller.stop() }
        root.rootView.onCloseWorkspace(); settle(0.4)
        let frame = shelf.frame
        let expandedLevel = workspace.level
        try require(shelf.ignoresMouseEvents,
                    "Docked wings must release native clicks even before the first move event")
        let screen = shelf.screen!
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
           screen.safeAreaInsets.top > 0 {
            let center = NSPoint(x: (left.maxX + right.minX) / 2,
                                 y: screen.frame.maxY - screen.safeAreaInsets.top / 2)
            func observed(_ kind: NSEvent.EventType, at point: NSPoint) {
                let event = NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
                delegate.handleMouseDown(event, at: point)
                settle(0.3)
            }
            for point in [NSPoint(x: left.maxX - 1, y: center.y),
                          NSPoint(x: right.minX + 1, y: center.y),
                          NSPoint(x: center.x, y: screen.frame.maxY - screen.safeAreaInsets.top - 1)] {
                observed(.leftMouseDown, at: point)
                try require(!workspace.isVisible, "Clicks beside or below the real camera gap must never open Paul")
            }
            observed(.mouseMoved, at: center)
            observed(.rightMouseDown, at: center)
            try require(!workspace.isVisible, "Hover and right click in the camera gap must not open Paul")
            observed(.leftMouseDown, at: center)
            try require(workspace.isVisible, "An observed left click inside the physical notch must open the actual workspace")
            try require(shelf.ignoresMouseEvents, "Opening through the physical notch must preserve wing click-through")
            observed(.leftMouseDown, at: center)
            try require(!workspace.isVisible, "A second center click must close the workspace exactly once")
            observed(.leftMouseDown, at: NSPoint(x: center.x, y: screen.frame.maxY))
            try require(workspace.isVisible, "The exact physical screen edge must not be a dead pixel row")
            observed(.leftMouseDown, at: center)
            observed(.leftMouseDown, at: center)
            let localClick = NSEvent.mouseEvent(with: .leftMouseDown,
                location: workspace.convertPoint(fromScreen: center), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: workspace.windowNumber,
                context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
            delegate.handleLocalMouseDown(localClick); settle(0.3)
            try require(!workspace.isVisible,
                        "The opaque expanded top must still toggle closed when the center click reaches its own window")
            observed(.leftMouseDown, at: center)
            let bottomOfCamera = NSPoint(x: center.x, y: screen.frame.maxY - screen.safeAreaInsets.top + 0.5)
            let edgeClick = NSEvent.mouseEvent(with: .leftMouseDown,
                location: workspace.convertPoint(fromScreen: bottomOfCamera), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: workspace.windowNumber,
                context: nil, eventNumber: 3, clickCount: 1, pressure: 0)!
            delegate.handleLocalMouseDown(edgeClick); settle(0.3)
            try require(!workspace.isVisible, "The whole physical camera gap must toggle, including below the shorter compact window")
        } else {
            print("SKIP: this mounted host has no physical camera gap; no invented center click region")
        }
        let menu = NSMenu(title: "Account-free menu fixture")
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        settle(0.2)
        try require((glance.layer?.opacity ?? 1) == 0,
                    "Tracking a native menu must remove the full black wings, not only their text")
        try require(shelf.frame == frame, "Yielding must never move or resize the original top anchor")
        // A deliberate P-menu open must still work while that menu is yielding.
        let statusItem = Mirror(reflecting: delegate).children.first { $0.label == "statusItem" }!.value as! NSStatusItem
        let openItem = statusItem.menu!.items.first!
        try require(app.sendAction(openItem.action!, to: openItem.target, from: openItem),
                    "The real P-menu Open action must remain wired")
        settle(0.4)
        try require(workspace.isVisible, "Opening the workspace while yielding must remain possible")
        try require(workspace.contentView?.layer?.mask == nil && workspace.level == expandedLevel,
                    "Opening from a menu must retain the expanded opaque top, not cut a desktop gap or lower it behind the menu bar")
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        settle(1)
        try require(glance.layer?.opacity == 1, "Closed fixture menu must return to a visible baseline")
        // Exercise genuine AppKit tracking, not just posted notifications. The
        // fixture menu has no commands; a common-mode timer cancels it safely.
        let nativeMenu = NSMenu(title: "Paul menu tracking validation")
        nativeMenu.addItem(withTitle: "只读测试", action: nil, keyEquivalent: "")
        let observation = MenuObservation(menu: nativeMenu, window: shelf)
        NotificationCenter.default.addObserver(observation, selector: #selector(MenuObservation.observed(_:)),
            name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(observation, selector: #selector(MenuObservation.observed(_:)),
            name: NSMenu.didEndTrackingNotification, object: nil)
        let timer = Timer(timeInterval: 0.25, target: observation,
                          selector: #selector(MenuObservation.finish), userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        nativeMenu.popUp(positioning: nil, at: NSPoint(x: 30, y: 30), in: workspace.contentView!)
        timer.invalidate()
        NotificationCenter.default.removeObserver(observation)
        try require(observation.began && observation.hidden,
                    "Genuine AppKit menu tracking must yield while tracking")
        settle(1)
        try require(glance.layer?.opacity == 1, "Actual native menu close must restore the glance")
        print("PASS: physical-notch click/close, docked wing click-through, native-menu hold and gap-free expanded anchor")
    }
}
