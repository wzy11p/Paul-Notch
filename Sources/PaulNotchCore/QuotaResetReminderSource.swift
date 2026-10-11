import Foundation

@MainActor enum QuotaResetReminderSource {
    static func inputs(codex: CodexStatusStore, connections: QuotaConnectionsStore, now: Date) -> ([QuotaResetWindow], QuotaResetFeed?) {
        var windows: [QuotaResetWindow] = []
        if AppEnvironment.codexStatusReadsEnabled, let snapshot = codex.quota {
            for window in snapshot.visibleWindows {
                guard let reset = window.resetsAt else { continue }
                windows.append(.init(id: "codex:\(window.id)", service: "Codex", pool: "\(window.shortName)额度",
                    remainder: "\(Int(window.remainingPercent.rounded(.down)))%", resetAt: reset,
                    observedAt: snapshot.observedAt, isCurrent: snapshot.freshness == .fresh && codex.quotaError == nil,
                    duration: window.windowDurationMinutes.map { TimeInterval($0) * 60 }))
            }
        }
        if let cursor = connections.cursorAccount, cursor.enabled, !cursor.needsAuthorization {
            for provider in [DesktopQuotaProvider.cursor, .grok] {
                guard let state = cursor.states[provider], let snapshot = state.snapshot, let reset = snapshot.resetsAt else { continue }
                let remainder = snapshot.pools.map { "\($0.name) \($0.remaining)%" }.joined(separator: " / ")
                windows.append(.init(id: provider.rawValue, service: provider.name,
                    pool: provider == .cursor ? "月度额度" : "每周额度", remainder: remainder,
                    resetAt: reset, observedAt: snapshot.observedAt, isCurrent: state.error == nil,
                    duration: provider == .cursor ? 30 * 86_400 : 7 * 86_400))
            }
        }
        for (id, membership) in connections.websiteMemberships {
            guard membership.enabled, let snapshot = membership.snapshot, snapshot.hasExactResetTime,
                  let reset = snapshot.resetsAt else { continue }
            // Date-only or relative website captions stay unknown: no invented timezone/hour.
            windows.append(.init(id: id, service: id == "muse" ? "Muse" : id == "doubao" ? "豆包工作" : "MiniMax Audio",
                pool: "会员额度", remainder: snapshot.value.text, resetAt: reset, observedAt: snapshot.observedAt,
                isCurrent: membership.error == nil && !membership.needsLogin))
        }
        var feed: QuotaResetFeed?
        if connections.feedEnabled, connections.feedError == nil,
           let retrieved = connections.feedRetrievedAt, (-60...660).contains(now.timeIntervalSince(retrieved)),
           let snapshot = connections.feedSnapshot,
           let collected = snapshot.collectedAt ?? snapshot.checkedAt,
           (-60...1800).contains(now.timeIntervalSince(collected)) { feed = snapshot }
        return (windows, feed)
    }
}
