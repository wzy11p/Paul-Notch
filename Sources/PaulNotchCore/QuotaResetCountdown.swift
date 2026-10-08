import Foundation

/// The compact notch prefix is a countdown to the reported reset, not the
/// length of the quota window. Unknown or expired reset times stay unknown.
enum QuotaResetCountdown {
    static func shortLabel(
        windowDurationMinutes: Int?,
        resetsAt: Date?,
        at now: Date
    ) -> String {
        let unit: TimeInterval
        let suffix: String
        switch windowDurationMinutes {
        case 10_080:
            unit = 86_400
            suffix = "D"
        case 300:
            unit = 3_600
            suffix = "H"
        default:
            return "Q"
        }

        guard let resetsAt, let windowDurationMinutes else { return "—" }
        let remaining = resetsAt.timeIntervalSince(now)
        let windowSeconds = TimeInterval(windowDurationMinutes) * 60
        // Allow one minute of clock skew; never let a bad timestamp widen the
        // hardware-attached shelf with an unbounded countdown.
        guard remaining.isFinite, remaining > 0, remaining <= windowSeconds + 60 else {
            return "—"
        }
        guard remaining >= unit else { return "<1\(suffix)" }
        return "\(Int(ceil(min(remaining, windowSeconds) / unit)))\(suffix)"
    }
}
