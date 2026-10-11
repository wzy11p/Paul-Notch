import Foundation

/// Input references canonical snapshots only; this feature owns no account client.
struct QuotaResetWindow {
    let id, service, pool, remainder: String
    let resetAt: Date
    var observedAt: Date
    let isCurrent: Bool
    var duration: TimeInterval? = nil
}

struct QuotaResetReminder: Equatable, Identifiable {
    let id, title, summary, evidence: String
    let resetAt: Date?
    let expiresAt: Date
    let sourceURL: URL?
    var isTest = false
}

/// Only acknowledgement IDs and snooze dates persist, never credentials or quota values.
struct QuotaResetReminderLedger: Codable {
    private var acknowledged: [String: Date] = [:]
    private var snoozed: [String: Date] = [:]
    private var hasFeedBaseline = false

    mutating func evaluate(windows: [QuotaResetWindow], feed: QuotaResetFeed?, now: Date) -> [QuotaResetReminder] {
        acknowledged = acknowledged.filter { now.timeIntervalSince($0.value) < 31 * 86_400 }
        snoozed = snoozed.filter { $0.value > now }
        var candidates: [QuotaResetReminder] = []
        for window in windows {
            let age = now.timeIntervalSince(window.observedAt), remaining = window.resetAt.timeIntervalSince(now)
            guard window.isCurrent, (-60...90).contains(age), remaining > 0, remaining <= 86_400 else { continue }
            let phase: String
            if remaining <= 3600 { phase = "1h" }
            else if (window.duration ?? 86_400) >= 86_400 { phase = "24h" }
            else { continue }
            candidates.append(.init(id: "account:\(window.id):\(Int(window.resetAt.timeIntervalSince1970)):\(phase)",
                title: "\(window.service) · \(window.pool) 即将重置",
                summary: "当前剩余 \(window.remainder)。可优先安排这个额度内的任务；无需为了清零额外消耗。",
                evidence: "你的账户返回的重置时间；不代表额度已经到账。",
                resetAt: window.resetAt, expiresAt: window.resetAt, sourceURL: nil))
        }
        if let feed {
            for event in feed.events {
                let publicID = "news:\(event.id):\(event.status):\(Int(event.updatedAt.timeIntervalSince1970))"
                let isUpcoming = event.announcedResetAt.map { $0 > now && $0.timeIntervalSince(now) <= 86_400 } == true
                // Record the historical baseline, but do not hide an actionable upcoming schedule.
                if !hasFeedBaseline && !isUpcoming { acknowledged[publicID] = now }
                guard event.isOriginalSource, ["direct_reset", "reset_credit"].contains(event.type),
                      ["announced", "in_progress", "confirmed"].contains(event.status),
                      event.confirmationBasis != "receipt_review", event.updatedAt <= now.addingTimeInterval(60),
                      isUpcoming || now.timeIntervalSince(event.updatedAt) < 2 * 86_400 else { continue }
                let exactFuture = event.announcedResetAt.flatMap { $0 > now ? $0 : nil }
                let scope = event.scopeKnown ? (event.audience ?? "范围见原帖") : "适用账户范围尚未确认"
                let scheduledPhase = isUpcoming ? ":24h" : ""
                candidates.append(.init(id: publicID + scheduledPhase, title: "Codex 公告 · \(event.title)",
                    summary: "\(event.typeLabel) · \(scope)。\(event.status == "confirmed" ? "先核对账户实际额度，不把公告当作到账凭据。" : "\(event.timingLabel)。")",
                    evidence: "AIHOT 转录 Tibo 原帖 · \(event.statusLabel)。\(feed.monitorStatus == "healthy" ? "" : "上游核验可能延迟。")",
                    resetAt: exactFuture, expiresAt: exactFuture ?? event.updatedAt.addingTimeInterval(2 * 86_400), sourceURL: event.sourceURL))
                // Distinct time checkpoint survives an earlier acknowledgement of the announcement.
                if let reset = exactFuture, reset.timeIntervalSince(now) <= 3600 {
                    candidates.removeLast()
                    candidates.append(.init(id: publicID + ":1h", title: "Codex 公告预定 · \(event.title)",
                        summary: "\(scope)。这是原帖预定时间，实际是否重置以账户返回为准。",
                        evidence: "AIHOT 转录 Tibo 原帖，不是个人账户的保证。", resetAt: reset, expiresAt: reset, sourceURL: event.sourceURL))
                }
            }
            hasFeedBaseline = true
        }
        // Bound local state even if the upstream changes identifiers repeatedly.
        if acknowledged.count > 512 { acknowledged = Dictionary(uniqueKeysWithValues: acknowledged.sorted { $0.value > $1.value }.prefix(512).map { ($0.key, $0.value) }) }
        return candidates.filter { acknowledged[$0.id] == nil && snoozed[$0.id] == nil && $0.expiresAt > now }
            .sorted { ($0.resetAt ?? .distantFuture, $0.id) < ($1.resetAt ?? .distantFuture, $1.id) }
    }

    mutating func acknowledge(_ reminder: QuotaResetReminder, now: Date) {
        acknowledged[reminder.id] = now; snoozed[reminder.id] = nil
    }
    mutating func snooze(_ reminder: QuotaResetReminder, now: Date) {
        snoozed[reminder.id] = now.addingTimeInterval(max(30, min(1800, reminder.expiresAt.timeIntervalSince(now) / 2)))
    }
}
