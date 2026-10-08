import Foundation
@testable import PaulNotchCore

@main struct AmbientServiceValidation {
    @MainActor static func main() throws {
        var failures = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures += 1; print("FAIL: \(message)") }
        }
        var selection = AmbientServiceSelection()
        for (bundle, expected) in [
            ("com.anysphere.sand", AmbientQuotaService.grok),
            ("com.work.pc.doubao", .doubao),
            ("com.work.pc.doubao.browser", .doubao),
            ("com.todesktop.230313mzl4w4u92", .cursor),
            ("com.openai.codex", .codex)
        ] {
            selection.observe(bundleIdentifier: bundle)
            check(selection.service == expected, "A supported foreground app must select its own account")
        }
        selection.observe(bundleIdentifier: "com.work.pc.doubao")
        for bundle in [nil, "", "com.apple.finder", "com.google.Chrome", "local.paul.home-preview-20260905",
                       "com.anysphere.sand.evil", "not-codex", "com.openai.chat"] as [String?] {
            selection.observe(bundleIdentifier: bundle)
            check(selection.service == .doubao, "Ordinary/own/unknown apps cannot erase or spoof the last AI service")
        }
        selection.observe(bundleIdentifier: "com.meta.endo")
        check(selection.service.rawValue == "muse", "Foreground Meta Muse must not leave the shelf displaying another account's quota")
        check(AmbientQuotaService.matching(bundleIdentifier: "com.meta.endo.evil") == nil,
              "Muse identification must use the exact installed Bundle ID")

        let now = Date(timeIntervalSince1970: 1_791_000_000)
        if let service = AmbientQuotaService.matching(bundleIdentifier: "com.meta.endo"),
           let muse = QuotaHomePresentation.accounts(snapshot: nil, error: nil, readsEnabled: false, now: now)
            .first(where: { $0.id == "muse" }) {
            let presentation = AmbientQuotaPresentation.make(service: service, account: muse,
                tasksAreFresh: true, runningTaskCount: 12, at: now)
            check(presentation.lines.isEmpty && presentation.activity == .notAvailable,
                  "Until Muse has its own verified source, neither quota nor Codex's task count can be borrowed")
        }
        func account(_ service: AmbientQuotaService, value: QuotaOverviewValue = .percent(73),
                     status: QuotaOverviewStatus = .current, timing: String = "官方未提供重置时间") -> QuotaOverviewAccount {
            .init(id: service.rawValue, name: service.name, account: "synthetic membership", group: .membership,
                  value: value, timing: timing, status: status)
        }
        let weekly = CodexQuotaWindow(id: "codex:secondary", limitID: "codex", limitName: nil,
            windowName: "week", usedPercent: 3, windowDurationMinutes: 10080, resetsAt: now.addingTimeInterval(2 * 86400))
        let short = CodexQuotaWindow(id: "codex:primary", limitID: "codex", limitName: nil,
            windowName: "short", usedPercent: 22, windowDurationMinutes: 300, resetsAt: now.addingTimeInterval(2 * 3600))
        let codex = AmbientQuotaPresentation.make(service: .codex, account: account(.codex),
            codexWindows: [short, weekly], tasksAreFresh: true, runningTaskCount: 12, at: now)
        check(codex.lines.map(\.value) == [.percent(97), .percent(78)] && codex.lines.map(\.period) == ["2D", "2H"],
              "Codex keeps its independent real windows and their own countdowns, weekly first")
        check(codex.activity == .running(12) && codex.activity.displayCount == "9+",
              "Only a fresh Codex task source produces a bounded running count")

        let cursor = AmbientQuotaPresentation.make(service: .cursor, account: account(.cursor, value: .percent(81)),
            resetsAt: now.addingTimeInterval(28 * 86400), tasksAreFresh: true, runningTaskCount: 12, at: now)
        check(cursor.lines.map(\.value) == [.percent(81)] && cursor.lines.first?.period == "28D",
              "Cursor's month countdown and primary pool must not inherit Codex's week/short pool")
        check(cursor.activity == .notAvailable && !cursor.summary.contains("12 个") && !cursor.activity.isWorking,
              "Cursor refresh/foreground does not mean twelve Codex tasks are running in Cursor")
        let grok = AmbientQuotaPresentation.make(service: .grok, account: account(.grok, value: .percent(0)),
            resetsAt: now.addingTimeInterval(3 * 86400), at: now)
        check(grok.lines.first?.value == .percent(0) && grok.lines.first?.period == "3D",
              "A true exhausted Grok quota stays zero and retains Grok's own reset")
        let doubao = AmbientQuotaPresentation.make(service: .doubao,
            account: account(.doubao, value: .percentBound(lowerExclusive: 99, upperInclusive: 100), timing: "2 小时 1 分钟后重置"),
            observedAt: now.addingTimeInterval(-60), at: now)
        check(doubao.lines.first?.value == .percentBound(lowerExclusive: 99, upperInclusive: 100) && doubao.lines.first?.period == "2H",
              "Official less-than-one usage stays a bound and countdown ages from the observation, not every render")
        let unstarted = AmbientQuotaPresentation.make(service: .doubao,
            account: account(.doubao, value: .unlimited, timing: "开始使用后计时"), observedAt: now, at: now)
        check(unstarted.lines.first?.period == "待用" && unstarted.lines.first?.value == .unlimited,
              "An unstarted/unlimited official window is not an invented percentage or reset date")
        for timing in ["官方未提供重置时间", "明天应该重置", "10月6日 12:00 重置", "999999 天后重置", "-2 小时后重置"] {
            let unknown = AmbientQuotaPresentation.make(service: .doubao,
                account: account(.doubao, timing: timing), observedAt: now, at: now)
            check(unknown.lines.first?.period == "—", "Unknown/ambiguous/unbounded timing must stay unknown")
        }
        for service in AmbientQuotaService.allCases {
            for status in [QuotaOverviewStatus.stale, .unavailable, .notConnected, .sample] {
                let state = AmbientQuotaPresentation.make(service: service,
                    account: account(service, status: status), codexWindows: [weekly], tasksAreFresh: true,
                    runningTaskCount: 4, at: now)
                check(state.lines.isEmpty, "Old/error/unconnected/sample capacity cannot masquerade as current")
            }
            let wrong = AmbientQuotaPresentation.make(service: service,
                account: account(service == .codex ? .doubao : .codex), codexWindows: [weekly], at: now)
            check(wrong.lines.isEmpty, "A service must reject a different provider's account instead of silently borrowing it")
        }
        let expired = AmbientQuotaPresentation.make(service: .grok, account: account(.grok), resetsAt: now, at: now)
        check(expired.lines.isEmpty, "At reset time wait for a new provider read; don't show the old quota or invent 100%")
        let missing = AmbientQuotaPresentation.make(service: .cursor, account: account(.cursor, value: .unknown), at: now)
        check(missing.lines.isEmpty && missing.summary.contains("Cursor"), "Missing Cursor data stays visibly Cursor, not Codex or zero")
        let wallet = AmbientQuotaPresentation.make(service: .grok,
            account: account(.grok, value: .money(12, currency: "CNY")), at: now)
        check(wallet.lines.isEmpty, "A membership cannot be silently replaced by an API wallet with the same display identity")
        let oldObservation = AmbientQuotaPresentation.make(service: .doubao,
            account: account(.doubao), observedAt: now.addingTimeInterval(-91), at: now)
        check(oldObservation.lines.isEmpty, "An old observation cannot restart a fresh countdown on every render")
        let staleTasks = AmbientQuotaPresentation.make(service: .codex, account: account(.codex),
            codexWindows: [weekly], tasksAreFresh: false, runningTaskCount: 4, at: now)
        check(staleTasks.activity == .unknown && !staleTasks.activity.isWorking,
              "Stale task cache cannot continue a working animation")
        let idle = AmbientQuotaPresentation.make(service: .codex, account: account(.codex),
            codexWindows: [weekly], tasksAreFresh: true, runningTaskCount: 0, at: now)
        check(idle.activity == .idle, "Only fresh zero Codex tasks can mean idle")
        guard failures == 0 else { exit(1) }
        print("PASS: exact foreground identities, last-service retention, independent quota/reset windows, bounds, missing/stale/expiry gates and provider-scoped task status")
    }
}
