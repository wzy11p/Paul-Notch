import AppKit
import SwiftUI

/// Synthetic native control validation only. No application stores or preference suites are initialized.
@MainActor
private final class TabStripFixture {
    let window: NSWindow
    let scroll = TabStripScrollView()
    var selections: [String] = []
    var commits: [[String]] = []
    var strip: TabStripDocumentView { scroll.strip }

    init(items: [ReorderableTabItem], compact: Bool = false, width: CGFloat = 680) {
        window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: 44),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll // This is a test host, never a second app or a user's data surface.
        window.alphaValue = 0
        window.orderBack(nil) // Allow AppKit's real local event routing without a visible/active window.
        scroll.frame = NSRect(x: 0, y: 0, width: width, height: 44)
        strip.onSelect = { [weak self] in self?.selections.append($0) }
        strip.onReorder = { [weak self] in self?.commits.append($0) }
        reset(items: items, compact: compact)
    }

    func reset(items: [ReorderableTabItem]? = nil, compact: Bool = false) {
        strip.cancelTracking()
        selections = []
        commits = []
        scroll.contentView.scroll(to: .zero)
        strip.configure(items: items ?? strip.items, selectedID: (items ?? strip.items).first?.id ?? "", compact: compact)
        scroll.layoutSubtreeIfNeeded()
        strip.resizeToViewport(scroll.contentSize.width)
    }

    func button(_ id: String) -> TabStripButton {
        strip.buttons.first { $0.item.id == id }!
    }

    func center(_ id: String) -> NSPoint {
        let frame = button(id).frame
        return NSPoint(x: frame.midX, y: frame.midY)
    }

    func begin(_ id: String) { strip.beginTracking(id: id, point: center(id)) }

    func mouse(_ type: NSEvent.EventType, point: NSPoint, number: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: strip.convert(point, to: nil),
                          modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                          windowNumber: window.windowNumber, context: nil,
                          eventNumber: number, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    }

    func key(_ code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, characters: characters, charactersIgnoringModifiers: characters,
                        isARepeat: false, keyCode: code)!
    }
}

private struct TabStripRenderSurface: View {
    let modules: [ReorderableTabItem]
    let categories: [ReorderableTabItem]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ReorderableTabStrip(items: modules, selectedID: "tasks", onSelect: { _ in }, onReorder: { _ in })
                .frame(height: 44)
            Divider().overlay(Color.white.opacity(0.1))
            ReorderableTabStrip(items: categories, selectedID: "work", compact: true,
                                onSelect: { _ in }, onReorder: { _ in })
                .frame(height: 44)
        }
        .padding(18)
        .frame(width: 620)
        .background(Color.black)
        .preferredColorScheme(.dark)
    }
}

@main
struct TabStripValidation {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        var failures: [String] = []
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ description: String) {
            count += 1
            if !condition() { failures.append(description); print("FAIL: \(description)") }
        }

        let modules: [ReorderableTabItem] = [
            .init(id: "home", title: "首页", symbol: "house"),
            .init(id: "tasks", title: "待办事项", symbol: "checklist"),
            .init(id: "notes", title: "随笔记", symbol: "square.and.pencil"),
            .init(id: "music", title: "音乐", symbol: "music.note"),
            .init(id: "links", title: "链接收藏", symbol: "link")
        ]
        let categories: [ReorderableTabItem] = [
            .init(id: "all", title: "全部分类", movable: false),
            .init(id: "work", title: "工作"), .init(id: "life", title: "生活"),
            .init(id: "study", title: "学习"), .init(id: "other", title: "其他")
        ]
        let fixture = TabStripFixture(items: modules)
        let original = modules.map(\.id)
        check(fixture.window.alphaValue == 0 && !fixture.window.isKeyWindow,
              "The native event host is transparent and never takes keyboard focus")

        // Small pointer jitter remains one click; a meaningful drag never invokes selection.
        let start = fixture.center("tasks")
        fixture.begin("tasks")
        fixture.strip.track(point: NSPoint(x: start.x + 3, y: start.y + 2))
        check(!fixture.strip.dragging, "Small pointer jitter must remain a click")
        check(fixture.commits.isEmpty && fixture.selections.isEmpty, "Mouse-down must not select or persist")
        fixture.strip.finishTracking(point: NSPoint(x: start.x + 3, y: start.y + 2))
        check(fixture.selections == ["tasks"] && fixture.commits.isEmpty, "Small-motion mouse-up selects once")
        fixture.strip.finishTracking(point: start)
        check(fixture.selections.count == 1, "Repeated mouse-up cannot select twice")

        fixture.reset()
        fixture.begin("tasks")
        let thresholdStart = fixture.center("tasks")
        fixture.strip.track(point: NSPoint(x: thresholdStart.x + 8, y: thresholdStart.y))
        check(fixture.strip.dragging && fixture.strip.candidateIDs == original,
              "Crossing the drag threshold without crossing a neighbor center does not change order")
        fixture.strip.finishTracking(point: NSPoint(x: thresholdStart.x + 8, y: thresholdStart.y))
        check(fixture.selections.isEmpty && fixture.commits.isEmpty, "A same-position drag does not persist or click")

        fixture.reset()
        fixture.begin("home")
        let tail = NSPoint(x: fixture.strip.visibleRect.maxX - 2, y: 22)
        fixture.strip.track(point: tail)
        check(fixture.strip.dragging, "Horizontal movement enters drag state")
        check(fixture.strip.candidateIDs == ["tasks", "notes", "music", "links", "home"], "A drag can cross all items into the tail")
        check(fixture.commits.isEmpty && fixture.selections.isEmpty, "Dragging updates only an in-memory candidate")
        fixture.strip.track(point: tail)
        check(fixture.commits.isEmpty, "Repeated drag events do not persist")
        fixture.strip.finishTracking(point: tail)
        check(fixture.commits == [["tasks", "notes", "music", "links", "home"]], "Mouse-up commits the tail order exactly once")
        check(fixture.selections.isEmpty, "A completed drag never also clicks")
        fixture.strip.finishTracking(point: tail)
        check(fixture.commits.count == 1, "Repeated release cannot commit twice")
        check(!fixture.strip.dragging && fixture.strip.candidateIDs == original, "Release clears transient tracking")

        fixture.reset()
        fixture.begin("home")
        let fastStart = fixture.center("home")
        fixture.strip.track(point: NSPoint(x: fastStart.x + 8, y: 22))
        fixture.strip.finishTracking(point: tail)
        check(fixture.commits == [["tasks", "notes", "music", "links", "home"]],
              "A fast release uses its final position beyond the last drag event")

        fixture.reset()
        fixture.begin("links")
        let head = NSPoint(x: 2, y: 22)
        fixture.strip.track(point: head)
        check(fixture.strip.candidateIDs == ["links", "home", "tasks", "notes", "music"], "Dragging left crosses multiple items into the first position")
        fixture.strip.finishTracking(point: head)
        check(fixture.commits == [["links", "home", "tasks", "notes", "music"]], "Leftward order commits once")

        fixture.reset()
        fixture.begin("home")
        fixture.strip.track(point: tail)
        fixture.strip.finishTracking(point: NSPoint(x: tail.x, y: 70))
        check(fixture.commits.isEmpty && fixture.selections.isEmpty && fixture.strip.candidateIDs == original,
              "Release outside the row cancels without selecting or persisting")
        fixture.begin("home")
        fixture.strip.track(point: NSPoint(x: start.x, y: 22))
        fixture.strip.finishTracking(point: NSPoint(x: fixture.strip.visibleRect.maxX + 20, y: 22))
        check(fixture.commits.isEmpty && fixture.selections.isEmpty, "Horizontal out-of-viewport release cancels")

        fixture.reset()
        fixture.begin("notes")
        let noteCenter = fixture.center("notes")
        fixture.strip.track(point: NSPoint(x: noteCenter.x, y: 40))
        fixture.strip.finishTracking(point: NSPoint(x: noteCenter.x, y: 40))
        check(fixture.selections.isEmpty, "Vertical movement above the threshold cannot accidentally click")

        fixture.reset()
        fixture.begin("home")
        fixture.strip.track(point: tail)
        fixture.window.makeFirstResponder(fixture.button("home"))
        fixture.window.sendEvent(fixture.key(53, characters: "\u{1b}"))
        check(!fixture.strip.dragging && fixture.strip.candidateIDs == original, "Locally dispatched Escape cancels drag state")
        fixture.strip.finishTracking(point: tail)
        check(fixture.commits.isEmpty && fixture.selections.isEmpty, "Escape suppresses the following mouse-up")
        fixture.strip.track(point: tail)
        fixture.strip.finishTracking(point: tail)
        check(!fixture.strip.dragging && fixture.commits.isEmpty, "Cancelled tracking cannot resume from stale mouse-drag or mouse-up events")
        fixture.begin("home")
        fixture.strip.track(point: tail)
        fixture.strip.finishTracking(point: tail)
        check(fixture.commits.count == 1, "A fresh mouse-down can drag normally after Escape")

        fixture.reset()
        fixture.begin("home")
        fixture.strip.track(point: tail)
        fixture.window.setContentSize(NSSize(width: 540, height: 44))
        fixture.scroll.layoutSubtreeIfNeeded()
        check(!fixture.strip.dragging && fixture.strip.candidateIDs == original, "Actual window resize cancels tracking")
        fixture.strip.finishTracking(point: NSPoint(x: 400, y: 22))
        check(fixture.commits.isEmpty && fixture.selections.isEmpty, "Mouse-up after resize cannot commit stale geometry")

        fixture.reset()
        fixture.begin("home")
        fixture.strip.track(point: NSPoint(x: 400, y: 22))
        let changed = modules.filter { $0.id != "music" }
        fixture.strip.configure(items: changed, selectedID: "home", compact: false)
        check(!fixture.strip.dragging && fixture.strip.candidateIDs == changed.map(\.id), "Source member removal cancels drag")
        fixture.strip.finishTracking(point: NSPoint(x: 400, y: 22))
        check(fixture.commits.isEmpty && fixture.selections.isEmpty, "Changed membership rejects stale mouse-up")

        fixture.reset(items: modules)
        fixture.begin("home")
        fixture.strip.track(point: NSPoint(x: 400, y: 22))
        fixture.strip.configure(items: modules, selectedID: "notes", compact: false)
        check(fixture.strip.dragging, "Selection-only refresh does not destroy the active drag")
        fixture.strip.cancelTracking()
        check(fixture.commits.isEmpty && fixture.strip.candidateIDs == original, "Explicit cancellation restores the source order")

        // Test native hit rectangles and NSEvent routing, including otherwise blank capsule margins.
        fixture.reset(items: modules)
        for button in fixture.strip.buttons {
            check(button.frame.height == 44, "\(button.item.id) retains a 44-point-high target")
            for local in [NSPoint(x: 1, y: 1), NSPoint(x: button.frame.width - 1, y: 43)] {
                let location = button.convert(local, to: fixture.scroll)
                check(fixture.scroll.hitTest(location) === button, "\(button.item.id) blank target corner participates in native hit testing")
            }
        }
        for id in ["home", "notes", "links"] {
            fixture.reset()
            let button = fixture.button(id)
            let point = NSPoint(x: button.frame.maxX - 1, y: 43)
            fixture.window.sendEvent(fixture.mouse(.leftMouseDown, point: point))
            fixture.window.sendEvent(fixture.mouse(.leftMouseUp, point: point))
            check(fixture.selections == [id] && fixture.commits.isEmpty, "Local NSEvent mouse routing clicks the full \(id) target")
        }

        fixture.reset()
        let nativeStart = fixture.center("home")
        let nativeTail = NSPoint(x: fixture.strip.visibleRect.maxX - 2, y: 22)
        fixture.window.sendEvent(fixture.mouse(.leftMouseDown, point: nativeStart))
        fixture.window.sendEvent(fixture.mouse(.leftMouseDragged, point: nativeTail))
        check(fixture.strip.dragging && fixture.commits.isEmpty, "Native mouse-drag dispatch tracks without committing")
        fixture.window.sendEvent(fixture.mouse(.leftMouseUp, point: nativeTail))
        check(fixture.commits == [["tasks", "notes", "music", "links", "home"]] && fixture.selections.isEmpty,
              "Native mouse-up dispatch commits one reorder with no click")

        let categoryFixture = TabStripFixture(items: categories, compact: true)
        categoryFixture.begin("other")
        categoryFixture.strip.track(point: NSPoint(x: 1, y: 22))
        check(categoryFixture.strip.candidateIDs == ["all", "other", "work", "life", "study"],
              "Fixed All Categories stays first when a category is dragged ahead of it")
        categoryFixture.strip.finishTracking(point: NSPoint(x: 1, y: 22))
        check(categoryFixture.commits == [["all", "other", "work", "life", "study"]], "Fixed-prefix candidate commits once")
        categoryFixture.reset(compact: true)
        categoryFixture.begin("all")
        categoryFixture.strip.track(point: NSPoint(x: 400, y: 22))
        categoryFixture.strip.finishTracking(point: NSPoint(x: 400, y: 22))
        check(categoryFixture.commits.isEmpty && categoryFixture.selections.isEmpty, "The fixed All Categories control cannot be dragged or misclicked")
        categoryFixture.strip.beginTracking(id: "all", point: NSPoint(x: 2, y: 22))
        categoryFixture.strip.finishTracking(point: NSPoint(x: categoryFixture.button("all").frame.maxX - 2, y: 22))
        check(categoryFixture.commits.isEmpty && categoryFixture.selections.isEmpty,
              "A fast fixed-control release with no intermediate drag cannot misclick")
        categoryFixture.begin("all")
        categoryFixture.strip.finishTracking(point: categoryFixture.center("all"))
        check(categoryFixture.selections == ["all"], "Fixed All Categories remains clickable")

        categoryFixture.reset(compact: true)
        categoryFixture.strip.move(id: "work", by: -1)
        categoryFixture.strip.move(id: "all", by: 1)
        check(categoryFixture.commits.isEmpty, "Keyboard/context movement cannot cross the fixed prefix")
        categoryFixture.window.makeFirstResponder(categoryFixture.button("life"))
        categoryFixture.window.sendEvent(categoryFixture.key(124, characters: "\u{f703}", modifiers: .option))
        check(categoryFixture.commits == [["all", "work", "study", "life", "other"]],
              "Local Option-Right uses the same complete-order callback")
        let focusedCategory = categoryFixture.button("life")
        let reorderedCategories = [categories[0], categories[1], categories[3], categories[2], categories[4]]
        categoryFixture.strip.configure(items: reorderedCategories, selectedID: "life", compact: true)
        check(categoryFixture.button("life") === focusedCategory && categoryFixture.window.firstResponder === focusedCategory,
              "Applying a new order preserves the native button and keyboard focus")
        categoryFixture.window.sendEvent(categoryFixture.key(123, characters: "\u{f702}", modifiers: .option))
        check(categoryFixture.commits.last == categories.map(\.id) && categoryFixture.commits.count == 2,
              "Repeated keyboard reordering still works after applying the prior order")

        let longItems: [ReorderableTabItem] = [
            .init(id: "all", title: "全部分类", movable: false),
            .init(id: "one", title: "一个非常长的分类名称用于验证完整标题显示与横向滚动"),
            .init(id: "two", title: "日常工作与深度学习资料整理"),
            .init(id: "three", title: "最终的分类标签🙂")
        ]
        let longFixture = TabStripFixture(items: longItems, compact: true, width: 340)
        check(longFixture.strip.bounds.width > longFixture.scroll.contentSize.width, "Long titles produce horizontally scrollable content")
        check(longFixture.strip.buttons.allSatisfy { $0.frame.width == $0.tabWidth && $0.frame.height == 44 },
              "Long titles retain intrinsic widths and complete 44-point targets")
        let wideStart = NSPoint(x: longFixture.button("one").frame.minX + 20, y: 22)
        longFixture.strip.beginTracking(id: "one", point: wideStart)
        longFixture.strip.track(point: NSPoint(x: wideStart.x + 2, y: 22))
        longFixture.strip.finishTracking(point: NSPoint(x: wideStart.x + 70, y: 22))
        check(longFixture.selections.isEmpty, "A fast release far from mouse-down cannot click inside a wide title")
        longFixture.strip.beginTracking(id: "one", point: wideStart)
        longFixture.strip.finishTracking(point: NSPoint(x: wideStart.x + 70, y: 22))
        check(longFixture.selections.isEmpty, "A wide-title release without any intermediate drag event cannot click")
        let contentWidth = longFixture.scroll.contentSize.width
        longFixture.scroll.contentView.scroll(to: NSPoint(x: longFixture.strip.bounds.width - contentWidth, y: 0))
        longFixture.scroll.reflectScrolledClipView(longFixture.scroll.contentView)
        check(longFixture.strip.visibleRect.minX > 0, "Native horizontal scrolling reaches the tail")
        check(longFixture.strip.visibleRect.contains(longFixture.center("three")), "The final long-title item is reachable by scrolling")
        let lastPoint = longFixture.center("three")
        longFixture.window.sendEvent(longFixture.mouse(.leftMouseDown, point: lastPoint))
        longFixture.window.sendEvent(longFixture.mouse(.leftMouseUp, point: lastPoint))
        check(longFixture.selections == ["three"], "Native mouse coordinates remain correct after horizontal scrolling")

        let host = NSHostingView(rootView: TabStripRenderSurface(modules: modules, categories: categories))
        let renderWindow = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 620, height: 150),
                                    styleMask: [.borderless], backing: .buffered, defer: false)
        renderWindow.isReleasedWhenClosed = false
        renderWindow.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 620, height: 150)
        host.layoutSubtreeIfNeeded()
        func descendants<T: NSView>(_ view: NSView, as type: T.Type) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, as: type) }
        }
        let hostedStrips = descendants(host, as: TabStripScrollView.self)
        check(hostedStrips.count == 2, "SwiftUI hosts both native tab strips")
        hostedStrips.forEach { $0.layoutSubtreeIfNeeded() }
        func snapshot(_ view: NSView, _ name: String) throws {
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                failures.append("Cannot allocate \(name) snapshot"); return
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                failures.append("Cannot encode \(name) snapshot"); return
            }
            try png.write(to: output.appendingPathComponent(name))
            check(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0 && png.count > 1_000, "\(name) renders nonempty native pixels")
        }
        try snapshot(host, "native-tab-strips.png")
        try snapshot(longFixture.scroll, "native-long-titles-tail.png")
        longFixture.scroll.contentView.scroll(to: .zero)
        try snapshot(longFixture.scroll, "native-long-titles-start.png")
        fixture.reset(items: modules)
        fixture.begin("home")
        fixture.strip.track(point: NSPoint(x: 250, y: 22))
        try snapshot(fixture.scroll, "native-tab-drag.png")
        fixture.strip.cancelTracking()

        for nativeWindow in [fixture.window, categoryFixture.window, longFixture.window, renderWindow] {
            nativeWindow.orderOut(nil)
            nativeWindow.contentView = nil
        }
        print("Synthetic native tab-strip checks: \(count - failures.count)/\(count) passed")
        print("Snapshots: \(output.path)")
        if !failures.isEmpty {
            exit(1)
        }
        print("PASS: no application stores, real preferences, global input, or visible preview launch used")
    }
}
