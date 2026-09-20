import AppKit
import SwiftUI
import QuartzCore
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum PanelPresentationMode {
        case ambient
        case workspace
    }

    private let store = TaskStore(repository: LocalTaskRepository(fileURL: AppDelegate.memoPreviewFileURL))
    private static var memoPreviewFileURL: URL? {
        AppEnvironment.usesIsolatedWorkspace ? AppEnvironment.dataDirectory.appendingPathComponent("tasks.json") : nil
    }
    private let clipboardStore = ClipboardStore()
    private let linksStore = LinksStore()
    private let commandsStore = CommandsStore()
    private let pomodoroStore = PomodoroStore()
    private let recordingsStore = RecordingStore()
    private let credentialsStore = CredentialsStore()
    private let musicService = MusicService()
    private let noteStore = NoteStore(repository: LocalNoteRepository(directory: AppEnvironment.dataDirectory),
                                      legacyText: { AppEnvironment.defaults.string(forKey: "home-quick-note") })
    private let windowListService = WindowListService()
    private let notifyServer = AgentNotifyServer()
    private let codexStatusStore = CodexStatusStore()
    private let aiApplicationDetector = AIApplicationDetector()
    private let appSettings = AppSettingsStore()
    private let panelMetrics = PanelMetrics()
    private let ambientPresentation = AmbientNotchPresentation()
    private lazy var reminderScheduler = TaskReminderScheduler { [weak self] in
        self?.store.tasks ?? []
    }
    private var panel: IslandPanel!
    private var ambientPanel: AmbientPanel!
    private var drawerView: NSView!
    private var ambientDrawerView: NSView!
    private var displaySettingsWindow: NSWindow?
    private var statusItem: NSStatusItem!
    private var openMenuItem: NSMenuItem?
    private var presentationMenuItem: NSMenuItem?
    private var presentationTrackingTimer: Timer?
    private var revealPolicy = PresentationRevealPolicy()
    private var presentationModeEnabled = AppEnvironment.defaults.bool(forKey: "presentation-mode-enabled-v1")
    private var shortcutConfiguration = ShortcutConfiguration.load()
    private var pointerTrackingTimer: Timer?
    private var ambientEnvironmentSettleTask: Task<Void, Never>?
    private var globalHotKey: GlobalHotKey?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var isAnimatingIn = false
    private var isAnimatingOut = false
    private var isPinnedByHotKey = false
    private var hasPointerEnteredAfterHotKey = false
    private var pointerOutsideSince: Date?
    private var panelPresentationMode: PanelPresentationMode = .ambient

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        appSettings.canDisableHomeModule = { [weak recordingsStore] module in
            (module != .recorder && module != .recordings) || recordingsStore?.state == .idle
        }
        appSettings.onClipboardConfigurationChanged = { [weak clipboardStore] in
            clipboardStore?.applyPreferences()
        }
        // Resolve only explicitly saved capture choices, including in the personal profile.
        // No timer or clipboard content capture starts when both types are disabled.
        clipboardStore.startMonitoring()
        setupPanels()
        showAmbientPanel(on: preferredAmbientScreen())
        setupMenuBar()
        if presentationModeEnabled { startPresentationTracking() }
        if Self.memoPreviewFileURL != nil {
            // Every store uses the isolated environment; background services remain opt-in.
            store.load()
            setupDismissMonitors()
            if ProcessInfo.processInfo.arguments.contains("--preview-live-codex")
                || Bundle.main.object(forInfoDictionaryKey: "PaulPreviewLiveCodex") as? Bool == true {
                codexStatusStore.start()
            }
            if !presentationModeEnabled {
                if let screen = preferredAmbientScreen() { showPanel(on: screen) }
                panel.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            return
        }
        setupGlobalHotKey()
        setupDismissMonitors()
        store.load()
        reminderScheduler.start()
        notifyServer.start()
        codexStatusStore.start()
        aiApplicationDetector.scan()
        startAmbientEnvironmentTracking()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard noteStore.isLoaded else { return .terminateNow }
        Task {
            await noteStore.flushDraft()
            if let error = noteStore.errorMessage {
                let alert = NSAlert()
                alert.messageText = "随笔草稿尚未保存"
                alert.informativeText = error
                alert.addButton(withTitle: "返回检查")
                alert.runModal()
                sender.reply(toApplicationShouldTerminate: false)
            } else {
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        presentationTrackingTimer?.invalidate()
        clipboardStore.stopMonitoring()
        pointerTrackingTimer?.invalidate()
        ambientEnvironmentSettleTask?.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        reminderScheduler.stop()
        notifyServer.stop()
        codexStatusStore.stop()
        globalHotKey?.invalidate()
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
    }

    private func setupPanels() {
        panel = IslandPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: IslandTheme.panelWidth,
                height: panelMetrics.topInset
                    + IslandTheme.topbarHeight
                    + IslandTheme.s3
                    + IslandTheme.panelContentHeight
                    + IslandTheme.s4
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let workspace = IslandView(
            store: store,
            noteStore: noteStore,
            clipboardStore: clipboardStore,
            linksStore: linksStore,
            commandsStore: commandsStore,
            pomodoroStore: pomodoroStore,
            recordingsStore: recordingsStore,
            credentialsStore: credentialsStore,
            musicService: musicService,
            windowListService: windowListService,
            notifyServer: notifyServer,
            codexStatusStore: codexStatusStore,
            appSettings: appSettings,
            panelMetrics: panelMetrics,
            onOpenDisplaySettings: { [weak self] in self?.openSettingsFromPanel() },
            onCloseWorkspace: { [weak self] in self?.closeWorkspaceExplicitly() }
        )
        let workspaceHostingView = NSHostingView(rootView: workspace)
        workspaceHostingView.wantsLayer = true
        workspaceHostingView.layer?.backgroundColor = NSColor.clear.cgColor
        workspaceHostingView.layer?.cornerCurve = .continuous
        workspaceHostingView.layer?.cornerRadius = IslandTheme.radiusPanel
        workspaceHostingView.layer?.masksToBounds = true
        workspaceHostingView.autoresizingMask = [.width, .height]
        drawerView = workspaceHostingView
        panel.contentView = workspaceHostingView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isMovable = false

        ambientPanel = AmbientPanel(
            contentRect: NSRect(x: 0, y: 0, width: 275, height: 32),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let ambient = AmbientNotchView(
            codexStatus: codexStatusStore,
            presentation: ambientPresentation,
            onOpen: { [weak self] in
                self?.toggleAmbientClick()
            }
        )
        let ambientHostingView = NSHostingView(rootView: ambient)
        ambientHostingView.wantsLayer = true
        ambientHostingView.layer?.backgroundColor = NSColor.clear.cgColor
        ambientHostingView.autoresizingMask = [.width, .height]
        ambientDrawerView = ambientHostingView
        ambientPanel.contentView = ambientHostingView
        ambientPanel.backgroundColor = .clear
        ambientPanel.isOpaque = false
        ambientPanel.hasShadow = false
        ambientPanel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        ambientPanel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
            .stationary,
        ]
        ambientPanel.hidesOnDeactivate = false
        ambientPanel.isMovable = false
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = PaulBrand.menuBarImage()

        let menu = NSMenu()
        openMenuItem = menu.addItem(
            withTitle: "打开 Paul Notch  \(shortcutConfiguration.displayText)",
            action: #selector(openFromMenu),
            keyEquivalent: "o"
        )
        menu.addItem(withTitle: "修改快捷键…", action: #selector(editShortcut), keyEquivalent: "")
        menu.addItem(withTitle: "打开设置中心…", action: #selector(openDisplaySettings), keyEquivalent: ",")
        presentationMenuItem = menu.addItem(withTitle: "演示模式（悬停临时显示）",
                                           action: #selector(togglePresentationMode), keyEquivalent: "p")
        presentationMenuItem?.keyEquivalentModifierMask = [.command, .option, .shift]
        presentationMenuItem?.state = presentationModeEnabled ? .on : .off
        presentationMenuItem?.toolTip = "隐藏刘海；移入原区域停留后临时显示，点击才展开。临时显示的内容也会出现在投屏中。"
        menu.addItem(.separator())
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
        let versionItem = menu.addItem(withTitle: "版本 \(version)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Paul Notch", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    private func setupGlobalHotKey() {
        globalHotKey = GlobalHotKey(
            keyCode: shortcutConfiguration.keyCode,
            modifiers: shortcutConfiguration.modifiers
        ) { [weak self] in
            self?.toggleHotKeyPanel()
        }
    }

    private func setupDismissMonitors() {
        let mouseEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) { [weak self] event in
            let pointer = NSEvent.mouseLocation
            Task { @MainActor in self?.handleMouseDown(event, at: pointer) }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseEvents) { [weak self] event in
            MainActor.assumeIsolated { self?.handleLocalMouseDown(event) }
            return event
        }
    }

    private func startPointerTracking() {
        pointerTrackingTimer?.invalidate()
        let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkPointer() }
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        pointerTrackingTimer = timer
        checkPointer()
    }

    private func startAmbientEnvironmentTracking() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            self,
            selector: #selector(ambientEnvironmentDidChange(_:)),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(ambientEnvironmentDidChange(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(ambientEnvironmentDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        refreshAmbientEnvironment(animated: false)
    }

    @objc private func ambientEnvironmentDidChange(_ notification: Notification) {
        refreshAmbientEnvironment()

        // Space and full-screen window metadata can settle one run-loop later
        // than the notification. Coalesce changes into one subordinate follow-up
        // rather than polling CGWindowList continuously during the gesture.
        ambientEnvironmentSettleTask?.cancel()
        ambientEnvironmentSettleTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 120_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.refreshAmbientEnvironment()
        }
    }

    private func refreshAmbientEnvironment(animated: Bool = true) {
        let isFullScreen = frontmostApplicationIsFullScreen()
        let stateChanged = ambientPresentation.isFrontmostAppFullScreen != isFullScreen
        ambientPresentation.isFrontmostAppFullScreen = isFullScreen

        let screen = ambientPanel.screen ?? preferredAmbientScreen()
        layoutAmbientPanel(on: screen, animated: animated && stateChanged)
    }

    private func checkPointer() {
        // Presentation mode has its own dwell/hide policy, including editing guards.
        if presentationModeEnabled { return }
        // Pointer movement may only keep an already-open panel visible or hide it.
        // Opening is exclusively handled by click, shortcut, or menu actions.
        guard panelPresentationMode == .workspace, panel.isVisible else { return }
        if store.memoEditingActive || noteStore.isEditing {
            pointerOutsideSince = nil
            return
        }
        guard let screen = screenContainingMouse() ?? NSScreen.main else { return }
        let pointer = NSEvent.mouseLocation
        // Date editing is presented in a separate popover window. Treat that popover
        // as part of the drawer so it remains usable while the main panel is open.
        let insidePanelOrPopover = isInsideDrawerOrPopover(pointer)

        if isPinnedByHotKey {
            pointerOutsideSince = nil
            return
        }

        if insidePanelOrPopover {
            pointerOutsideSince = nil
        } else if !isAnimatingIn && !isAnimatingOut && pointerHasStayedOutsideLongEnough() {
            hidePanel(on: screen)
        }
    }

    private func pointerHasStayedOutsideLongEnough() -> Bool {
        let now = Date()
        guard let pointerOutsideSince else {
            self.pointerOutsideSince = now
            return false
        }
        return now.timeIntervalSince(pointerOutsideSince) >= 0.5
    }

    private func toggleAmbientClick() {
        guard let screen = ambientPanel.screen ?? preferredAmbientScreen() else { return }
        // Hover is artwork feedback only. Every deliberate click toggles the workspace.
        // Ignore repeated presses during dismissal so two animations cannot race.
        guard !isAnimatingOut else { return }
        if panelPresentationMode == .workspace {
            isPinnedByHotKey = false
            hidePanel(on: screen)
        } else {
            isPinnedByHotKey = true
            showPanel(on: screen)
        }
    }

    private func showPanel(on screen: NSScreen) {
        if presentationModeEnabled {
            layoutAmbientPanel(on: screen, animated: false)
            ambientPanel.orderFrontRegardless()
        }
        pointerOutsideSince = nil
        // 顶边距 = 菜单栏高 + 4，让顶栏避让物理刘海；宽度按屏 clamp。
        let menuBarHeight = max(
            screen.safeAreaInsets.top,
            screen.frame.maxY - screen.visibleFrame.maxY
        )
        panelMetrics.topInset = menuBarHeight + 4
        let size = NSSize(
            width: min(IslandTheme.panelWidth, screen.frame.width - 24),
            height: menuBarHeight + 4 + IslandTheme.topbarHeight + IslandTheme.s3
                + IslandTheme.panelContentHeight + IslandTheme.s4
        )
        let x = screen.frame.midX - size.width / 2
        let expandedY = screen.frame.maxY - size.height
        let targetFrame = NSRect(origin: NSPoint(x: x, y: expandedY), size: size)

        // If the pointer reaches the notch on another display while the drawer is
        // already visible, move it to that display instead of leaving it behind.
        if panelPresentationMode == .workspace && panel.isVisible && !isAnimatingOut {
            if abs(panel.frame.origin.x - targetFrame.origin.x) > 0.5
                || abs(panel.frame.origin.y - targetFrame.origin.y) > 0.5
                || abs(panel.frame.width - targetFrame.width) > 0.5 {
                panel.setFrame(targetFrame, display: true)
            }
            return
        }

        isAnimatingIn = true
        isAnimatingOut = false
        panelPresentationMode = .workspace
        // Keep the real window in its final position. Only its clipped content
        // moves, avoiding off-screen NSPanel frame constraints near the notch.
        panel.setFrame(targetFrame, display: false)
        drawerView.frame = NSRect(origin: NSPoint(x: 0, y: size.height - 42), size: size)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        musicService.workspaceDidOpen()
        ambientPanel.orderFrontRegardless()
        ambientPanel.order(.above, relativeTo: panel.windowNumber)
        startPointerTracking()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.16,
                1,
                0.3,
                1
            )
            self.drawerView.animator().setFrameOrigin(.zero)
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self,
                      self.panelPresentationMode == .workspace,
                      !self.isAnimatingOut else { return }
                self.isAnimatingIn = false
                self.checkPointer()
            }
        }
    }

    private func hidePanel(on _: NSScreen) {
        guard panelPresentationMode == .workspace else { return }
        Task { await noteStore.flushDraft() }
        pointerOutsideSince = nil
        panelMetrics.panelWillHide()
        isAnimatingIn = false
        isAnimatingOut = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.drawerView.animator().setFrameOrigin(
                NSPoint(x: 0, y: self.panel.frame.height - 42)
            )
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self,
                      self.panelPresentationMode == .workspace,
                      self.isAnimatingOut else { return }
                self.isAnimatingOut = false
                self.store.requestMemoListReset()
                self.showAmbientPanel(
                    on: self.ambientPanel.screen ?? self.panel.screen ?? self.preferredAmbientScreen()
                )
            }
        }
    }

    private func showAmbientPanel(on screen: NSScreen?) {
        guard let screen else { return }
        panelPresentationMode = .ambient
        isAnimatingIn = false
        isAnimatingOut = false
        pointerOutsideSince = nil
        pointerTrackingTimer?.invalidate()
        pointerTrackingTimer = nil
        panel.orderOut(nil)

        let geometry = ambientGeometry(on: screen)
        ambientPresentation.centerGapWidth = geometry.centerGapWidth
        ambientPanel.setFrame(geometry.frame, display: true)
        ambientDrawerView.frame = NSRect(origin: .zero, size: geometry.frame.size)
        applyAmbientCornerMask()
        ambientPanel.alphaValue = 1
        if presentationModeEnabled {
            ambientPanel.orderOut(nil)
            revealPolicy.reset()
        } else {
            ambientPanel.orderFrontRegardless()
        }
    }

    private func layoutAmbientPanel(on screen: NSScreen?, animated: Bool) {
        guard let screen else { return }
        let geometry = ambientGeometry(on: screen)
        ambientPresentation.centerGapWidth = geometry.centerGapWidth
        applyAmbientCornerMask()
        guard geometry.frame != ambientPanel.frame else { return }

        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = ambientPresentation.isFrontmostAppFullScreen ? 0.2 : 0.28
                context.timingFunction = CAMediaTimingFunction(
                    controlPoints: 0.16,
                    1,
                    0.3,
                    1
                )
                ambientPanel.animator().setFrame(geometry.frame, display: true)
            }
        } else {
            ambientPanel.setFrame(geometry.frame, display: true)
        }
    }

    private func applyAmbientCornerMask() {
        guard let layer = ambientDrawerView.layer else { return }
        layer.cornerCurve = .continuous
        layer.cornerRadius = ambientPresentation.isFrontmostAppFullScreen ? 12 : 16
        layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        layer.masksToBounds = true
    }

    private struct AmbientGeometry {
        let frame: NSRect
        let centerGapWidth: CGFloat
    }

    private func ambientGeometry(on screen: NSScreen) -> AmbientGeometry {
        let notch = physicalNotchGap(on: screen)
        let hasPhysicalNotch = notch != nil
        let centerGap = notch?.width ?? 14
        let quotaCount = min(2, codexStatusStore.displayQuotaWindows.count)
        let isFullScreen = ambientPresentation.isFrontmostAppFullScreen
        let wingWidth: CGFloat = isFullScreen ? 42 : 48
        let unconstrainedWidth = hasPhysicalNotch
            ? centerGap + wingWidth * 2
            : (quotaCount > 1 ? 236 : 220)
        let width = min(unconstrainedWidth, screen.frame.width - 32)
        let topInset = max(
            screen.safeAreaInsets.top,
            screen.frame.maxY - screen.visibleFrame.maxY
        )
        let topBandHeight = max(24, topInset)
        let height: CGFloat = isFullScreen
            ? min(24, topBandHeight)
            : min(hasPhysicalNotch ? 32 : 28, topBandHeight)
        let x = screen.frame.midX - width / 2
        // Attach directly to the display's top edge so the status surface reads
        // as part of the hardware notch. Compact fixed wings reduce collisions
        // with application menus and status items.
        let y = screen.frame.maxY - height
        return AmbientGeometry(
            frame: NSRect(x: x, y: y, width: width, height: height),
            centerGapWidth: min(centerGap, max(14, width - 100))
        )
    }

    private func physicalNotchGap(on screen: NSScreen) -> NSRect? {
        guard let leftArea = screen.auxiliaryTopLeftArea,
              let rightArea = screen.auxiliaryTopRightArea,
              !leftArea.isEmpty,
              !rightArea.isEmpty,
              rightArea.minX > leftArea.maxX else {
            return nil
        }
        return NSRect(
            x: leftArea.maxX,
            y: min(leftArea.minY, rightArea.minY),
            width: rightArea.minX - leftArea.maxX,
            height: min(leftArea.height, rightArea.height)
        )
    }

    private func preferredAmbientScreen() -> NSScreen? {
        NSScreen.screens.first(where: { physicalNotchGap(on: $0) != nil })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func frontmostApplicationIsFullScreen() -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
              ) as? [[String: Any]] else {
            return false
        }

        var layerZeroBounds: [CGRect] = []
        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32,
                  pid == frontmost.processIdentifier,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else {
                continue
            }

            // Chromium-style full-screen windows split the menu/tab/content areas
            // into multiple CG windows. Their private menu-bar cover is a reliable
            // signal that the frontmost app owns the full-screen space.
            if layer > 0, NSScreen.screens.contains(where: { screen in
                let topInset = max(
                    screen.safeAreaInsets.top,
                    screen.frame.maxY - screen.visibleFrame.maxY
                )
                return abs(bounds.width - screen.frame.width) <= 4
                    && bounds.height >= 20
                    && bounds.height <= max(44, topInset + 12)
            }) {
                return true
            }

            if layer == 0 { layerZeroBounds.append(bounds) }
        }

        guard let firstBounds = layerZeroBounds.first else { return false }
        let combinedBounds = layerZeroBounds.dropFirst().reduce(firstBounds) { partial, bounds in
            partial.union(bounds)
        }

        return NSScreen.screens.contains { screen in
            let topInset = max(
                screen.safeAreaInsets.top,
                screen.frame.maxY - screen.visibleFrame.maxY
            )
            let usableFullScreenHeight = screen.frame.height - topInset
            return abs(combinedBounds.width - screen.frame.width) <= 4
                && combinedBounds.height >= usableFullScreenHeight - 4
        }
    }

    private func screenContainingMouse() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(point) }
    }

    private func notchTrigger(on screen: NSScreen) -> NSRect {
        if let leftArea = screen.auxiliaryTopLeftArea,
           let rightArea = screen.auxiliaryTopRightArea,
           !leftArea.isEmpty,
           !rightArea.isEmpty,
           rightArea.minX > leftArea.maxX {
            // The gap between the two unobscured menu-bar areas is the physical notch.
            // A 3pt horizontal allowance prevents precision issues without occupying
            // any of the usable content directly below it.
            let menuBarHeight = max(
                screen.safeAreaInsets.top,
                screen.frame.maxY - screen.visibleFrame.maxY
            )
            let height = min(max(menuBarHeight + 8, 36), 54)
            return NSRect(
                x: leftArea.maxX - 3,
                y: screen.frame.maxY - height,
                width: rightArea.minX - leftArea.maxX + 6,
                height: height
            )
        }

        // Displays without a notch get a compact top-center trigger only.
        return NSRect(
            x: screen.frame.midX - 90,
            y: screen.frame.maxY - 30,
            width: 180,
            height: 30
        )
    }

    private func isInsideDrawerOrPopover(_ point: NSPoint) -> Bool {
        if let button = statusItem.button,
           let window = button.window {
            let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
            if buttonFrame.contains(point) { return true }
        }
        return NSApp.windows.contains { $0.isVisible && $0.frame.contains(point) }
    }

    private func handleLocalMouseDown(_ event: NSEvent) {
        // SwiftUI owns shelf taps. Handling mouse-down here too would toggle twice.
        if event.window === ambientPanel { return }
        // An event dispatched to our own window is not an outside click. Window
        // coordinates during a panel animation are not a reliable global hit test.
        if event.window != nil {
            if event.window === panel, panelPresentationMode == .workspace {
                // A deliberate click inside the workspace leaves hover-preview
                // mode: the next notch click must close, not merely pin, it.
                isPinnedByHotKey = true
            }
            pointerOutsideSince = nil
            return
        }
        handleMouseDown(event, at: NSEvent.mouseLocation)
    }

    private func handleMouseDown(_ event: NSEvent, at pointer: NSPoint) {
        // An invisible trigger is observation-only: never steal clicks from another app.
        if presentationModeEnabled && !ambientPanel.isVisible && !panel.isVisible { return }
        guard let screen = screenContainingMouse() ?? NSScreen.main else { return }

        if event.type == .leftMouseDown,
           !ambientPanel.frame.contains(pointer),
           notchTrigger(on: screen).contains(pointer) {
            toggleAmbientClick()
            return
        }

        dismissHotKeyPanelIfClickedOutside(at: pointer)
    }

    private func dismissHotKeyPanelIfClickedOutside(at pointer: NSPoint) {
        if presentationModeEnabled && (store.memoEditingActive || noteStore.isEditing) { return }
        // An IME candidate panel may belong to the input-method process, not our
        // window list. Do not dismiss the note beneath a candidate-selection click.
        guard !store.memoEditingActive, noteStore.composingDraftID == nil else { return }
        guard panelPresentationMode == .workspace, (isPinnedByHotKey || noteStore.isEditing), panel.isVisible else { return }
        guard !isInsideDrawerOrPopover(pointer),
              let screen = screenContainingMouse() ?? NSScreen.main else {
            hasPointerEnteredAfterHotKey = true
            return
        }

        isPinnedByHotKey = false
        hasPointerEnteredAfterHotKey = false
        pointerOutsideSince = nil
        hidePanel(on: screen)
    }

    private func closeWorkspaceExplicitly() {
        guard let screen = ambientPanel.screen ?? preferredAmbientScreen() else { return }
        isPinnedByHotKey = false
        hidePanel(on: screen)
    }

    @objc private func openFromMenu() {
        guard let screen = NSScreen.main else { return }
        isPinnedByHotKey = true
        showPanel(on: screen)
        hasPointerEnteredAfterHotKey = isInsideDrawerOrPopover(NSEvent.mouseLocation)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        store.requestAddFocus()
    }

    @objc private func togglePresentationMode() {
        presentationModeEnabled.toggle()
        AppEnvironment.defaults.set(presentationModeEnabled, forKey: "presentation-mode-enabled-v1")
        presentationMenuItem?.state = presentationModeEnabled ? .on : .off
        revealPolicy.reset()
        if presentationModeEnabled {
            // Explicit mode change hides immediately; do not reset or discard active editors.
            concealForPresentation()
            startPresentationTracking()
        } else {
            presentationTrackingTimer?.invalidate()
            presentationTrackingTimer = nil
            if panelPresentationMode != .workspace {
                showAmbientPanel(on: preferredAmbientScreen())
            }
        }
    }

    private func startPresentationTracking() {
        presentationTrackingTimer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkPresentationPointer() }
        }
        timer.tolerance = 0.015
        RunLoop.main.add(timer, forMode: .common)
        presentationTrackingTimer = timer
    }

    private func concealForPresentation() {
        Task { await noteStore.flushDraft() }
        isAnimatingIn = false
        isAnimatingOut = false
        isPinnedByHotKey = false
        panelPresentationMode = .ambient
        pointerOutsideSince = nil
        pointerTrackingTimer?.invalidate()
        pointerTrackingTimer = nil
        panelMetrics.panelWillHide()
        panel.orderOut(nil)
        ambientPanel.orderOut(nil)
        revealPolicy.reset()
    }

    private func checkPresentationPointer() {
        guard presentationModeEnabled, let screen = screenContainingMouse() else {
            revealPolicy.reset()
            return
        }
        let pointer = NSEvent.mouseLocation
        let frame = ambientGeometry(on: screen).frame
        let visible = ambientPanel.isVisible || panel.isVisible
        let editing = panel.isVisible && (store.memoEditingActive || noteStore.isEditing || noteStore.composingDraftID != nil)
        let action = revealPolicy.update(now: ProcessInfo.processInfo.systemUptime,
            region: NSStringFromRect(screen.frame), insideTrigger: frame.contains(pointer),
            insideVisibleSurface: isInsideDrawerOrPopover(pointer), visible: visible, editing: editing)
        switch action {
        case .none: break
        case .reveal:
            layoutAmbientPanel(on: screen, animated: false)
            ambientPanel.alphaValue = 1
            ambientPanel.orderFrontRegardless()
        case .hide:
            concealForPresentation()
        }
    }

    @objc private func editShortcut() {
        let recorder = ShortcutRecorderView(initial: shortcutConfiguration)
        let alert = NSAlert()
        alert.messageText = "修改快捷键"
        alert.informativeText = "点击下方区域，然后按下新的组合键。快捷键必须包含 Command、Option 或 Control。"
        alert.accessoryView = recorder
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { alert.window.makeFirstResponder(recorder) }

        guard alert.runModal() == .alertFirstButtonReturn,
              let configuration = recorder.capturedConfiguration else { return }
        guard configuration != shortcutConfiguration else { return }

        let previousConfiguration = shortcutConfiguration
        globalHotKey?.invalidate()
        globalHotKey = nil
        let candidate = makeGlobalHotKey(configuration)
        guard candidate.isRegistered else {
            candidate.invalidate()
            globalHotKey = makeGlobalHotKey(previousConfiguration)
            let errorAlert = NSAlert()
            errorAlert.messageText = "快捷键无法使用"
            errorAlert.informativeText = "这个组合键可能已被其他应用占用，请换一个再试。"
            errorAlert.runModal()
            return
        }

        globalHotKey = candidate
        shortcutConfiguration = configuration
        shortcutConfiguration.save()
        appSettings.updateShortcutDisplayText(configuration.displayText)
        openMenuItem?.title = "打开 Paul Notch  \(configuration.displayText)"
    }

    @objc private func openDisplaySettings() {
        if let displaySettingsWindow {
            displaySettingsWindow.center()
            displaySettingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Paul Notch · 设置中心"
        window.contentView = NSHostingView(rootView: DisplaySettingsView(
            settings: appSettings,
            pomodoro: pomodoroStore,
            recordings: recordingsStore,
            notifyServer: notifyServer,
            aiApplications: aiApplicationDetector,
            music: musicService,
            onEditShortcut: { [weak self] in self?.editShortcut() }
        ))
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.center()
        displaySettingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openSettingsFromPanel() {
        if panelPresentationMode == .workspace,
           panel.isVisible,
           let screen = screenContainingMouse() ?? panel.screen ?? NSScreen.main {
            isPinnedByHotKey = false
            hasPointerEnteredAfterHotKey = false
            hidePanel(on: screen)
        }
        openDisplaySettings()
    }

    private func makeGlobalHotKey(_ configuration: ShortcutConfiguration) -> GlobalHotKey {
        GlobalHotKey(keyCode: configuration.keyCode, modifiers: configuration.modifiers) { [weak self] in
            self?.toggleHotKeyPanel()
        }
    }

    private func toggleHotKeyPanel() {
        guard let screen = screenContainingMouse() ?? NSScreen.main else { return }
        if panelPresentationMode == .workspace && panel.isVisible && isPinnedByHotKey {
            isPinnedByHotKey = false
            hasPointerEnteredAfterHotKey = false
            hidePanel(on: screen)
            return
        }

        isPinnedByHotKey = true
        showPanel(on: screen)
        hasPointerEnteredAfterHotKey = isInsideDrawerOrPopover(NSEvent.mouseLocation)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.store.requestAddFocus()
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Accessory panels have no application Edit menu to forward these commands.
        if event.modifierFlags.contains(.command), let editor = firstResponder as? NSTextView {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a": editor.selectAll(nil); return true
            case "c": editor.copy(nil); return true
            case "v": editor.paste(nil); return true
            case "x": editor.cut(nil); return true
            case "z":
                if let undo = editor.undoManager {
                    if event.modifierFlags.contains(.shift) { undo.redo() } else { undo.undo() }
                    return true
                }
            case "\r" where editor.hasMarkedText():
                return true // Never submit while a Chinese/Japanese candidate is being composed.
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class AmbientPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
