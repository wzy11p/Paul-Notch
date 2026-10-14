import AppKit
import QuartzCore

/// Lets the native menu bar receive input without moving Paul's top anchor.
/// Exiting starts restoration immediately. Only a held native menu needs bounded,
/// event-driven retries; no timer, idle polling, screenshots, AX or key monitoring.
/// Yield only the compact wings. The expanded surface stays attached to the
/// bezel; clipping its top or lowering it behind the menu bar opens a blue gap.
@MainActor final class MenuBarYieldController: NSObject {
    struct Context {
        var enabled: Bool
        var screenFrame: NSRect
        var menuHeight: CGFloat
        var workspaceAcceptsInput: Bool

        var menuBand: NSRect {
            let height = min(max(menuHeight, 22), 64)
            return NSRect(x: screenFrame.minX, y: screenFrame.maxY - height,
                          width: screenFrame.width, height: height)
        }
    }

    private weak var ambient: NSWindow?
    private weak var workspace: NSWindow?
    private let context: () -> Context?
    private let pointer: () -> NSPoint
    private let buttons: () -> Int
    private let reduceMotion: () -> Bool
    private let menuIsOpen: @MainActor (NSRect) -> Bool
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var nextMenuProbeUptime: TimeInterval = 0
    private var trackingMenus: Set<ObjectIdentifier> = []
    private var running = false
    private var asleep = false
    private var isYielding = false

    init(ambient: NSWindow, workspace: NSWindow,
         pointer: @escaping () -> NSPoint = { NSEvent.mouseLocation },
         buttons: @escaping () -> Int = { NSEvent.pressedMouseButtons },
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         menuIsOpen: @escaping @MainActor (NSRect) -> Bool = MenuBarYieldController.hasNativeMenu,
         context: @escaping () -> Context?) {
        self.ambient = ambient; self.workspace = workspace
        self.pointer = pointer; self.buttons = buttons; self.reduceMotion = reduceMotion
        self.menuIsOpen = menuIsOpen; self.context = context
        super.init()
    }

    func start() {
        guard !running else { return }
        running = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(menuBegan(_:)), name: NSMenu.didBeginTrackingNotification, object: nil)
        center.addObserver(self, selector: #selector(menuEnded(_:)), name: NSMenu.didEndTrackingNotification, object: nil)
        center.addObserver(self, selector: #selector(windowChanged), name: NSWindow.didResizeNotification, object: workspace)
        center.addObserver(self, selector: #selector(windowChanged), name: NSWindow.didMoveNotification, object: workspace)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep),
            name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification, object: nil)
        refresh()
    }

    func stop() {
        running = false
        nextMenuProbeUptime = 0
        setMonitoring(false)
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        trackingMenus.removeAll()
        setYielding(false, animated: false)
        ambient?.ignoresMouseEvents = false
    }

    func refresh() {
        guard running else { return }
        let current = context()
        guard let state = current, state.enabled, !asleep else {
            setMonitoring(false)
            nextMenuProbeUptime = 0
            setYielding(false, animated: false)
            if ambient?.ignoresMouseEvents == true { ambient?.ignoresMouseEvents = false }
            if let current, workspace?.ignoresMouseEvents == current.workspaceAcceptsInput {
                workspace?.ignoresMouseEvents = !current.workspaceAcceptsInput
            }
            return
        }
        setMonitoring(true)
        let point = pointer()
        let inside = Self.contains(point, band: state.menuBand)
        // Every menu-band entry yields, including approaching a black wing
        // directly from below. Keep clicks passing through before the first
        // move event too; the physical-notch observer remains the open action.
        if ambient?.ignoresMouseEvents == false { ambient?.ignoresMouseEvents = true }
        if inside || !trackingMenus.isEmpty {
            nextMenuProbeUptime = 0
            setYielding(true)
        } else if isYielding && buttons() == 0 {
            restoreIfClear(state)
        }
        updateWorkspace(state)
    }

    static func contains(_ point: NSPoint, band: NSRect) -> Bool {
        return point.x >= band.minX && point.x < band.maxX
            && point.y >= band.minY && point.y <= band.maxY
    }

    private func restoreIfClear(_ state: Context) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= nextMenuProbeUptime else { return }
        // The first exit checks immediately. Repeated moves inside an external
        // popup are capped; a release retries immediately, with no idle work.
        if menuIsOpen(state.menuBand) {
            nextMenuProbeUptime = now + 0.15
            return
        }
        nextMenuProbeUptime = 0
        setYielding(false)
    }

    private func pointerEvent(_ event: NSEvent) {
        if event.type == .leftMouseUp || event.type == .rightMouseUp || event.type == .otherMouseUp {
            nextMenuProbeUptime = 0
        }
        refresh()
    }

    private func setMonitoring(_ enabled: Bool) {
        if !enabled {
            if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
            if let localMonitor { NSEvent.removeMonitor(localMonitor) }
            globalMonitor = nil; localMonitor = nil
            return
        }
        guard globalMonitor == nil, localMonitor == nil else { return }
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged,
            .otherMouseDragged, .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseUp, .rightMouseUp, .otherMouseUp]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
            MainActor.assumeIsolated { self?.pointerEvent(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            MainActor.assumeIsolated { self?.pointerEvent(event) }
            return event // Never consume or manufacture another application's event.
        }
    }

    private func setYielding(_ value: Bool, animated: Bool = true) {
        guard let layer = ambient?.contentView?.layer else { return }
        let target: Float = value ? 0 : 1
        if isYielding != value || layer.opacity != target {
            let from = layer.presentation()?.opacity ?? layer.opacity
            layer.removeAnimation(forKey: "menu-bar-yield")
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.opacity = target
            CATransaction.commit()
            if animated && !reduceMotion() {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = from; fade.toValue = target
                fade.duration = value ? 0.12 : 0.10
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(fade, forKey: "menu-bar-yield")
            }
        }
        isYielding = value
    }

    private func updateWorkspace(_ state: Context) {
        guard let workspace else { return }
        // Its top is deliberately opaque. Never click an invisible native menu
        // item behind it; all visible expanded pixels belong to this workspace.
        let ignoresInput = !state.workspaceAcceptsInput
        if workspace.ignoresMouseEvents != ignoresInput { workspace.ignoresMouseEvents = ignoresInput }
    }

    @objc private func menuBegan(_ note: Notification) {
        guard let menu = note.object as? NSMenu else { return }
        trackingMenus.insert(ObjectIdentifier(menu)); refresh()
    }
    @objc private func menuEnded(_ note: Notification) {
        guard let menu = note.object as? NSMenu else { return }
        trackingMenus.remove(ObjectIdentifier(menu)); refresh()
    }
    @objc private func windowChanged() { refresh() }
    @objc private func willSleep() { asleep = true; nextMenuProbeUptime = 0; setMonitoring(false) }
    @objc private func didWake() { asleep = false; trackingMenus.removeAll(); refresh() }

    private static func hasNativeMenu(_ menuBand: NSRect) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID) as? [[String: Any]], let primary = NSScreen.screens.first else { return true }
        return windows.contains { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? Int,
                  pid != ProcessInfo.processInfo.processIdentifier,
                  let level = window[kCGWindowLayer as String] as? Int,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            let appKitFrame = NSRect(x: frame.minX, y: primary.frame.maxY - frame.maxY,
                                     width: frame.width, height: frame.height)
            return isMenuLike(frame: appKitFrame, level: level, band: menuBand)
        }
    }

    static func isMenuLike(frame: NSRect, level: Int, band: NSRect) -> Bool {
        // No titles, pixels, icon identities or app content. Narrowly match
        // top-attached native popups, excluding the thin status bar itself.
        level >= Int(CGWindowLevelForKey(.mainMenuWindow))
            && level < Int(CGWindowLevelForKey(.screenSaverWindow))
            && frame.height > band.height + 8 && frame.width < band.width * 0.8
            && frame.maxY >= band.minY - 80 && frame.minY < band.minY
            && frame.maxX > band.minX && frame.minX < band.maxX
    }
}
