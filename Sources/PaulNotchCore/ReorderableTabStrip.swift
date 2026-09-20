import AppKit
import SwiftUI

struct ReorderableTabItem: Equatable {
    let id: String
    let title: String
    var symbol: String? = nil
    var movable = true
}

/// Native pointer tracking separates a click from a drag, without attaching a
/// competing SwiftUI gesture to a Button. Only mouse-up commits an order.
struct ReorderableTabStrip: NSViewRepresentable {
    let items: [ReorderableTabItem]
    let selectedID: String
    var compact = false
    let onSelect: (String) -> Void
    let onReorder: ([String]) -> Void

    func makeNSView(context: Context) -> TabStripScrollView {
        TabStripScrollView()
    }

    func updateNSView(_ view: TabStripScrollView, context: Context) {
        view.strip.onSelect = onSelect
        view.strip.onReorder = onReorder
        view.strip.configure(items: items, selectedID: selectedID, compact: compact)
    }

    static func dismantleNSView(_ view: TabStripScrollView, coordinator: ()) {
        view.strip.cancelTracking()
    }
}

@MainActor
final class TabStripScrollView: NSScrollView {
    let strip = TabStripDocumentView()

    init() {
        super.init(frame: .zero)
        drawsBackground = false
        borderType = .noBorder
        hasHorizontalScroller = true
        hasVerticalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .none
        documentView = strip
        appearance = NSAppearance(named: .darkAqua)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        strip.resizeToViewport(contentSize.width)
    }
}

@MainActor
final class TabStripDocumentView: NSView {
    override var isFlipped: Bool { true }
    private(set) var items: [ReorderableTabItem] = []
    private(set) var buttons: [TabStripButton] = []
    private(set) var candidateIDs: [String] = []
    private(set) var dragging = false
    private var selectedID = ""
    private var compact = false
    private var trackedID: String?
    private var startPoint = NSPoint.zero
    private var grabOffset: CGFloat = 0
    private var pointer = NSPoint.zero
    private var scrollTimer: Timer?
    private var viewportWidth: CGFloat = 0
    var onSelect: (String) -> Void = { _ in }
    var onReorder: ([String]) -> Void = { _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(self, selector: #selector(windowResigned(_:)),
                                               name: NSWindow.didResignKeyNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowResigned(_:)),
                                               name: NSWindow.willCloseNotification, object: nil)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(items next: [ReorderableTabItem], selectedID: String, compact: Bool) {
        if next != items || self.compact != compact {
            cancelTracking()
            items = next
            self.compact = compact
            let previous = buttons
            buttons = next.map { item in
                if let retained = previous.first(where: { $0.item == item && $0.compact == compact }) {
                    return retained
                }
                let button = TabStripButton(item: item, compact: compact)
                button.owner = self
                button.target = self
                button.action = #selector(activate(_:))
                addSubview(button)
                return button
            }
            previous.filter { old in !buttons.contains(where: { $0 === old }) }.forEach { $0.removeFromSuperview() }
            candidateIDs = next.map(\.id)
            resizeToViewport(viewportWidth)
        }
        self.selectedID = selectedID
        for button in buttons {
            button.chosen = button.item.id == selectedID
            button.state = button.chosen ? .on : .off
            button.needsDisplay = true
        }
    }

    func resizeToViewport(_ width: CGFloat) {
        if viewportWidth != width && trackedID != nil { cancelTracking() }
        viewportWidth = width
        setFrameSize(NSSize(width: max(width, buttons.reduce(0) { $0 + $1.tabWidth }), height: 44))
        layoutButtons()
    }

    private func frames(for order: [String]) -> [String: NSRect] {
        var x: CGFloat = 0
        var result: [String: NSRect] = [:]
        for id in order {
            guard let button = buttons.first(where: { $0.item.id == id }) else { continue }
            result[id] = NSRect(x: x, y: 0, width: button.tabWidth, height: 44)
            x += button.tabWidth
        }
        return result
    }

    private func layoutButtons() {
        let slots = frames(for: candidateIDs)
        for button in buttons {
            guard var slot = slots[button.item.id] else { continue }
            if dragging && trackedID == button.item.id {
                slot.origin.x = min(max(0, pointer.x - grabOffset), max(0, bounds.width - slot.width))
            }
            button.frame = slot
            button.lifted = dragging && button.item.id == trackedID
            button.needsDisplay = true
        }
        needsDisplay = true
    }

    @objc private func activate(_ sender: TabStripButton) {
        guard trackedID == nil else { return }
        onSelect(sender.item.id)
    }

    func beginTracking(id: String, point: NSPoint) {
        cancelTracking()
        guard let button = buttons.first(where: { $0.item.id == id }) else { return }
        trackedID = id
        startPoint = point
        pointer = point
        grabOffset = point.x - button.frame.minX
    }

    func track(point: NSPoint) {
        guard let id = trackedID,
              let item = items.first(where: { $0.id == id }) else { return }
        pointer = point
        // A predominantly vertical gesture is never treated as a tab click.
        if !dragging && hypot(point.x - startPoint.x, point.y - startPoint.y) >= 7 {
            guard item.movable else { cancelTracking(); return }
            dragging = true
            if let button = buttons.first(where: { $0.item.id == id }) {
                addSubview(button, positioned: .above, relativeTo: nil)
            }
            scrollTimer = Timer(timeInterval: 1.0 / 30, target: self,
                                selector: #selector(autoScroll), userInfo: nil, repeats: true)
            if let scrollTimer { RunLoop.main.add(scrollTimer, forMode: .common) }
        }
        guard dragging else { return }
        let remaining = items.filter { $0.id != id }
        // Compare against the frozen pre-drag slots. Closing the source gap
        // before measuring would make a wide tab jump on its first 7pt move.
        let originalFrames = frames(for: items.map(\.id))
        let sourceWidth = buttons.first { $0.item.id == id }?.tabWidth ?? 0
        let center = point.x - grabOffset + sourceWidth / 2
        var insertion = remaining.firstIndex { center < (originalFrames[$0.id]?.midX ?? 0) } ?? remaining.count
        // Fixed controls (currently All Categories) stay at the start.
        let fixedPrefix = remaining.prefix(while: { !$0.movable }).count
        insertion = max(fixedPrefix, insertion)
        candidateIDs = remaining.map(\.id)
        candidateIDs.insert(id, at: insertion)
        layoutButtons()
    }

    func finishTracking(point: NSPoint) {
        // Mouse events can be coalesced; the release position is authoritative.
        track(point: point)
        guard let id = trackedID else { return }
        let wasDragging = dragging
        let order = candidateIDs
        let visible = visibleRect
        let inside = visible.insetBy(dx: 0, dy: -8).contains(point)
        let clickInside = buttons.first(where: { $0.item.id == id })?.frame.contains(point) == true
        cancelTracking()
        if wasDragging {
            if inside && order != items.map(\.id) { onReorder(order) }
        } else if inside && clickInside {
            onSelect(id)
        }
    }

    func cancelTracking() {
        scrollTimer?.invalidate()
        scrollTimer = nil
        trackedID = nil
        dragging = false
        candidateIDs = items.map(\.id)
        layoutButtons()
    }

    func move(id: String, by delta: Int) {
        cancelTracking()
        var order = items.map(\.id)
        guard let from = order.firstIndex(of: id), items[from].movable else { return }
        let to = from + delta
        guard items.indices.contains(to), items[to].movable else { return }
        order.swapAt(from, to)
        onReorder(order)
    }

    @objc private func autoScroll() {
        guard dragging, let scroll = enclosingScrollView, let window else {
            cancelTracking(); return
        }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let visible = visibleRect
        guard point.y >= -8 && point.y <= 52 else { return }
        let direction: CGFloat = point.x < visible.minX + 22 ? -1 : (point.x > visible.maxX - 22 ? 1 : 0)
        guard direction != 0 else { return }
        let x = min(max(0, visible.minX + direction * 9), max(0, bounds.width - visible.width))
        guard x != visible.minX else { return }
        scroll.contentView.scroll(to: NSPoint(x: x, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        track(point: convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    @objc private func windowResigned(_ notification: Notification) {
        if notification.object as? NSWindow === window { cancelTracking() }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { cancelTracking() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if dragging, let id = trackedID, let slot = frames(for: candidateIDs)[id] {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: slot.minX + 2, y: 10, width: 2, height: 24),
                         xRadius: 1, yRadius: 1).fill()
        }
    }
}

@MainActor
final class TabStripButton: NSButton {
    let item: ReorderableTabItem
    let compact: Bool
    weak var owner: TabStripDocumentView?
    var chosen = false
    var lifted = false
    private var hovering = false
    private var hoverArea: NSTrackingArea?
    private let normalSymbol: NSImage?
    private let activeSymbol: NSImage?
    var tabWidth: CGFloat {
        ceil((item.title as NSString).size(withAttributes: [.font: font!]).width)
            + 28 + (item.symbol == nil ? 0 : 19)
    }

    init(item: ReorderableTabItem, compact: Bool) {
        self.item = item
        self.compact = compact
        normalSymbol = Self.symbol(item.symbol, white: 0.66)
        activeSymbol = Self.symbol(item.symbol, white: 0.96)
        super.init(frame: .zero)
        title = item.title
        font = .systemFont(ofSize: compact ? 12 : 13, weight: compact ? .medium : .regular)
        isBordered = false
        focusRingType = .none
        setAccessibilityLabel(item.title)
        setAccessibilityRole(.radioButton)
        toolTip = item.movable ? "拖动调整顺序；也可右键或按 Option + 左右方向键移动" : item.title
        if item.movable {
            let menu = NSMenu()
            let left = menu.addItem(withTitle: "向左移动", action: #selector(moveTabLeft), keyEquivalent: "")
            let right = menu.addItem(withTitle: "向右移动", action: #selector(moveTabRight), keyEquivalent: "")
            left.target = self
            right.target = self
            self.menu = menu
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if let owner { owner.beginTracking(id: item.id, point: owner.convert(event.locationInWindow, from: nil)) }
    }
    override func mouseDragged(with event: NSEvent) {
        if let owner { owner.track(point: owner.convert(event.locationInWindow, from: nil)) }
    }
    override func mouseUp(with event: NSEvent) {
        if let owner { owner.finishTracking(point: owner.convert(event.locationInWindow, from: nil)) }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { owner?.cancelTracking(); return }
        if event.modifierFlags.contains(.option), event.keyCode == 123 || event.keyCode == 124 {
            owner?.move(id: item.id, by: event.keyCode == 123 ? -1 : 1)
            return
        }
        super.keyDown(with: event)
    }
    @objc private func moveTabLeft() { owner?.move(id: item.id, by: -1) }
    @objc private func moveTabRight() { owner?.move(id: item.id, by: 1) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let pill = bounds.insetBy(dx: compact ? 3 : 1, dy: compact ? 5 : 2)
        if chosen || hovering || lifted {
            NSColor(white: lifted ? 0.23 : (chosen ? 0.13 : 0.09), alpha: 1).setFill()
            NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        }
        if window?.firstResponder === self && NSApp.isFullKeyboardAccessEnabled {
            NSColor.controlAccentColor.setStroke()
            let ring = NSBezierPath(roundedRect: pill.insetBy(dx: 1, dy: 1), xRadius: 16, yRadius: 16)
            ring.lineWidth = 1
            ring.stroke()
        }
        let color = NSColor(white: chosen || lifted ? 0.96 : 0.66, alpha: 1)
        var x: CGFloat = 14
        if let image = chosen || lifted ? activeSymbol : normalSymbol {
            image.draw(in: NSRect(x: x, y: (44 - image.size.height) / 2,
                                  width: image.size.width, height: image.size.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += 19
        }
        let text = item.title as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: font!, .foregroundColor: color]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: x, y: (44 - size.height) / 2), withAttributes: attributes)
    }

    private static func symbol(_ name: String?, white: CGFloat) -> NSImage? {
        guard let name, let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular)) else { return nil }
        let tinted = NSImage(size: image.size)
        tinted.lockFocus()
        image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        NSColor(white: white, alpha: 1).set()
        NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        return tinted
    }
}
