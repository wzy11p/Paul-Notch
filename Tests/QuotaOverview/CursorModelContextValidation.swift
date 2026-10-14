import Foundation
@testable import PaulNotchCore

@main struct CursorModelContextValidation {
    @MainActor static func main() throws {
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        let account = QuotaOverviewAccount(id: "cursor", name: "Cursor", account: "fixture",
            group: .membership, value: .percent(78), timing: "19 天后重置", status: .current,
            pools: [.init(label: "Cursor", value: .percent(78), timing: "19 天后重置"),
                    .init(label: "其他模型", value: .percent(43), timing: "19 天后重置")])
        let state = AmbientQuotaPresentation.make(service: .cursor, account: account,
            resetsAt: now.addingTimeInterval(19 * 86400), observedAt: now, at: now)
        var failures = 0
        func check(_ value: Bool, _ why: String) { if !value { failures += 1; print("FAIL: \(why)") } }
        check(state.lines.map(\.value) == [.percent(78), .percent(43)],
              "without a verified selected model retain both pools, never silently choose the first")
        for (name, values) in [("Claude Opus 5.5 1M Medium", [QuotaOverviewValue.percent(43)]),
                               ("Grok 4.7", [.percent(78)]),
                               ("Grok 4.7 Extra High Fast\u{200B}\u{200B}", [.percent(78)]),
                               ("Auto", [.percent(78), .percent(43)])] {
            let chosen = AmbientQuotaPresentation.make(service: .cursor, account: account,
                resetsAt: now.addingTimeInterval(19 * 86400), observedAt: now,
                cursorModel: CursorModelSelection.parse(name) ?? .unavailable, at: now)
            check(chosen.lines.map(\.value) == [.percent(78), .percent(43)],
                  "\(name) preserves both fixed pools rather than shrinking the reading")
            check(chosen.liquidValue == (values.count == 1 ? values[0] : nil),
                  "\(name) waterline selects only the matching actual pool")
            check(chosen.summary.contains("19") && chosen.activity == .notAvailable,
                  "model selection retains reset and does not invent running tasks")
        }
        var absent = account
        absent.pools.removeLast()
        let unavailable = AmbientQuotaPresentation.make(service: .cursor, account: absent,
            cursorModel: CursorModelSelection.parse("Claude Opus 5.5")!, at: now)
        check(unavailable.lines.map(\.value) == [.percent(78), .unknown] && unavailable.liquidValue == nil,
              "missing selected pool cannot borrow the other quota's waterline, but its labeled balance remains available")
        absent.pools = []
        for model in [CursorModelSelection.parse("Claude Opus 5.5")!, .automatic, .unavailable] {
            let noPools = AmbientQuotaPresentation.make(service: .cursor, account: absent, cursorModel: model, at: now)
            check(noPools.lines.isEmpty, "missing pool identities cannot borrow an unlabeled primary percentage")
        }
        for status in [QuotaOverviewStatus.stale, .unavailable, .notConnected, .sample] {
            let stale = QuotaOverviewAccount(id: "cursor", name: "Cursor", account: "fixture", group: .membership,
                value: .percent(78), timing: "19 天后重置", status: status, pools: account.pools)
            let result = AmbientQuotaPresentation.make(service: .cursor, account: stale,
                cursorModel: CursorModelSelection.parse("Claude Opus 5.5")!, at: now)
            check(result.lines.isEmpty, "recognizing a model cannot make stale or unconnected quota fresh")
        }
        guard failures == 0 else { exit(1) }
        print("PASS: selected/Auto/unknown pool presentation, missing pool, freshness and task boundaries")
    }
}
