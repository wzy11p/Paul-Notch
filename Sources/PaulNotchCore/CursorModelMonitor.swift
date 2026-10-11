import AppKit
import ApplicationServices
import Combine

@MainActor final class CursorModelMonitor: ObservableObject {
    static let preferenceKey = "quota.cursor-model-follow.enabled.v1"
    @Published private(set) var enabled: Bool
    @Published private(set) var selection = CursorModelSelection.disabled
    @Published private var webObservation = CursorWebObservation.unavailable
    var isMonitoring: Bool { fallback != nil }
    private let defaults: UserDefaults
    private let allowsInspection: Bool
    private let foregroundPID: @MainActor () -> Int32?
    private let trusted: @MainActor () -> Bool
    private let read: @Sendable (Int32) async -> CursorModelSelection
    private let readWeb: @Sendable (Int32) async -> CursorWebObservation
    private let clock: @MainActor () -> Date
    private var cursorPID: Int32?
    private var inspectingChrome = false
    private var suspended = false
    private var generation = 0
    private var observedAt = Date.distantPast
    private var lastRead = -Double.infinity
    private var fallback: Task<Void, Never>?
    private var pending: Task<Void, Never>?
    private var reading: Task<Void, Never>?
    private var observer: AXObserver?
    private var powerObservers: [NSObjectProtocol] = []
    init(defaults: UserDefaults, allowsInspection: Bool,
         foregroundPID: @escaping @MainActor () -> Int32? = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
         trusted: @escaping @MainActor () -> Bool = { AXIsProcessTrusted() },
         clock: @escaping @MainActor () -> Date = Date.init,
         read: @escaping @Sendable (Int32) async -> CursorModelSelection = { await CursorModelAXReader.shared.read(pid: $0) },
         readWeb: @escaping @Sendable (Int32) async -> CursorWebObservation = { await CursorModelAXReader.shared.readWeb(pid: $0) }) {
        self.defaults = defaults; self.allowsInspection = allowsInspection
        self.foregroundPID = foregroundPID; self.trusted = trusted; self.read = read; self.clock = clock
        self.readWeb = readWeb
        enabled = allowsInspection && defaults.bool(forKey: Self.preferenceKey)
        selection = enabled ? .unavailable : .disabled
        if allowsInspection {
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
                powerObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.setSuspended(true) }
                })
            }
            for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
                powerObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.setSuspended(false) }
                })
            }
        }
    }
    func setEnabled(_ value: Bool) {
        guard allowsInspection else { return }
        enabled = value
        defaults.set(value, forKey: Self.preferenceKey)
        reconcile()
    }
    func observeForeground(bundleIdentifier: String?, pid: Int32?) {
        let chrome = bundleIdentifier == "com.google.Chrome"
        let next = chrome || bundleIdentifier == "com.todesktop.230313mzl4w4u92" ? pid : nil
        if next != cursorPID || inspectingChrome != chrome {
            endObservation(); cursorPID = next; inspectingChrome = chrome
        }
        reconcile()
    }
    func recognizesCursorWeb(at date: Date) -> Bool {
        enabled && !suspended && inspectingChrome && cursorPID != nil && foregroundPID() == cursorPID &&
            webObservation.isCursorPage && (-1...12).contains(date.timeIntervalSince(observedAt))
    }
    func context(at date: Date) -> CursorModelSelection {
        if selection.pool != nil || selection == .automatic {
            return (-1...12).contains(date.timeIntervalSince(observedAt)) ? selection : .unavailable
        }
        return selection
    }
    func signalChange() {
        guard enabled, !suspended, allowsInspection, let pid = cursorPID, foregroundPID() == pid,
              reading == nil, pending == nil else { return }
        guard trusted() else { endObservation(); publish(.permissionRequired); return }
        // Coalesce notification bursts. No more than one read per 0.8 s; the
        // fallback runs once per 5 s, only while Cursor or verified Chrome is
        // frontmost. Chrome's reader rejects other origins before model reads.
        let delay = max(0.12, 0.8 - (ProcessInfo.processInfo.systemUptime - lastRead))
        let revision = generation
        pending = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, !Task.isCancelled, revision == generation else { return }
            pending = nil
            beginRead(pid: pid, revision: revision)
        }
    }
    func setSuspended(_ value: Bool) {
        suspended = value
        reconcile()
    }
    func stop() { endObservation(); cursorPID = nil; publish(enabled ? .unavailable : .disabled) }

    private func publish(_ value: CursorModelSelection) {
        if selection != value { selection = value }
    }
    private func reconcile() {
        guard allowsInspection, enabled else { endObservation(); publish(.disabled); return }
        guard trusted() else { endObservation(); publish(.permissionRequired); return }
        guard !suspended, let pid = cursorPID, foregroundPID() == pid else {
            endObservation(); publish(.unavailable); return
        }
        guard fallback == nil else { signalChange(); return }
        publish(.unavailable)
        installObserver(pid: pid)
        signalChange()
        fallback = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard !Task.isCancelled else { return }
                self?.signalChange()
            }
        }
    }
    private func beginRead(pid: Int32, revision: Int) {
        guard reading == nil, enabled, !suspended, foregroundPID() == pid else { return }
        lastRead = ProcessInfo.processInfo.systemUptime
        let reader = read
        let webReader = readWeb, chrome = inspectingChrome
        reading = Task { [weak self] in
            let web = chrome ? await webReader(pid) : CursorWebObservation.unavailable
            let result = chrome ? web.selection : await reader(pid)
            guard let self, !Task.isCancelled, revision == generation, cursorPID == pid,
                  enabled, !suspended, foregroundPID() == pid else { return }
            reading = nil; observedAt = clock()
            webObservation = web
            publish(result)
        }
    }
    private func installObserver(pid: Int32) {
        var candidate: AXObserver?
        guard AXObserverCreate(pid, { _, _, _, context in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<CursorModelMonitor>.fromOpaque(context).takeUnretainedValue().signalChange()
            }
        }, &candidate) == .success, let candidate else { return }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.06)
        for name in [kAXFocusedWindowChangedNotification, kAXFocusedUIElementChangedNotification,
                     kAXSelectedChildrenChangedNotification, kAXValueChangedNotification, kAXTitleChangedNotification] {
            AXObserverAddNotification(candidate, application, name as CFString, Unmanaged.passUnretained(self).toOpaque())
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(candidate), .commonModes)
        observer = candidate
    }
    private func endObservation() {
        webObservation = .unavailable
        generation += 1
        fallback?.cancel(); fallback = nil
        pending?.cancel(); pending = nil
        reading?.cancel(); reading = nil
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil
    }
    isolated deinit {
        fallback?.cancel(); pending?.cancel(); reading?.cancel()
        for token in powerObservers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
    }
}

/// The only native adapter: selected window only, no actions, no value/text
/// extraction, no new browser, disk, account credentials or network access.
actor CursorModelAXReader {
    static let shared = CursorModelAXReader()
    func read(pid: Int32) async -> CursorModelSelection {
        guard !Task.isCancelled else { return .unavailable }
        guard AXIsProcessTrusted() else { return .permissionRequired }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(180))
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.06)
        guard let window = element(application, kAXFocusedWindowAttribute) else { return .unavailable }
        let focused = element(application, kAXFocusedUIElementAttribute)
        let result = CursorModelSelector.read(NativeCursorModelTree(), window: window, focused: focused) {
            !Task.isCancelled && ContinuousClock.now < deadline
        }
        guard !Task.isCancelled, let current = element(application, kAXFocusedWindowAttribute), CFEqual(window, current) else { return .unavailable }
        return result
    }
    func readWeb(pid: Int32) async -> CursorWebObservation {
        guard !Task.isCancelled, AXIsProcessTrusted(),
              NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.google.Chrome" else { return .unavailable }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(180))
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.06)
        guard let window = element(application, kAXFocusedWindowAttribute) else { return .unavailable }
        let focused = element(application, kAXFocusedUIElementAttribute)
        let result = CursorWebSelector.read(NativeCursorModelTree(), window: window, focused: focused) {
            !Task.isCancelled && ContinuousClock.now < deadline
        }
        guard !Task.isCancelled, let current = element(application, kAXFocusedWindowAttribute), CFEqual(window, current) else { return .unavailable }
        return result
    }
    private func element(_ root: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}

struct NativeCursorModelTree: CursorModelTree {
    func same(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool { CFEqual(lhs, rhs) }
    func parent(_ element: AXUIElement) -> AXUIElement? {
        AXUIElementSetMessagingTimeout(element, 0.06)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    func string(_ element: AXUIElement, _ attribute: CursorModelAttribute) -> String? {
        // Apple's timeout is per object; setting it only on the application
        // does NOT constrain child AX objects (AXUIElement.h).
        AXUIElementSetMessagingTimeout(element, 0.06)
        let key: String
        switch attribute { case .role: key = kAXRoleAttribute; case .title: key = kAXTitleAttribute
        case .description: key = kAXDescriptionAttribute; case .url: key = kAXURLAttribute }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        if attribute == .url, let url = value as? URL { return url.absoluteString }
        guard let text = value as? String, text.utf8.count <= (attribute == .url ? 1024 : 96) else { return nil }
        return text
    }
    func children(_ element: AXUIElement) -> [AXUIElement]? {
        AXUIElementSetMessagingTimeout(element, 0.06)
        var count: CFIndex = 0
        let result = AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count)
        if result == .attributeUnsupported || result == .noValue { return [] }
        guard result == .success, count <= 64 else { return nil }
        if count == 0 { return [] }
        var values: CFArray?
        guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, count, &values) == .success else { return nil }
        return values as? [AXUIElement]
    }
}
