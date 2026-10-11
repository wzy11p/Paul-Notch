import AppKit
import SwiftUI
@testable import PaulNotchCore

@main struct QuotaResetReminderNativeValidation {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let suite = "test.paul.reset-native.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        let dateOnly = try WebsiteQuotaParser.audio(amount: 10, reload: "2026-10-12", ends: nil, at: now)
        guard !dateOnly.hasExactResetTime else { fatalError("Date-only Audio caption cannot become a precise reset alarm") }
        let noZone = try WebsiteQuotaParser.audio(amount: 10, reload: "2026-10-12 10:00:00", ends: nil, at: now)
        guard !noZone.hasExactResetTime else { fatalError("Timezone-less Audio caption cannot become a precise reset alarm") }
        let exact = try WebsiteQuotaParser.audio(amount: 10, reload: "2026-10-12T01:00:00-07:00", ends: nil, at: now)
        guard exact.hasExactResetTime && exact.resetsAt.map(QuotaNoticeTime.beijing) == "北京时间 2026年10月12日 16:00" else { fatalError("Explicit Audio offset remains usable") }
        let notice = QuotaResetReminder(id: "fixture", title: "测试提醒 · Codex 每周额度即将重置", summary: "当前剩余 73%。可优先安排这个额度内的任务；无需为了清零额外消耗。", evidence: "示例数据，仅用于界面验证。正式提醒来自你的账户时间，不代表额度已经到账。", resetAt: now.addingTimeInterval(86_400), expiresAt: now.addingTimeInterval(86_400), sourceURL: nil, isTest: true)
        let view = QuotaResetReminderView(notice: notice, count: 1, now: now, acknowledge: {}, snooze: {})
        try await capture(view, width: 420, height: 330, file: output.appendingPathComponent("reset-reminder-native.png"))
        let back = HStack {
            Button(action: {}) { QuotaBackButtonLabel() }.buttonStyle(QuotaOverviewButtonStyle())
            Spacer()
        }.padding(20).frame(width: 280, height: 80).background(Color(white: 0.19)).environment(\.colorScheme, .dark)
        try await capture(back, width: 280, height: 80, file: output.appendingPathComponent("reset-back-native.png"))
        let label = NSHostingView(rootView: QuotaBackButtonLabel())
        guard label.fittingSize.width >= 98, label.fittingSize.height >= 32 else { fatalError("Back control must include its padding inside its styled bounds") }
        let controller = QuotaResetReminderController(defaults: defaults, inputs: { date in
            ([.init(id: "fixture", service: "测试 Codex", pool: "每周额度", remainder: "73%", resetAt: now.addingTimeInterval(86_400), observedAt: date, isCurrent: true, duration: 604_800)], nil)
        })
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        controller.start()
        try await Task.sleep(for: .milliseconds(200))
        guard let panel = NSApp.windows.first(where: { $0.accessibilityIdentifier() == "quota-reset-reminder" }), panel.isVisible else { fatalError("Reminder must appear without opening Home") }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost, !panel.isKeyWindow else { fatalError("Reminder must not activate or steal keyboard focus") }
        let firstHost = panel.contentView
        controller.requestUpdate()
        try await Task.sleep(for: .milliseconds(100))
        guard firstHost === panel.contentView else { fatalError("Repeated source updates must reuse the native host") }
        defaults.set(false, forKey: QuotaNoticeTime.reminderEnabledKey)
        NotificationCenter.default.post(name: QuotaNoticeTime.settingsChanged, object: nil)
        try await Task.sleep(for: .milliseconds(100))
        guard !panel.isVisible else { fatalError("Turning reminders off hides the panel") }
        controller.showTest()
        try await Task.sleep(for: .milliseconds(100))
        guard panel.isVisible else { fatalError("Explicit test works even when automatic reminders are disabled") }
        controller.isSuppressed = true
        guard !panel.isVisible else { fatalError("Presentation mode must hide reminders immediately") }
        controller.isSuppressed = false
        try await Task.sleep(for: .milliseconds(100))
        guard panel.isVisible else { fatalError("Leaving presentation mode restores pending reminder without marking it read") }
        controller.stop()
        guard !panel.isVisible else { fatalError("Stopping the owner closes the native reminder") }
        print("PASS: 98x32 padded back button, persistent native reminder, no focus steal, one reused host, disable/test/stop lifecycle")
    }
    @MainActor static func capture<V: View>(_ view: V, width: CGFloat, height: CGFloat, file: URL) async throws {
        let window = NSWindow(contentRect: NSRect(x: -9000, y: -9000, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: view)
        window.contentView = host; window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("Capture failed") }
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: file)
        window.orderOut(nil)
    }
}
