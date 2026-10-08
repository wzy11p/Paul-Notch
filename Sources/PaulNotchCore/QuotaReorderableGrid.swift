import AppKit
import SwiftUI

/// One native tracking surface: click opens; movement picks up the very same card.
/// No pasteboard drag, long-press mode, or competing Button/DragGesture recognizers.
struct QuotaReorderableGrid: NSViewRepresentable {
    let accounts: [QuotaOverviewAccount]
    let pinnedID: String?
    var enabled = true
    let onOpen: (String) -> Void
    let onReorder: ([String]) -> Void

    func makeNSView(context: Context) -> QuotaGridScrollView { QuotaGridScrollView() }
    func updateNSView(_ view: QuotaGridScrollView, context: Context) {
        view.grid.onOpen = onOpen
        view.grid.onReorder = onReorder
        view.grid.configure(accounts: accounts, pinnedID: pinnedID, enabled: enabled)
    }
    static func dismantleNSView(_ view: QuotaGridScrollView, coordinator: ()) {
        view.grid.cancelTracking()
    }
}

@MainActor
final class QuotaGridScrollView: NSScrollView {
    let grid = QuotaGridDocumentView()
    init() {
        super.init(frame: .zero)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .none
        documentView = grid
        appearance = NSAppearance(named: .darkAqua)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        grid.resize(to: contentSize)
    }
}

@MainActor
final class QuotaGridDocumentView: NSView {
    override var isFlipped: Bool { true }
    private(set) var accounts: [QuotaOverviewAccount] = []
    private(set) var buttons: [QuotaGridButton] = []
    private(set) var candidateIDs: [String] = []
    private(set) var dragging = false
    var onOpen: (String) -> Void = { _ in }
    var onReorder: ([String]) -> Void = { _ in }
    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var viewport = NSSize.zero
    private var enabled = true
    private var trackedID: String?
    private var start = NSPoint.zero
    private var pointer = NSPoint.zero
    private var windowPointer = NSPoint.zero
    private var grabOffset = NSPoint.zero
    private var scrollTimer: Timer?
    private var cursorPushed = false
    private var accessibleOrder: [String] = []
    private var focusToRestore: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        NotificationCenter.default.addObserver(self, selector: #selector(windowLost(_:)),
                                               name: NSWindow.didResignKeyNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowLost(_:)),
                                               name: NSWindow.willCloseNotification, object: nil)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(accounts next: [QuotaOverviewAccount], pinnedID: String?, enabled: Bool) {
        let wasEnabled = self.enabled
        if wasEnabled && !enabled, let card = window?.firstResponder as? QuotaGridButton, card.owner === self {
            focusToRestore = card.account.id
            window?.makeFirstResponder(nil)
        }
        self.enabled = enabled
        setAccessibilityHidden(!enabled)
        if !enabled || next.map(\.id) != accounts.map(\.id) { cancelTracking() }
        let previous = Dictionary(uniqueKeysWithValues: buttons.map { ($0.account.id, $0) })
        let changedMembership = next.map(\.id) != accounts.map(\.id)
        accounts = next
        buttons = next.map { account in
            let button = previous[account.id] ?? QuotaGridButton(account: account)
            button.owner = self
            button.isEnabled = enabled
            button.update(account: account, pinned: account.id == pinnedID)
            if button.superview == nil { addSubview(button) }
            return button
        }
        previous.values.filter { old in !buttons.contains(where: { $0 === old }) }.forEach { $0.removeFromSuperview() }
        if changedMembership || trackedID == nil { candidateIDs = next.map(\.id) }
        resize(to: viewport)
        if !wasEnabled && enabled {
            if let id = focusToRestore, let button = buttons.first(where: { $0.account.id == id }) {
                window?.makeFirstResponder(button)
            }
            focusToRestore = nil
        }
    }

    func resize(to size: NSSize) {
        // Hosting layout can report fractional rounding changes during press
        // feedback. Keep the gesture's exact slots until a real resize occurs.
        if trackedID != nil, abs(viewport.width - size.width) <= 1,
           abs(viewport.height - size.height) <= 1 { return }
        let changed = viewport != size
        if changed { cancelTracking() }
        viewport = size
        let layout = QuotaBentoLayout(width: size.width, accountCount: accounts.count)
        let rows = (accounts.count + layout.columns - 1) / layout.columns
        let height = Double(rows) * (layout.cardWidth + layout.spacing) - (rows == 0 ? 0 : layout.spacing) + 4
        setFrameSize(NSSize(width: size.width, height: max(size.height, height)))
        layoutCards(animated: false)
    }

    func slot(_ index: Int) -> NSRect {
        let layout = QuotaBentoLayout(width: viewport.width, accountCount: accounts.count)
        let pitch = layout.cardWidth + layout.spacing
        return NSRect(x: layout.leadingInset + Double(index % layout.columns) * pitch, y: Double(index / layout.columns) * pitch + 2,
                      width: layout.cardWidth, height: layout.cardWidth)
    }

    private func layoutCards(animated: Bool) {
        for (index, id) in candidateIDs.enumerated() {
            guard let button = buttons.first(where: { $0.account.id == id }) else { continue }
            var frame = slot(index)
            if dragging && trackedID == id {
                frame.origin = NSPoint(x: pointer.x - grabOffset.x, y: pointer.y - grabOffset.y)
                button.layer?.removeAllAnimations()
                button.frame = frame // Pointer tracking has no easing or delayed catch-up.
            } else if button.frame != frame {
                if animated && !reduceMotion {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.2
                        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                        button.animator().frame = frame
                    }
                } else {
                    button.layer?.removeAllAnimations()
                    button.frame = frame
                }
            }
        }
        if accessibleOrder != candidateIDs {
            // The lifted card is last in z-order, but assistive navigation follows its slot.
            let ordered = candidateIDs.compactMap { id in buttons.first { $0.account.id == id } }
            setAccessibilityChildren(ordered)
            accessibleOrder = candidateIDs
        }
        needsDisplay = true
    }

    func beginTracking(id: String, point: NSPoint) {
        cancelTracking()
        guard enabled, let button = buttons.first(where: { $0.account.id == id }) else { return }
        trackedID = id
        start = point
        pointer = point
        windowPointer = convert(point, to: nil)
        grabOffset = NSPoint(x: point.x - button.frame.minX, y: point.y - button.frame.minY)
        button.setInteraction(pressed: true, lifted: false)
    }

    func track(point: NSPoint) {
        guard let id = trackedID else { return }
        pointer = point
        windowPointer = convert(point, to: nil)
        if !dragging && hypot(point.x - start.x, point.y - start.y) >= 7 {
            dragging = true
            if let button = buttons.first(where: { $0.account.id == id }) {
                addSubview(button, positioned: .above, relativeTo: nil)
                button.setInteraction(pressed: false, lifted: true)
            }
            NSCursor.closedHand.push()
            cursorPushed = true
            let timer = Timer(timeInterval: 1.0 / 60, target: self, selector: #selector(autoScroll),
                              userInfo: nil, repeats: true)
            scrollTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        guard dragging else { return }
        let before = candidateIDs
        if visibleRect.contains(point), let source = candidateIDs.firstIndex(of: id) {
            let layout = QuotaBentoLayout(width: viewport.width, accountCount: accounts.count)
            let pitch = layout.cardWidth + layout.spacing
            let center = NSPoint(x: point.x - grabOffset.x + layout.cardWidth / 2,
                                 y: point.y - grabOffset.y + layout.cardWidth / 2)
            let column = max(0, min(layout.columns - 1, Int(floor((center.x - layout.leadingInset + layout.spacing / 2) / pitch))))
            let row = max(0, Int(floor((center.y - 2 + layout.spacing / 2) / pitch)))
            let target = min(accounts.count - 1, row * layout.columns + column)
            candidateIDs.remove(at: source)
            candidateIDs.insert(id, at: target)
        }
        layoutCards(animated: before != candidateIDs)
    }

    func finishTracking(point: NSPoint) {
        track(point: point) // A coalesced last mouse event must not lose the final drop position.
        guard let id = trackedID else { return }
        let wasDragging = dragging
        let inside = visibleRect.contains(point)
        let clickInside = buttons.first(where: { $0.account.id == id })?.frame.contains(point) == true
        let changed = inside && wasDragging && candidateIDs != accounts.map(\.id)
        if changed {
            let byID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
            accounts = candidateIDs.compactMap { byID[$0] }
        }
        cancelTracking(animated: true)
        if changed { onReorder(accounts.map(\.id)) }
        else if !wasDragging && inside && clickInside { open(id) }
    }

    func cancelTracking(animated: Bool = true) {
        scrollTimer?.invalidate()
        scrollTimer = nil
        if cursorPushed { NSCursor.pop(); cursorPushed = false }
        trackedID = nil
        dragging = false
        candidateIDs = accounts.map(\.id)
        buttons.forEach { $0.setInteraction(pressed: false, lifted: false) }
        layoutCards(animated: animated)
    }

    func open(_ id: String) {
        guard enabled, trackedID == nil else { return }
        focusToRestore = id
        onOpen(id)
    }

    func move(_ id: String, by delta: Int) {
        cancelTracking()
        guard enabled, let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        let target = max(0, min(accounts.count - 1, index + delta))
        guard target != index else { return }
        let item = accounts.remove(at: index)
        accounts.insert(item, at: target)
        candidateIDs = accounts.map(\.id)
        layoutCards(animated: true)
        onReorder(candidateIDs)
        scrollToVisible(slot(target))
    }

    @objc func autoScroll() {
        guard dragging, let scroll = enclosingScrollView, window != nil else { return }
        let point = convert(windowPointer, from: nil)
        let visible = visibleRect
        guard point.x >= visible.minX && point.x <= visible.maxX,
              point.y >= visible.minY && point.y <= visible.maxY else { return }
        let edge: CGFloat = 30
        let speed: CGFloat = point.y < visible.minY + edge ? -7 : (point.y > visible.maxY - edge ? 7 : 0)
        let y = min(max(0, visible.minY + speed), max(0, bounds.height - visible.height))
        guard speed != 0 && y != visible.minY else { return }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        track(point: convert(windowPointer, from: nil))
    }

    @objc private func windowLost(_ notification: Notification) {
        if notification.object as? NSWindow === window { cancelTracking() }
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { cancelTracking(animated: false) }
        super.viewWillMove(toWindow: newWindow)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard dragging, let id = trackedID, let index = candidateIDs.firstIndex(of: id) else { return }
        let path = NSBezierPath(roundedRect: slot(index).insetBy(dx: 1, dy: 1), xRadius: 22, yRadius: 22)
        NSColor(white: 0.12, alpha: 1).setFill()
        path.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.5).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

struct QuotaCardInteraction: Equatable {
    var hovered = false
    var pressed = false
    var lifted = false
}

@MainActor
final class QuotaGridButton: NSButton {
    private(set) var account: QuotaOverviewAccount
    weak var owner: QuotaGridDocumentView?
    private var pinned = false
    private var interaction = QuotaCardInteraction()
    private let host: NSHostingView<AnyView>
    private var hoverArea: NSTrackingArea?

    init(account: QuotaOverviewAccount) {
        self.account = account
        host = NSHostingView(rootView: AnyView(EmptyView()))
        super.init(frame: .zero)
        wantsLayer = true
        isBordered = false
        focusRingType = .none
        title = account.name
        target = self
        action = #selector(activate)
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        addSubview(host)
        setAccessibilityIdentifier("quota-account-\(account.id)")
        setAccessibilityRole(.button)
        let menu = NSMenu()
        for (label, action) in [("向前移动", #selector(moveEarlier)), ("向后移动", #selector(moveLater))] {
            let item = menu.addItem(withTitle: label, action: action, keyEquivalent: "")
            item.target = self
        }
        self.menu = menu
        update(account: account, pinned: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { isEnabled }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func draw(_ dirtyRect: NSRect) {} // SwiftUI draws the approved card, AppKit owns all input.
    override func layout() { super.layout(); host.frame = bounds }

    func update(account: QuotaOverviewAccount, pinned: Bool) {
        let changed = self.account != account || self.pinned != pinned
        self.account = account
        self.pinned = pinned
        title = account.name
        setAccessibilityLabel(account.accessibilitySummary)
        setAccessibilityHelp("单击查看详情；拖动调整顺序；Option 加方向键移动，Esc 取消拖动")
        toolTip = "\(account.accessibilitySummary) · 拖动调整顺序"
        if changed || host.frame.isEmpty { redrawCard() }
    }
    func setInteraction(pressed: Bool, lifted: Bool) {
        guard interaction.pressed != pressed || interaction.lifted != lifted else { return }
        interaction.pressed = pressed
        interaction.lifted = lifted
        redrawCard()
    }
    private func redrawCard() {
        host.rootView = AnyView(QuotaOverviewAccountCard(account: account, isPinned: pinned,
            onOpen: {}, interaction: interaction).allowsHitTesting(false).accessibilityHidden(true)
            .preferredColorScheme(.dark))
    }
    @objc private func activate() { owner?.open(account.id) }
    @objc private func moveEarlier() { owner?.move(account.id, by: -1) }
    @objc private func moveLater() { owner?.move(account.id, by: 1) }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        if let owner { owner.beginTracking(id: account.id, point: owner.convert(event.locationInWindow, from: nil)) }
    }
    override func mouseDragged(with event: NSEvent) {
        if let owner { owner.track(point: owner.convert(event.locationInWindow, from: nil)) }
    }
    override func mouseUp(with event: NSEvent) {
        if let owner { owner.finishTracking(point: owner.convert(event.locationInWindow, from: nil)) }
    }
    override func keyDown(with event: NSEvent) {
        guard isEnabled else { return }
        if event.keyCode == 53, owner?.dragging == true { owner?.cancelTracking(); return }
        if event.modifierFlags.contains(.option), [123, 124, 125, 126].contains(event.keyCode) {
            let columns = QuotaBentoLayout(width: Double(owner?.bounds.width ?? 0), accountCount: 0).columns
            let delta = event.keyCode == 123 ? -1 : event.keyCode == 124 ? 1 : event.keyCode == 125 ? columns : -columns
            owner?.move(account.id, by: delta)
            return
        }
        super.keyDown(with: event)
    }
    override func becomeFirstResponder() -> Bool { updateFocus(true); return true }
    override func resignFirstResponder() -> Bool { updateFocus(false); return true }
    private func updateFocus(_ focused: Bool) {
        layer?.cornerRadius = 22
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = focused && NSApp.isFullKeyboardAccessEnabled ? 1.5 : 0
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                 owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { interaction.hovered = true; redrawCard() }
    override func mouseExited(with event: NSEvent) { interaction.hovered = false; redrawCard() }
}
