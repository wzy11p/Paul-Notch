import AppKit
import SwiftUI

/// One native, nonactivating reminder, not another browser or account poller.
@MainActor final class QuotaResetReminderController: NSObject {
    private let defaults: UserDefaults
    private let inputs: (Date) -> ([QuotaResetWindow], QuotaResetFeed?)
    private var ledger: QuotaResetReminderLedger
    private var savedLedger: Data?
    private var panel: ReminderPanel?
    private var hostingView: NSHostingView<QuotaResetReminderView>?
    private var current: QuotaResetReminder?
    private var displayedMinute: Int?
    private var displayedCount = 0
    private var updateTask: Task<Void, Never>?
    private var sessionAvailable = true
    private var demonstration: QuotaResetReminder?
    var isSuppressed = false {
        didSet {
            if isSuppressed { panel?.orderOut(nil) }
            else { requestUpdate() }
        }
    }
    private static let ledgerKey = "quota.reset-reminders.ledger.v1"

    init(defaults: UserDefaults, inputs: @escaping (Date) -> ([QuotaResetWindow], QuotaResetFeed?)) {
        self.defaults = defaults; self.inputs = inputs
        let saved = defaults.data(forKey: Self.ledgerKey)
        self.savedLedger = saved
        self.ledger = saved.flatMap { try? JSONDecoder().decode(QuotaResetReminderLedger.self, from: $0) } ?? .init()
        super.init()
    }

    func start() {
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: QuotaNoticeTime.settingsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(showTest), name: QuotaNoticeTime.testRequested, object: nil)
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            center.addObserver(self, selector: #selector(suspend), name: name, object: nil)
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            center.addObserver(self, selector: #selector(resume), name: name, object: nil)
        }
        requestUpdate()
    }
    func stop() {
        updateTask?.cancel(); updateTask = nil
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        panel?.orderOut(nil); panel = nil; hostingView = nil
    }
    func requestUpdate() {
        guard updateTask == nil else { return }
        updateTask = Task { @MainActor [weak self] in
            // Published notifications precede mutation. Coalesce them onto the next turn.
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            updateTask = nil
            evaluate(now: Date())
        }
    }
    @objc private func settingsChanged() { demonstration = nil; requestUpdate() }
    @objc private func suspend() { sessionAvailable = false; panel?.orderOut(nil) }
    @objc private func resume() { sessionAvailable = true; requestUpdate() }
    @objc func showTest() {
        let now = Date()
        demonstration = .init(id: "test", title: "测试提醒 · Codex 每周额度", summary: "这是一条展示用提醒，不代表你的真实额度或重置公告。",
            evidence: "实际提醒会显示账户返回的时间或公告原帖，并标明确定程度。", resetAt: now.addingTimeInterval(86_400),
            expiresAt: now.addingTimeInterval(600), sourceURL: nil, isTest: true)
        requestUpdate()
    }
    private func evaluate(now: Date) {
        let enabled = defaults.object(forKey: QuotaNoticeTime.reminderEnabledKey) as? Bool ?? true
        guard sessionAvailable, !isSuppressed, enabled || demonstration != nil else { panel?.orderOut(nil); current = nil; return }
        if let demonstration, demonstration.expiresAt <= now { self.demonstration = nil }
        let (windows, feed) = inputs(now)
        let pending = enabled ? ledger.evaluate(windows: windows, feed: feed, now: now) : []
        persist()
        guard let notice = demonstration ?? pending.first else { panel?.orderOut(nil); current = nil; return }
        let wasHidden = panel?.isVisible != true
        let minute = Int(now.timeIntervalSince1970 / 60)
        if !wasHidden && current == notice && displayedMinute == minute && displayedCount == pending.count { return }
        current = notice
        displayedMinute = minute; displayedCount = pending.count
        if panel == nil {
            let window = ReminderPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 292),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.isOpaque = false; window.backgroundColor = .clear
            window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.hidesOnDeactivate = false; window.hasShadow = true
            window.isMovableByWindowBackground = true
            window.title = "Paul Notch · 重置提醒"
            window.setAccessibilityIdentifier("quota-reset-reminder")
            panel = window
        }
        let width: CGFloat = min(420, (NSScreen.main?.visibleFrame.width ?? 460) - 40)
        let view = QuotaResetReminderView(notice: notice, count: pending.count, now: now, width: width,
            acknowledge: { [weak self] in self?.resolve(notice, snooze: false) },
            snooze: { [weak self] in self?.resolve(notice, snooze: true) })
        let host: NSHostingView<QuotaResetReminderView>
        if let hostingView { host = hostingView; host.rootView = view }
        else { host = NSHostingView(rootView: view); hostingView = host; panel?.contentView = host }
        host.frame = NSRect(x: 0, y: 0, width: width, height: 340)
        let height = max(260, host.fittingSize.height)
        panel?.setContentSize(NSSize(width: width, height: height))
        if wasHidden, let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel?.setFrameOrigin(NSPoint(x: frame.maxX - width - 20, y: max(frame.minY, frame.maxY - height - 20)))
            // Does not activate Paul, take the key window, or depend on notification permission/DND.
            panel?.orderFrontRegardless()
        }
    }
    private func resolve(_ notice: QuotaResetReminder, snooze: Bool) {
        if notice.isTest { demonstration = nil }
        else if snooze { ledger.snooze(notice, now: Date()) }
        else { ledger.acknowledge(notice, now: Date()) }
        persist(); requestUpdate()
    }
    private func persist() {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(ledger), data != savedLedger else { return }
        defaults.set(data, forKey: Self.ledgerKey); savedLedger = data
    }
}

private final class ReminderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct QuotaResetReminderView: View {
    let notice: QuotaResetReminder
    let count: Int
    let now: Date
    var width: CGFloat = 420
    let acknowledge, snooze: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(notice.isTest ? "测试 · 不是真实公告" : "Paul Notch · 重置提醒", systemImage: "bell.badge.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.orange)
                Spacer(minLength: 4)
                if count > 1 { Text("\(count) 条待确认").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            Text(verbatim: notice.title).font(.system(size: 17, weight: .semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            if let reset = notice.resetAt {
                Text(QuotaNoticeTime.remaining(until: reset, now: now)).font(.system(size: 26, weight: .semibold)).monospacedDigit()
                Text(QuotaNoticeTime.beijing(reset)).font(.system(size: 14, weight: .medium))
            } else {
                Text("请核对最新公告").font(.system(size: 24, weight: .semibold))
            }
            Text(verbatim: notice.summary).font(.system(size: 12)).lineLimit(4).fixedSize(horizontal: false, vertical: true)
            Text(verbatim: notice.evidence).font(.system(size: 11)).foregroundStyle(Color(white: 0.72)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if let source = notice.sourceURL { Link("查看原帖", destination: source).font(.system(size: 12)) }
                Spacer(minLength: 0)
                Button("稍后提醒", action: snooze).accessibilityIdentifier("reset-reminder-snooze")
                Button("知道了", action: acknowledge).buttonStyle(.borderedProminent).accessibilityIdentifier("reset-reminder-ack")
            }.controlSize(.large)
        }
        .foregroundStyle(Color(white: 0.96)).padding(22).frame(width: width, alignment: .leading)
        .background(Color(white: 0.17), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
        .environment(\.colorScheme, .dark)
    }
}
