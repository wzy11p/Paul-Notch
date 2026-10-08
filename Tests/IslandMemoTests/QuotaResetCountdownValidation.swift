import Foundation

@main
struct QuotaResetCountdownValidation {
    static func main() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        func label(_ duration: Int?, _ remaining: TimeInterval?) -> String {
            QuotaResetCountdown.shortLabel(
                windowDurationMinutes: duration,
                resetsAt: remaining.map { now.addingTimeInterval($0) },
                at: now
            )
        }

        // If these use elapsed rather than remaining time, or round down, the
        // label incorrectly loses a day/hour before the interval has ended.
        precondition(label(10_080, 7 * 86_400) == "7D")
        precondition(label(10_080, 7 * 86_400 + 30) == "7D")
        precondition(label(10_080, 6 * 86_400 + 23 * 3_600) == "7D")
        precondition(label(10_080, 6 * 86_400) == "6D")
        precondition(label(10_080, 86_400) == "1D")
        precondition(label(10_080, 86_399) == "<1D")
        precondition(label(300, 5 * 3_600) == "5H")
        precondition(label(300, 4 * 3_600 + 59 * 60) == "5H")
        precondition(label(300, 3_600) == "1H")
        precondition(label(300, 3_599) == "<1H")

        // Missing, expired and implausible reset timestamps must not pretend
        // to be a real seven-day or five-hour countdown.
        precondition(label(10_080, nil) == "—")
        precondition(label(300, nil) == "—")
        precondition(label(10_080, 0) == "—")
        precondition(label(300, -1) == "—")
        precondition(label(10_080, 8 * 86_400) == "—")
        precondition(label(300, 6 * 3_600) == "—")

        // Other future quota windows retain the existing neutral marker.
        precondition(label(nil, 3_600) == "Q")
        precondition(label(1_440, 3_600) == "Q")

        print("PASS: reset-bound weekly/hourly labels, sub-unit and unavailable boundaries")
    }
}
