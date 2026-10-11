import Foundation
#if !DIRECT_MODEL_TEST
@testable import PaulNotchCore
#endif

private actor ModelReadFixture {
    var calls = 0
    var label = "Claude Opus 5.5"
    var delay: UInt64 = 0
    var isCursorPage = true
    func configure(_ label: String, delay: UInt64 = 0) { self.label = label; self.delay = delay }
    func navigate(cursorPage: Bool) { isCursorPage = cursorPage }
    func readWeb(_ pid: Int32) async -> CursorWebObservation {
        let page = isCursorPage
        let selection = await read(pid)
        return page ? .init(isCursorPage: true, selection: selection) : .unavailable
    }
    func read(_ pid: Int32) async -> CursorModelSelection {
        calls += 1
        let captured = label, pause = delay
        if pause > 0 { try? await Task.sleep(nanoseconds: pause) }
        return CursorModelSelection.parse(captured) ?? .unavailable
    }
}
@MainActor private final class ModelForegroundFixture { var pid: Int32?; var trusted = true }

@main struct CursorModelMonitorValidation {
    @MainActor static func main() async throws {
        var failures = 0
        func check(_ value: Bool, _ why: String) { if !value { failures += 1; print("FAIL: \(why)") } }
        let suite = "local.paul.test.model.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = ModelReadFixture(), foreground = ModelForegroundFixture()
        let monitor = CursorModelMonitor(defaults: defaults, allowsInspection: true,
            foregroundPID: { foreground.pid }, trusted: { foreground.trusted }, read: { await source.read($0) },
            readWeb: { await source.readWeb($0) })
        defer { monitor.stop() }
        monitor.setEnabled(true)
        monitor.observeForeground(bundleIdentifier: "com.apple.finder", pid: 999999)
        try await Task.sleep(for: .milliseconds(250))
        check(await source.calls == 0 && !monitor.isMonitoring, "ordinary apps incur no model reads or polling")
        foreground.pid = 999999
        monitor.observeForeground(bundleIdentifier: "com.todesktop.230313mzl4w4u92", pid: 999999)
        try await Task.sleep(for: .milliseconds(400))
        check(monitor.selection.pool == .other && monitor.isMonitoring, "Cursor activation reads the current selector")
        let beforeActivations = await source.calls
        for _ in 0..<8 {
            foreground.pid = nil
            monitor.observeForeground(bundleIdentifier: "com.apple.finder", pid: 999998)
            foreground.pid = 999999
            monitor.observeForeground(bundleIdentifier: "com.todesktop.230313mzl4w4u92", pid: 999999)
            try await Task.sleep(for: .milliseconds(50))
        }
        check(await source.calls <= beforeActivations + 1, "rapid leave/return must share the same read throttle")
        let initial = await source.calls
        await source.configure("Grok 4.7")
        for _ in 0..<100 { monitor.signalChange() }
        try await Task.sleep(for: .milliseconds(1100))
        check(monitor.selection.pool == .cursor, "model event updates the context")
        check(await source.calls <= initial + 2, "event storms coalesce instead of creating a read for each event")
        await source.configure("Auto")
        let beforeFallback = await source.calls
        try await Task.sleep(for: .milliseconds(5300))
        let afterFallback = await source.calls
        check(monitor.selection == .automatic && afterFallback == beforeFallback + 1,
              "missed native events recover through one foreground-only fallback, not high frequency polling")
        await source.configure("Grok 4.7")
        monitor.setSuspended(true)
        let beforeSleep = await source.calls
        try await Task.sleep(for: .milliseconds(750))
        check(await source.calls == beforeSleep && !monitor.isMonitoring && monitor.selection.pool == nil, "sleep releases observation and clears active attribution")
        monitor.setSuspended(false)
        try await Task.sleep(for: .milliseconds(1100))
        check(monitor.selection.pool == .cursor, "wake reacquires the foreground selection")
        await source.configure("Claude Opus 5.5", delay: 1_000_000_000)
        monitor.signalChange()
        try await Task.sleep(for: .milliseconds(850))
        foreground.pid = nil
        monitor.observeForeground(bundleIdentifier: "com.openai.codex", pid: 999998)
        try await Task.sleep(for: .milliseconds(1100))
        check(monitor.selection.pool == nil && !monitor.isMonitoring, "late previous-window result cannot republish after foreground changes")
        await source.configure("Grok 4.7")
        foreground.pid = 999999; foreground.trusted = false
        let beforePermission = await source.calls
        monitor.observeForeground(bundleIdentifier: "com.todesktop.230313mzl4w4u92", pid: 999999)
        try await Task.sleep(for: .milliseconds(250))
        let afterPermission = await source.calls
        check(monitor.selection == .permissionRequired && !monitor.isMonitoring && afterPermission == beforePermission,
              "missing permission performs no reads and no repeated prompt/poll")
        foreground.pid = nil
        monitor.observeForeground(bundleIdentifier: "local.paul.notch", pid: 999997)
        check(monitor.selection == .permissionRequired && !monitor.isMonitoring,
              "permission recovery entry remains visible when the user returns to Paul settings")
        foreground.pid = 999999
        foreground.trusted = true
        monitor.observeForeground(bundleIdentifier: "com.todesktop.230313mzl4w4u92", pid: 999999)
        try await Task.sleep(for: .milliseconds(400))
        check(monitor.selection.pool == .cursor, "permission recovery needs no account re-login")
        monitor.observeForeground(bundleIdentifier: "com.google.Chrome", pid: 999999)
        try await Task.sleep(for: .milliseconds(1100))
        check(monitor.isMonitoring && monitor.selection.pool == .cursor,
              "Chrome foreground must inspect the verified Cursor web composer instead of retaining Codex")
        check(monitor.recognizesCursorWeb(at: .now), "fresh official web capture can override the last desktop service")
        check(!monitor.recognizesCursorWeb(at: Date().addingTimeInterval(13)), "expired browser capture cannot keep selecting Cursor")
        await source.navigate(cursorPage: false)
        monitor.signalChange()
        try await Task.sleep(for: .milliseconds(1100))
        check(!monitor.recognizesCursorWeb(at: .now) && monitor.selection == .unavailable,
              "a different tab in the same Chrome process clears official-page and model attribution")
        await source.navigate(cursorPage: true)
        await source.configure("Claude Sonnet 5.5 High", delay: 1_000_000_000)
        monitor.signalChange()
        try await Task.sleep(for: .milliseconds(850))
        foreground.pid = nil
        monitor.observeForeground(bundleIdentifier: "com.openai.codex", pid: 999998)
        try await Task.sleep(for: .milliseconds(1100))
        check(!monitor.recognizesCursorWeb(at: .now) && monitor.selection.pool == nil,
              "a delayed Chrome capture cannot overwrite a newly foreground desktop app")
        foreground.pid = 999999
        await source.configure("Grok 4.7")
        monitor.observeForeground(bundleIdentifier: "com.google.Chrome", pid: 999999)
        try await Task.sleep(for: .milliseconds(1100))
        foreground.pid = nil
        check(!monitor.recognizesCursorWeb(at: .now), "foreground PID change invalidates the web override even before a notification")
        foreground.pid = 999999
        monitor.setSuspended(true)
        check(!monitor.recognizesCursorWeb(at: .now), "sleep clears browser attribution")
        monitor.setSuspended(false)
        monitor.setEnabled(false)
        let stopped = await source.calls
        monitor.signalChange()
        try await Task.sleep(for: .milliseconds(5300))
        check(await source.calls == stopped && !monitor.isMonitoring && monitor.selection == .disabled,
              "turning off follow stops work without deleting balances or credentials")
        let blocked = CursorModelMonitor(defaults: defaults, allowsInspection: false,
            foregroundPID: { foreground.pid }, trusted: { true }, read: { await source.read($0) })
        blocked.setEnabled(true)
        blocked.observeForeground(bundleIdentifier: "com.todesktop.230313mzl4w4u92", pid: 999999)
        try await Task.sleep(for: .milliseconds(250))
        check(await source.calls == stopped && !blocked.isMonitoring, "disposable previews cannot activate native inspection")
        blocked.stop()
        check(defaults.persistentDomain(forName: suite)?.values.allSatisfy { $0 is Bool } == true,
              "model labels, window identifiers and history are not persisted")
        guard failures == 0 else { exit(1) }
        print("PASS: foreground-only reads, event coalescing, sleep/wake, late results, permission/off/preview gates and bounded persistence")
    }
}
