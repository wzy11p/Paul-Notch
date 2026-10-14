import AppKit
import SwiftUI
@testable import PaulNotchCore

/// A regression for the detached shelf/chimney and unreachable drop target.
/// Runs the actual panels and mounted input, with an empty isolated workspace.
@main struct TopDockValidation {
    struct Failure: Error { let message: String }
    @MainActor static func main() {
        do { try run() }
        catch { print("FAIL: \(error)"); fflush(stdout); exit(1) }
    }
    @MainActor static func run() throws {
        print("START: actual isolated top/drag regression"); fflush(stdout)
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
        let host = (workspace.contentView as! WorkspacePanelContainer).workspace as! NSHostingView<IslandView>
        let glance = shelf.contentView as! NSHostingView<AmbientNotchView>
        let screen = shelf.screen!
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }
        func checkDock(_ label: String) {
            check(abs(shelf.frame.maxY - screen.frame.maxY) < 0.6,
                  "\(label): the whole readout must touch the screen top, not a bridge below it; \(shelf.frame)")
            check(abs(shelf.frame.midX - screen.frame.midX) < 0.6 && shelf.frame.height <= 32,
                  "\(label): restore the original centered, shallow silhouette")
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                check(glance.rootView.presentation.centerGapWidth >= right.minX - left.maxX,
                      "\(label): no labels may borrow the camera cutout's occluded space")
            }
        }
        host.rootView.onCloseWorkspace(); settle(0.4)
        checkDock("initial")
        glance.rootView.onOpen(); settle(0.4)
        guard let grip = find("workspace-move-handle", in: host) else {
            throw Failure(message: "missing native workspace drag handle")
        }
        drag(grip, window: workspace, to: NSPoint(x: workspace.frame.midX - 210,
             y: workspace.frame.midY - 230))
        host.rootView.onCloseWorkspace(); settle(0.5)
        guard let input = find("floating-quota-handle", in: glance) else {
            throw Failure(message: "missing native detached-orb drag handle")
        }
        // Leave the orb 4pt below the reachable menu edge: users should not have
        // to hit an impossible physical edge or use the separate return button.
        drag(input, window: shelf, to: NSPoint(x: screen.frame.midX - 200,
             y: screen.visibleFrame.maxY - 4 - 46))
        settle(0.7)
        check(QuotaFloatingPlacement(defaults: AppEnvironment.defaults).isFloating,
              "a drop beside the center must remain floating")
        drag(input, window: shelf, to: NSPoint(x: screen.frame.midX,
             y: screen.visibleFrame.maxY - 4 - 46))
        settle(0.7)
        check(!QuotaFloatingPlacement(defaults: AppEnvironment.defaults).isFloating,
              "centered drag/release at the reachable top must dock without clicking Return")
        checkDock("drag arrival")
        glance.rootView.onOpen(); settle(0.4)
        check(abs(workspace.frame.maxY - screen.frame.maxY) < 0.6,
              "expanded workspace must share the exact top attachment, without a second menu-height offset")
        host.rootView.onCloseWorkspace(); settle(0.4)
        checkDock("reopened")
        print("Actual dock frame: \(shelf.frame); screen: \(screen.frame)")
        if !failures.isEmpty {
            failures.forEach { print("FAIL: \($0)") }
            throw Failure(message: failures.joined(separator: "; "))
        }
        print("PASS: top-attached compact silhouette, unobstructed camera gap, reachable native drag, off-center rejection and reopen")
    }
    @MainActor static func find(_ id: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == id { return view }
        return view.subviews.lazy.compactMap { find(id, in: $0) }.first
    }
    @MainActor static func drag(_ view: NSView, window: NSWindow, to center: NSPoint) {
        let origin = window.convertPoint(toScreen: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil))
        let end = NSPoint(x: origin.x + center.x - window.frame.midX,
                          y: origin.y + center.y - window.frame.midY)
        for (kind, point) in [(NSEvent.EventType.leftMouseDown, origin), (.leftMouseDragged, end), (.leftMouseUp, end)] {
            let event = NSEvent.mouseEvent(with: kind, location: window.convertPoint(fromScreen: point),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
            switch kind {
            case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseDragged: view.mouseDragged(with: event)
            default: view.mouseUp(with: event)
            }
        }
    }
    @MainActor static func settle(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}
