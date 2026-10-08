import AppKit
import SwiftUI

@main
struct QuotaGridDragValidation {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.finishLaunching()
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 560, height: 285),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        let scroll = QuotaGridScrollView()
        window.contentView = scroll
        window.orderBack(nil)
        let grid = scroll.grid
        let samples = QuotaOverviewFixtures.accounts(count: 7)
        let original = samples.map(\.id)
        var opens: [String] = []
        var commits: [[String]] = []
        var checks = 0
        var failures = 0
        func check(_ value: @autoclosure () -> Bool, _ name: String) {
            checks += 1
            if !value() { failures += 1; print("FAIL: \(name)") }
        }
        func reset(_ accounts: [QuotaOverviewAccount]? = nil) {
            grid.cancelTracking(animated: false)
            grid.configure(accounts: accounts ?? samples, pinnedID: nil, enabled: true)
            scroll.layoutSubtreeIfNeeded()
            grid.resize(to: scroll.contentSize)
            scroll.contentView.scroll(to: .zero)
            opens = []; commits = []
        }
        func center(_ index: Int) -> NSPoint {
            let rect = grid.slot(index)
            return NSPoint(x: rect.midX, y: rect.midY)
        }
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: grid.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        grid.onOpen = { opens.append($0) }
        grid.onReorder = { commits.append($0) }
        reset()
        let start = center(0)
        let target = center(2)
        let button = grid.buttons[0]
        check(button.acceptsFirstMouse(for: event(.leftMouseDown, start)),
              "The first deliberate press in the inactive notch must reach the card, not only activate its window")
        button.mouseDown(with: event(.leftMouseDown, start))
        button.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: start.x + 3, y: start.y + 2)))
        button.mouseUp(with: event(.leftMouseUp, NSPoint(x: start.x + 3, y: start.y + 2)))
        check(opens == ["codex"] && commits.isEmpty, "Small pointer jitter is one click, not a reorder")
        reset()
        button.mouseDown(with: event(.leftMouseDown, start))
        button.mouseDragged(with: event(.leftMouseDragged, target))
        check(grid.dragging, "Native mouse drag starts immediately without an edit mode")
        check(button.frame.midX == target.x && button.frame.midY == target.y, "Dragged card tracks pointer exactly")
        check(grid.candidateIDs == ["kimi", "grok", "codex", "doubao", "deepseek", "minimax-api", "minimax-audio"],
              "Neighbors fill the source gap before drop")
        check(commits.isEmpty && opens.isEmpty, "Dragging does not open details or persist intermediate orders")
        button.mouseUp(with: event(.leftMouseUp, target))
        button.mouseUp(with: event(.leftMouseUp, target))
        check(commits.count == 1 && opens.isEmpty, "Drop commits exactly once; it is never a click")
        let accessibleOrder = (grid.accessibilityChildren() ?? []).compactMap { ($0 as? QuotaGridButton)?.account.id }
        check(accessibleOrder == ["kimi", "grok", "codex", "doubao", "deepseek", "minimax-api", "minimax-audio"],
              "VoiceOver traversal must follow the new visual order, not the lifted card's z-order")

        reset()
        grid.beginTracking(id: "codex", point: start)
        grid.track(point: target)
        grid.finishTracking(point: NSPoint(x: -20, y: target.y))
        check(commits.isEmpty && opens.isEmpty && grid.candidateIDs == original, "Drop outside cancels without data changes")
        reset()
        grid.beginTracking(id: "codex", point: start)
        grid.track(point: target)
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        grid.buttons[0].keyDown(with: escape)
        grid.finishTracking(point: target)
        check(commits.isEmpty && opens.isEmpty && !grid.dragging && grid.candidateIDs == original,
              "Escape cancels; later mouse-up cannot open or commit")
        reset()
        grid.beginTracking(id: "codex", point: start)
        grid.finishTracking(point: target)
        check(commits.count == 1 && opens.isEmpty, "Coalesced mouse-up position determines the drop")

        reset()
        grid.beginTracking(id: "codex", point: start)
        grid.track(point: target)
        var refreshed = samples
        refreshed[0] = .init(id: "codex", name: "Codex", account: "Updated", group: .membership,
                             value: .percent(51), timing: "Updated", status: .sample)
        grid.configure(accounts: refreshed, pinnedID: nil, enabled: true)
        check(grid.dragging && grid.candidateIDs[2] == "codex", "Quota refresh must not reset an in-progress drag")
        grid.finishTracking(point: target)
        check(commits.count == 1 && grid.accounts.first(where: { $0.id == "codex" })?.value == .percent(51),
              "Reorder preserves updated account values")

        reset()
        grid.beginTracking(id: "codex", point: start); grid.track(point: target)
        grid.resize(to: NSSize(width: scroll.contentSize.width + 0.1, height: scroll.contentSize.height))
        check(grid.dragging, "Subpixel hosting-layout jitter must not cancel the held card")
        grid.finishTracking(point: target)
        check(commits.count == 1, "A drop still commits after a subpixel layout update")

        reset()
        grid.beginTracking(id: "codex", point: start); grid.track(point: target)
        grid.resize(to: NSSize(width: scroll.contentSize.width - 80, height: scroll.contentSize.height))
        grid.finishTracking(point: target)
        check(commits.isEmpty && !grid.dragging, "A real user resize cancels the obsolete drop geometry")

        reset()
        grid.beginTracking(id: "codex", point: start); grid.track(point: target)
        grid.configure(accounts: Array(samples.dropLast()), pinnedID: nil, enabled: true)
        grid.finishTracking(point: target)
        check(commits.isEmpty && opens.isEmpty && !grid.dragging, "Membership changes cancel instead of committing stale identities")
        reset()
        grid.beginTracking(id: "codex", point: start); grid.track(point: target)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        grid.finishTracking(point: target)
        check(commits.isEmpty && opens.isEmpty && !grid.dragging, "Losing the window cancels tracking")

        reset(QuotaOverviewFixtures.accounts(count: 30))
        grid.beginTracking(id: "codex", point: center(0))
        let edge = NSPoint(x: center(2).x, y: grid.visibleRect.maxY - 6)
        grid.track(point: edge)
        let before = grid.visibleRect.minY
        grid.autoScroll()
        check(grid.visibleRect.minY > before, "Holding at the visible bottom edge scrolls many-account content")
        grid.cancelTracking()
        let after = grid.visibleRect.minY
        grid.autoScroll()
        check(grid.visibleRect.minY == after, "Cancellation stops autoscroll")
        check(window.frame.height == 285, "Thirty accounts never enlarge the notch window")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 300))
        grid.configure(accounts: samples, pinnedID: nil, enabled: true)
        scroll.layoutSubtreeIfNeeded()
        check(grid.visibleRect.minY == 0, "Filtering a scrolled long list back to seven cards keeps content visible")
        reset()
        grid.move("codex", by: 4)
        check(commits.first == ["kimi", "grok", "doubao", "deepseek", "codex", "minimax-api", "minimax-audio"],
              "Keyboard reorders across rows without opening details")
        window.orderOut(nil)
        guard failures == 0 else { exit(1) }
        print("PASS: \(checks) native card pointer, cancellation, refresh, scrolling and keyboard checks")
    }
}
