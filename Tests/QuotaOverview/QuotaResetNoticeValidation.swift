import Foundation

@main struct QuotaResetNoticeValidation {
    static func main() throws {
        var failures = [String]()
        func check(_ value: Bool, _ message: String) {
            if !value { failures.append(message); print("FAIL: \(message)") }
        }
        let request = QuotaReadRequest.resetFeed(etag: "test")
        check(request.url?.path == "/api/v1/codex-resets/recent", "Poll the small recent feed, not the entire history")
        check(request.httpMethod == "GET" && request.httpBody == nil && request.value(forHTTPHeaderField: "Authorization") == nil,
              "Public notices never invoke a model or send account tokens")
        let payload = #"{"schemaVersion":1,"checkedAt":null,"monitor":{"status":"attention"},"events":[{"id":"test-reset","type":"direct_reset","status":"announced","title":"Reset","updatedAt":"2026-10-11T06:00:00Z","confirmationBasis":null,"schedule":{"precision":"exact","from":"2026-10-12T01:00:00-07:00","through":"2026-10-12T01:00:00-07:00","label":"source time"},"presentation":{"status":"announced","scopeKnown":true,"kindExplicit":true,"timeInferred":false,"audienceZh":"所有用户","productsZh":"Codex"},"posts":[{"text":"Explicit announcement fixture","url":"https://x.com/thsottiaux/status/123"}]}]}"#
        check((try? QuotaResetFeed.decode(Data(payload.utf8))) != nil, "A missing upstream verification watermark is valid but must not become a fresh verified timestamp")
        let event = try QuotaResetFeed.decode(Data(payload.utf8)).events[0]
        check(event.announcedResetAt != nil, "Only explicit, sourced exact announcements may have a public countdown")
        check(event.announcedResetAt.map(QuotaNoticeTime.beijing) == "北京时间 2026年10月12日 16:00", "Convert explicit PDT offset into Beijing date and time")
        let winter = ISO8601DateFormatter().date(from: "2026-12-31T23:30:00-08:00")!
        check(QuotaNoticeTime.beijing(winter) == "北京时间 2027年1月1日 15:30", "PST and year rollover do not use a fixed US offset")
        var uncertain = event; uncertain.timeInferred = true
        check(uncertain.announcedResetAt == nil, "Inferred time cannot drive a precise alert")
        uncertain = try QuotaResetFeed.decode(Data(payload.replacingOccurrences(of: "\"announced\"", with: "\"confirmed\"").utf8)).events[0]
        check(uncertain.announcedResetAt == nil && !uncertain.timingLabel.contains("16:00"), "A completed reset never counts down a retained future schedule")
        uncertain = event; uncertain.schedule = .init(precision: "deadline", from: winter, through: winter)
        check(uncertain.announcedResetAt == nil, "EOD deadline must not become an exact reset")
        uncertain = event; uncertain.scopeKnown = false
        check(uncertain.announcedResetAt == nil, "Unknown audience cannot imply a universal exact reset")
        let now = ISO8601DateFormatter().date(from: "2026-10-11T08:00:00Z")!
        let window = QuotaResetWindow(id: "codex:weekly", service: "Codex", pool: "每周额度", remainder: "73%", resetAt: now.addingTimeInterval(86_400), observedAt: now, isCurrent: true, duration: 604_800)
        var ledger = QuotaResetReminderLedger()
        var notices = ledger.evaluate(windows: [window], feed: nil, now: now)
        check(notices.count == 1 && notices[0].id.contains("24h"), "An account reset receives the 24-hour reminder without opening Home")
        ledger.acknowledge(notices[0], now: now)
        let saved = try JSONEncoder().encode(ledger)
        ledger = try JSONDecoder().decode(QuotaResetReminderLedger.self, from: saved)
        check(ledger.evaluate(windows: [window], feed: nil, now: now).isEmpty, "Acknowledgement survives restart")
        var later = window; later.observedAt = now.addingTimeInterval(83_000)
        notices = ledger.evaluate(windows: [later], feed: nil, now: later.observedAt)
        check(notices.count == 1 && notices[0].id.contains("1h"), "One-hour checkpoint remains after acknowledging one-day checkpoint")
        ledger.snooze(notices[0], now: later.observedAt)
        check(ledger.evaluate(windows: [later], feed: nil, now: later.observedAt.addingTimeInterval(20)).isEmpty, "Snooze suppresses repeated polling alerts")
        check(ledger.evaluate(windows: [window], feed: nil, now: now.addingTimeInterval(91)).isEmpty, "Stale quota cannot trigger a fresh urgency claim")
        later.observedAt = window.resetAt
        check(ledger.evaluate(windows: [later], feed: nil, now: window.resetAt).isEmpty, "Expired windows do not roll over or invent a reset")
        var short = window; short.duration = 18_000
        var shortLedger = QuotaResetReminderLedger()
        check(shortLedger.evaluate(windows: [short], feed: nil, now: now).isEmpty, "Short rolling limits do not generate a full-day alert every cycle")
        var feedLedger = QuotaResetReminderLedger()
        let baseline = QuotaResetFeed(events: [uncertain], checkedAt: now, monitorStatus: "healthy")
        check(feedLedger.evaluate(windows: [], feed: baseline, now: now).isEmpty, "Initial feed does not flood historical notices")
        let news = QuotaResetFeed.Event(id: "new-confirmation", type: event.type, status: "confirmed", title: event.title, text: event.text, confirmationBasis: "source_post", updatedAt: now, sourceURL: event.sourceURL, schedule: event.schedule)
        let changed = QuotaResetFeed(events: [news], checkedAt: now, monitorStatus: "attention")
        notices = feedLedger.evaluate(windows: [], feed: changed, now: now)
        check(notices.count == 1 && notices[0].resetAt == nil, "New confirmation alerts immediately but does not reuse the announced time")
        check(feedLedger.evaluate(windows: [], feed: .init(events: [], checkedAt: now, monitorStatus: "healthy"), now: now).isEmpty, "Withdrawal cancels an unacknowledged public alert")
        var exactLedger = QuotaResetReminderLedger()
        let exact = QuotaResetFeed(events: [event], checkedAt: now, monitorStatus: "healthy")
        check(exactLedger.evaluate(windows: [], feed: exact, now: now).first?.resetAt == event.announcedResetAt,
              "Already announced upcoming exact resets still alert on first connection")
        var longLedger = QuotaResetReminderLedger()
        let early = now.addingTimeInterval(-86_400)
        _ = longLedger.evaluate(windows: [], feed: exact, now: early)
        check(longLedger.evaluate(windows: [], feed: exact, now: now).first?.resetAt != nil,
              "A public announcement baselined days earlier still receives its 24-hour checkpoint")
        let oldAnnouncement = QuotaResetFeed.Event(id: "old-upcoming", type: event.type, status: event.status, title: event.title, text: event.text, confirmationBasis: nil,
            updatedAt: now.addingTimeInterval(-3 * 86_400), sourceURL: event.sourceURL, schedule: event.schedule,
            scopeKnown: true, kindExplicit: true, timeInferred: false)
        var oldLedger = QuotaResetReminderLedger()
        check(oldLedger.evaluate(windows: [], feed: .init(events: [oldAnnouncement], checkedAt: now, monitorStatus: "healthy"), now: now).count == 1,
              "A current upcoming schedule announced three days ago must not expire with news retention")
        guard failures.isEmpty else { exit(1) }
        print("PASS: reset notice source regressions")
    }
}
