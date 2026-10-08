import Foundation

@main struct DesktopQuotaStoreValidation {
    @MainActor static func main() async {
        var failures = 0
        func check(_ value: Bool, _ message: String) { if !value { failures += 1; print("FAIL: \(message)") } }
        let suite = "local.paul.test.desktop.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let capture = Capture()
        let store = DesktopQuotaStore(defaults: defaults, allowsReads: true, reader: { provider, interactive in
            await capture.read(provider, interactive)
        })
        store.refreshDue()
        check(store.reading == nil, "No opt-in means no passive reads")
        check(store.account(.cursor).value == .unknown, "No snapshot means no invented value")
        store.read(.cursor)
        await settle(store)
        check(store.account(.cursor).value == .percent(83), "Publish real reader value instead of fixture data")
        check(store.enabled.contains(.cursor), "A successful explicit read enables passive updates")
        check(store.account(.cursor, now: .now.addingTimeInterval(120)).status == .stale, "Page snapshots age out")
        store.disconnect(.cursor)
        check(store.account(.cursor).value == .unknown && !store.enabled.contains(.cursor), "Disconnect clears snapshot and opt-in")
        store.read(.grok)
        store.disconnect(.grok)
        await settle(store)
        check(store.account(.grok).value == .unknown, "A late completion cannot reconnect a disconnected provider")
        let denied = DesktopQuotaStore(defaults: defaults, allowsReads: false, reader: { p, i in await capture.read(p, i) })
        let before = await capture.count
        denied.read(.cursor); denied.refreshDue()
        check(await capture.count == before, "Preview gating must not invoke the reader")
        let broken = DesktopQuotaStore(defaults: defaults, allowsReads: true, reader: { _, _ in throw DesktopQuotaFailure.permission })
        broken.read(.doubao); await settle(broken)
        check(broken.states[.doubao]?.error == .permission && broken.account(.doubao).value == .unknown,
              "Permission failure is actionable and never produces a number")
        let connectedDefaults = UserDefaults(suiteName: "\(suite).connected")!
        defer { connectedDefaults.removePersistentDomain(forName: "\(suite).connected") }
        for provider in DesktopQuotaProvider.allCases {
            connectedDefaults.set(true, forKey: "quota.desktop.\(provider.rawValue).enabled.v1")
        }
        let clock = TestClock()
        let updates = Updates()
        let continuous = DesktopQuotaStore(defaults: connectedDefaults, allowsReads: true, clock: { clock.now }, reader: { p, i in
            try await updates.read(p, i)
        })
        continuous.refreshDue()
        await settle(continuous)
        for provider in DesktopQuotaProvider.allCases {
            check(continuous.account(provider).value == .percent(83),
                  "Every opted-in membership must refresh in the same scheduling pass; \(provider.rawValue) cannot starve")
        }
        await updates.configure(used: 42, failed: .grok)
        clock.now = clock.now.addingTimeInterval(10)
        continuous.refreshDue()
        await settle(continuous)
        check(continuous.account(.cursor).value == .percent(58) && continuous.account(.doubao).value == .percent(58),
              "Changed source quotas must reach every healthy card on the next automatic cycle without reconnecting")
        check(continuous.account(.grok).status == .stale && continuous.states[.grok]?.error == .pageUnavailable,
              "A missing source becomes stale without blocking other providers or inventing a reset")
        let countAfterUpdate = await updates.count
        continuous.refreshDue()
        await settle(continuous)
        check(await updates.count == countAfterUpdate, "Scheduling ticks cannot hammer sources before the next due time")
        check(await updates.interactiveReads == 0, "Automatic updates must never activate the source app or open its menu")
        await updates.configure(used: 47, failed: nil)
        continuous.refreshDue(force: true)
        for _ in 0..<10 { continuous.refreshDue(force: true) }
        continuous.disconnect(.grok)
        await settle(continuous)
        check(continuous.account(.cursor).value == .percent(53) && continuous.account(.doubao).value == .percent(53),
              "Disconnecting one provider cannot cancel another provider's update")
        check(continuous.account(.grok).value == .unknown && !continuous.enabled.contains(.grok),
              "A disconnected provider cannot reconnect from its late automatic completion")
        check(await updates.count <= countAfterUpdate + 3, "Repeated refreshes coalesce independently for each provider")
        continuous.stop()
        guard failures == 0 else { exit(1) }
        print("PASS: membership opt-in, real values, freshness, disconnect race and preview/permission boundaries")
    }
    @MainActor static func settle(_ store: DesktopQuotaStore) async {
        for _ in 0..<100 where store.reading != nil { try? await Task.sleep(for: .milliseconds(10)) }
    }
    actor Capture {
        var count = 0
        func read(_ provider: DesktopQuotaProvider, _ interactive: Bool) -> DesktopQuotaSnapshot {
            count += 1
            return .init(pools: [.init(name: "独立额度", used: 17)], resetLabel: nil, observedAt: .now)
        }
    }
    @MainActor final class TestClock { var now = Date() }
    actor Updates {
        var count = 0
        var interactiveReads = 0
        private var used: Double = 17
        private var failed: DesktopQuotaProvider?
        func configure(used: Double, failed: DesktopQuotaProvider?) { self.used = used; self.failed = failed }
        func read(_ provider: DesktopQuotaProvider, _ interactive: Bool) async throws -> DesktopQuotaSnapshot {
            count += 1
            if interactive { interactiveReads += 1 }
            let result = DesktopQuotaSnapshot(pools: [.init(name: "独立额度", used: used)], resetLabel: nil, observedAt: .now)
            let shouldFail = provider == failed
            try? await Task.sleep(for: .milliseconds(40))
            if shouldFail { throw DesktopQuotaFailure.pageUnavailable }
            return result
        }
    }
}
