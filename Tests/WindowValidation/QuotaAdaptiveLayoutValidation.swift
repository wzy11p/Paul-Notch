import AppKit
import SwiftUI
@testable import PaulNotchCore

/// Real Home and AppKit viewport, with isolated preferences and no account access.
@main struct QuotaAdaptiveLayoutValidation {
    @MainActor static func main() {
        precondition(AppEnvironment.isPreview)
        var failures: [String] = []
        func check(_ value: @autoclosure () -> Bool, _ name: String) {
            if !value() { failures.append(name); print("FAIL: \(name)") }
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer {
            delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            app.windows.forEach { $0.orderOut(nil) }
        }
        settle(0.4)
        let panel = app.windows.first { $0 is IslandPanel }!
        let host = (panel.contentView as! WorkspacePanelContainer).workspace as! NSHostingView<IslandView>
        let shelf = app.windows.first { $0 is AmbientPanel }!.contentView as! NSHostingView<AmbientNotchView>
        host.rootView.onCloseWorkspace(); settle(0.6)
        shelf.rootView.onOpen(); settle(0.6)
        let initial = panel.frame
        func scroll() -> QuotaGridScrollView? { descendants(host).compactMap { $0 as? QuotaGridScrollView }.first }
        func fits(_ grid: QuotaGridDocumentView) -> Bool {
            grid.buttons.allSatisfy { grid.visibleRect.insetBy(dx: -0.5, dy: -0.5).contains($0.frame) }
        }
        check(scroll()?.grid.accounts.count == 8, "Default starts with all eight genuine catalog identities")
        check(scroll().map { fits($0.grid) } == true, "Eight default cards fit without clipping the final row")
        check(scroll()?.hasVerticalScroller == false, "A scrollbar must not cover quota cards")
        check(scroll().map { $0.verticalScrollElasticity == .none } == true, "A full-fit Home must not wobble under the wheel")
        func remove(_ id: String) {
            guard let card = scroll()?.grid.buttons.first(where: { $0.account.id == id }),
                  let item = card.menu?.items.first(where: { $0.identifier?.rawValue == "quota-remove-account" }),
                  let action = item.action else { check(false, "Reachable removal for \(id)"); return }
            NSApp.sendAction(action, to: item.target, from: item)
            settle(0.15)
        }
        remove("minimax-audio")
        check(scroll().map { fits($0.grid) } == true, "Seven cards still fit when Undo adds a footer row")
        for id in ["cursor", "grok", "doubao", "deepseek", "minimax-api"] { remove(id) }
        check(Set(scroll()?.grid.accounts.map(\.id) ?? []) == ["codex", "muse"], "Adaptive layout preserves remaining identities")
        check(panel.frame.width < initial.width && panel.frame.height < initial.height,
              "A two-card Home contracts instead of retaining an empty eight-card shell")
        check(scroll().map { fits($0.grid) } == true, "The sparse layout keeps both cards completely visible")
        let single = panel.frame
        let originalInset = host.rootView.panelMetrics.topInset
        if let grip = descendants(host).first(where: { $0.accessibilityIdentifier() == "workspace-move-handle" }) {
            let begin = panel.convertPoint(toScreen: grip.convert(NSPoint(x: grip.bounds.midX, y: grip.bounds.midY), to: nil))
            let end = NSPoint(x: begin.x + 200, y: begin.y - 180)
            for (type, point) in [(NSEvent.EventType.leftMouseDown, begin), (.leftMouseDragged, end), (.leftMouseUp, end)] {
                let event = NSEvent.mouseEvent(with: type, location: panel.convertPoint(fromScreen: point), modifierFlags: [],
                    timestamp: 1, windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
                if type == .leftMouseDown { grip.mouseDown(with: event) }
                else if type == .leftMouseDragged { grip.mouseDragged(with: event) }
                else { grip.mouseUp(with: event) }
            }
            settle(0.1)
            check(panel.frame.width == single.width && abs(panel.frame.height - single.height + originalInset) < 0.5,
                  "Moving a sparse automatic Home preserves its width and usable height")
            host.rootView.onGeometryReset(); settle(0.1)
        } else { check(false, "Sparse Home still has a reachable move grip") }
        host.rootView.navigation.showQuotaConnections(selectedProvider: "muse"); settle(0.2)
        let connection = panel.frame
        check(connection.width >= 740 && connection.height > single.height,
              "Setup keeps its independent larger viewport")
        host.rootView.navigation.closeQuotaConnections(); settle(0.15)
        let manual = NSRect(x: panel.frame.minX, y: panel.frame.maxY - 350, width: 500, height: 350)
        panel.setFrame(manual, display: true)
        host.rootView.onGeometryCommit(manual, panel.screen!); settle(0.1)
        remove("muse")
        check(panel.frame == manual, "Explicit manual resizing overrides auto fit")
        host.rootView.onCloseWorkspace(); settle(0.6)
        shelf.rootView.onOpen(); settle(0.6)
        check(panel.frame == manual, "Manual size survives collapse and reopen")
        host.rootView.onGeometryReset(); settle(0.15)
        check(panel.frame.width < manual.width && scroll().map { fits($0.grid) } == true,
              "Reset returns to a count-aware default instead of a fixed large panel")
        let cold = WorkspacePanelGeometry(defaults: AppEnvironment.defaults)
        check(cold.frame(navigation: host.rootView.navigation,
                         topInset: host.rootView.panelMetrics.topInset, screen: panel.screen!.frame) == panel.frame,
              "Cold geometry restores the automatic mode and bounded position")
        check(app.windows.filter { $0 is IslandPanel }.count == 1,
              "Adaptation never creates another workspace window")
        // Render the actual native grid for count/screen combinations, not just size arithmetic.
        let wide = CGSize(width: 1440, height: 900)
        for count in [0, 1, 4, 8, 12, 30, 40] {
            let accounts = (0..<count).map { index in QuotaOverviewAccount(id: "fixture-\(index)",
                name: "服务 \(index)", account: "离线示例", group: .membership, value: .percent(65),
                timing: "6 天后重置", status: .sample) }
            let size = QuotaHomeLayout(accountCount: count).size(topInset: 38, screen: wide)
            let surface = NSHostingView(rootView: QuotaOverviewView(accounts: accounts, onClose: {}, mode: .notch)
                .padding(.top, 54))
            surface.sizingOptions = []
            let fixture = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
                styleMask: [.borderless], backing: .buffered, defer: false)
            fixture.isReleasedWhenClosed = false; fixture.alphaValue = 0; fixture.contentView = surface
            fixture.orderBack(nil); settle(0.15)
            let viewport = descendants(surface).compactMap { $0 as? QuotaGridScrollView }.first
            check(size.width <= 1416 && size.height <= 888, "\(count) accounts stay within the available display")
            if count > 0 {
                check(viewport?.grid.buttons.count == count && viewport.map { fits($0.grid) } == true,
                      "\(count) default cards are all physically visible without scrolling")
                check(viewport?.hasVerticalScroller == false, "\(count) cards have no visible scroller")
            } else { check(viewport == nil, "Zero cards uses recovery, not an empty scroller") }
            if let bitmap = surface.bitmapImageRepForCachingDisplay(in: surface.bounds),
               let root = ProcessInfo.processInfo.environment["PAUL_PREVIEW_DIRECTORY"] {
                surface.cacheDisplay(in: surface.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(
                    to: URL(fileURLWithPath: root).appendingPathComponent("adaptive-\(count).png"))
            }
            fixture.orderOut(nil)
        }
        let small = QuotaHomeLayout(accountCount: 40).size(topInset: 32, screen: CGSize(width: 440, height: 300))
        check(small.width <= 416 && small.height <= 288, "Screen-limited fallback never makes the window unbounded")
        let narrow = QuotaGridScrollView()
        narrow.frame = NSRect(x: 0, y: 0, width: 492, height: 248)
        let sample = (0..<8).map { QuotaOverviewAccount(id: "narrow-\($0)", name: "服务", account: "示例",
            group: .membership, value: .percent(65), timing: "6 天后重置", status: .sample) }
        narrow.grid.configure(accounts: sample, pinnedID: nil, enabled: true)
        narrow.layoutSubtreeIfNeeded()
        check(fits(narrow.grid), "A few points of manual width change must not push an entire row below the viewport")
        guard failures.isEmpty else { exit(1) }
        print("PASS: real Home full visibility, adaptive counts/Undo, manual override/reset and independent setup")
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor static func settle(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
}
