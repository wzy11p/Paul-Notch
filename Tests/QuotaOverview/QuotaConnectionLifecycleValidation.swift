import Foundation
import Combine

@MainActor final class TestQuotaVault: QuotaCredentialStoring {
    var key: String?
    var denied = false
    func read() throws -> String? { key }
    func save(_ value: String) throws { if denied { throw QuotaConnectionError.keychain }; key = value }
    func delete() throws { key = nil }
}

actor TestQuotaTransport {
    var calls = 0
    var balance = "6.77"
    var status = 200
    var shouldDelay = false
    func configure(status: Int, delayed: Bool = false) { self.status = status; shouldDelay = delayed }
    func setBalance(_ value: String) { balance = value }
    func fetch(_ request: URLRequest) async throws -> QuotaHTTPResponse {
        calls += 1
        let capturedStatus = status
        if shouldDelay { try? await Task.sleep(for: .milliseconds(160)) }
        let body = Data("{\"is_available\":true,\"balance_infos\":[{\"currency\":\"CNY\",\"total_balance\":\"\(balance)\",\"granted_balance\":\"0\",\"topped_up_balance\":\"\(balance)\"}]}".utf8)
        return QuotaHTTPResponse(status: capturedStatus, data: body, etag: nil)
    }
}

actor TestResetTransport {
    var status = 200
    var empty = false
    var etagReceived: String?
    var calls = 0
    var retryAfter: TimeInterval?
    func configure(status: Int, empty: Bool = false, retryAfter: TimeInterval? = nil) {
        self.status = status; self.empty = empty; self.retryAfter = retryAfter
    }
    func fetch(_ request: URLRequest) async throws -> QuotaHTTPResponse {
        calls += 1
        etagReceived = request.value(forHTTPHeaderField: "If-None-Match")
        let event = #"{"id":"public-test","type":"reset_credit","status":"confirmed","title":"发放重置卡","updatedAt":"2026-09-27T11:00:00+08:00","confirmationBasis":null,"posts":[]}"#
        let payload = "{\"schemaVersion\":1,\"checkedAt\":\"2026-09-27T12:00:00+08:00\",\"monitor\":{\"status\":\"healthy\"},\"events\":[\(empty ? "" : event)]}"
        return QuotaHTTPResponse(status: status, data: Data(payload.utf8), etag: "test-etag", retryAfter: retryAfter)
    }
}

@main struct QuotaConnectionLifecycleValidation {
    @MainActor static func main() async throws {
        let suite = "test.paul.quota.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let vault = TestQuotaVault()
        let transport = TestQuotaTransport()
        let store = QuotaConnectionsStore(defaults: defaults, vault: vault, allowsConnections: true,
                                          transport: { try await transport.fetch($0) })
        var failures: [String] = []
        func check(_ value: Bool, _ message: String) {
            if !value { failures.append(message); print("FAIL: \(message)") }
        }
        store.start()
        try await Task.sleep(for: .milliseconds(30))
        check(await transport.calls == 0, "Startup without explicit connections must not make new provider requests")
        vault.denied = true
        check(!store.connectDeepSeek("test-valid-not-secret"), "Failed secure save must not enable a connection")
        check(!store.deepSeekEnabled && vault.key == nil, "Rejected credentials cannot be published or silently retained")
        vault.denied = false
        check(store.connectDeepSeek("test-valid-not-secret"), "An explicit valid key enables only the requested source")
        await settle(store)
        check(store.deepSeekSnapshot?.entries.first?.total == Decimal(string: "6.77"), "Publish the actual parsed balance after successful read")
        let cadenceClock = CadenceClock()
        let cadence = QuotaConnectionsStore(defaults: defaults, vault: vault, allowsConnections: true,
            transport: { try await transport.fetch($0) }, clock: { cadenceClock.now })
        cadence.refreshDeepSeek()
        await settle(cadence)
        let beforeDue = await transport.calls
        await transport.setBalance("5.20")
        cadenceClock.now = cadenceClock.now.addingTimeInterval(29)
        cadence.refreshDeepSeek()
        await settle(cadence)
        check(await transport.calls == beforeDue, "Wallet polling must not run before its bounded cadence")
        cadenceClock.now = cadenceClock.now.addingTimeInterval(1)
        cadence.refreshDeepSeek()
        await settle(cadence)
        check(cadence.deepSeekSnapshot?.entries.first?.total == Decimal(string: "5.20"),
              "A changed server balance must replace the Home source after thirty seconds without reconnecting")
        cadence.stop()
        await transport.setBalance("6.77")
        check(!store.feedEnabled, "Connecting a balance must not silently enable the public feed")
        store.stop()
        let restarted = QuotaConnectionsStore(defaults: defaults, vault: vault, allowsConnections: true,
                                              transport: { try await transport.fetch($0) })
        restarted.start()
        await settle(restarted)
        check(restarted.deepSeekSnapshot != nil && !restarted.feedEnabled,
              "Restart restores only the explicitly enabled connection and re-reads its balance")
        restarted.stop()
        await transport.configure(status: 500)
        store.refreshDeepSeek(force: true)
        await settle(store)
        check(store.deepSeekSnapshot != nil && store.deepSeekError != nil, "Network failure preserves the last value but marks it stale")
        await transport.configure(status: 401)
        store.refreshDeepSeek(force: true)
        await settle(store)
        check(store.deepSeekNeedsAuthorization && store.deepSeekSnapshot == nil,
              "Authorization failure must not present another account's cached balance")
        await transport.configure(status: 200, delayed: true)
        _ = store.connectDeepSeek("replacement-test-key")
        check(!store.connectDeepSeek("double-submit-test-key") && vault.key == "replacement-test-key",
              "Submitting twice while connecting must not replace the in-flight credential")
        let beforeBurst = await transport.calls
        for _ in 0..<10 { store.refreshDeepSeek(force: true) }
        try await Task.sleep(for: .milliseconds(20))
        check(await transport.calls <= beforeBurst + 1, "Rapid refresh clicks coalesce into one request")
        store.disconnectDeepSeek()
        try await Task.sleep(for: .milliseconds(220))
        check(store.deepSeekSnapshot == nil && !store.deepSeekEnabled && vault.key == nil,
              "Late results after disconnect cannot restore balances or credentials")
        store.stop()
        let isolated = QuotaConnectionsStore(defaults: defaults, vault: vault, allowsConnections: false,
                                             transport: { try await transport.fetch($0) })
        check(!isolated.connectDeepSeek("another-test-key"), "An isolated preview must not save live credentials")
        isolated.setFeedEnabled(true)
        check(!isolated.feedEnabled, "An isolated preview cannot silently enable public networking")
        let feedTransport = TestResetTransport()
        let feedStore = QuotaConnectionsStore(defaults: defaults, vault: vault, allowsConnections: true,
                                             transport: { try await feedTransport.fetch($0) })
        feedStore.setFeedEnabled(true)
        await settleFeed(feedStore)
        check(feedStore.feedSnapshot?.events.count == 1 && !feedStore.hasUnreadFeed,
              "First public sync publishes actual events without flagging all history as new")
        await feedTransport.configure(status: 304)
        feedStore.refreshFeed(force: true)
        await settleFeed(feedStore)
        check(await feedTransport.etagReceived == "test-etag" && feedStore.feedSnapshot?.events.count == 1 && feedStore.feedError == nil,
              "Conditional refresh preserves a valid snapshot on 304")
        await feedTransport.configure(status: 200, empty: true)
        feedStore.refreshFeed(force: true)
        await settleFeed(feedStore)
        check(feedStore.feedSnapshot?.events.isEmpty == true, "A withdrawn event disappears through full snapshot replacement")
        await feedTransport.configure(status: 429)
        feedStore.refreshFeed(force: true)
        await settleFeed(feedStore)
        let countAtRateLimit = await feedTransport.calls
        feedStore.refreshFeed(force: true)
        try await Task.sleep(for: .milliseconds(20))
        check(await feedTransport.calls == countAtRateLimit && feedStore.feedError != nil,
              "Rate limits block rapid retries, including manual refresh")
        feedStore.setFeedEnabled(false)
        check(feedStore.feedSnapshot == nil && !feedStore.feedEnabled, "Stopping public reads clears presentation without altering account data")
        await feedTransport.configure(status: 503, retryAfter: 600)
        feedStore.setFeedEnabled(true)
        await settleFeed(feedStore)
        let countAtUnavailable = await feedTransport.calls
        feedStore.refreshFeed(force: true)
        try await Task.sleep(for: .milliseconds(20))
        check(await feedTransport.calls == countAtUnavailable, "A 503 Retry-After also blocks manual early retries")
        feedStore.setFeedEnabled(false)
        feedStore.stop()
        var wrongRequest = URLRequest(url: URL(string: "https://example.com/private")!)
        wrongRequest.httpMethod = "GET"
        do { _ = try await QuotaHTTPClient.fetch(wrongRequest); check(false, "Reject unapproved destinations before any network request") }
        catch QuotaConnectionError.invalidData {} catch { check(false, "Unexpected rejection type") }
        guard failures.isEmpty else { exit(1) }
        print("PASS: opt-in, secure-save failures, source independence, stale/auth states, coalescing, disconnect races and preview isolation")
    }
    @MainActor final class CadenceClock { var now = Date() }
    @MainActor static func settle(_ store: QuotaConnectionsStore) async {
        for _ in 0..<100 {
            if !store.isDeepSeekRefreshing { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
    @MainActor static func settleFeed(_ store: QuotaConnectionsStore) async {
        for _ in 0..<100 {
            if !store.isFeedRefreshing { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
