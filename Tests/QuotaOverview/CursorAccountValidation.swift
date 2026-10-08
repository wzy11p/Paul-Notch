import Foundation

@MainActor private final class CursorTestVault: QuotaCredentialStoring {
    var key: String?
    var reads = 0
    var authorizations = 0
    var denied = false
    var saves = 0
    var refreshSaves = 0
    var deniesRefreshSave = false
    func read() throws -> String? { reads += 1; if denied { throw QuotaConnectionError.keychain }; return key }
    func readForAuthorization() throws -> String? { authorizations += 1; return key }
    func save(_ value: String) throws { saves += 1; key = value }
    func saveForRefresh(_ value: String) throws {
        refreshSaves += 1
        if deniesRefreshSave { throw QuotaConnectionError.keychain }
        key = value
    }
    func delete() throws { key = nil }
}

private actor CursorTestTransport {
    var counts: [String: Int] = [:]
    var used = 12.5
    var failure: String?
    var status = 200
    var delayed = false
    var requiresRotation = false
    var rotationStatus = 200
    var pollStatus = 200
    var retryAfter: TimeInterval?
    func configure(used: Double, failure: String? = nil, status: Int = 500, delayed: Bool = false) {
        self.used = used; self.failure = failure; self.status = status; self.delayed = delayed
    }
    func configureAuthentication(rotation: Bool = false, status: Int = 200, poll: Int = 200,
                                 retryAfter: TimeInterval? = nil) {
        requiresRotation = rotation; rotationStatus = status; pollStatus = poll; self.retryAfter = retryAfter
    }
    func fetch(_ request: URLRequest) async throws -> QuotaHTTPResponse {
        let path = request.url?.path ?? ""
        counts[path, default: 0] += 1
        let capturedUsed = used
        let capturedStatus: Int
        if path == "/auth/poll" { capturedStatus = pollStatus }
        else if path == "/oauth/token" { capturedStatus = rotationStatus }
        else if requiresRotation && request.value(forHTTPHeaderField: "Authorization") != "Bearer rotated-test-access" { capturedStatus = 401 }
        else { capturedStatus = path == failure ? status : 200 }
        if delayed { try? await Task.sleep(for: .milliseconds(100)) }
        let payload: String
        if path == "/auth/poll" {
            payload = #"{"accessToken":"test-access-token","refreshToken":"test-refresh-token"}"#
        } else if path == "/oauth/token" {
            payload = #"{"access_token":"rotated-test-access","refresh_token":"rotated-test-refresh"}"#
        } else if path.hasSuffix("GetCurrentPeriodUsage") {
            payload = "{\"enabled\":true,\"billingCycleStart\":\"1790812800000\",\"billingCycleEnd\":\"1793491200000\",\"planUsage\":{\"autoPercentUsed\":\(capturedUsed),\"apiPercentUsed\":25}}"
        } else if path.hasSuffix("GetSandUsageStatus") {
            payload = "{\"usagePercent\":\(capturedUsed),\"nextResetTimestampUtc\":\"2026-10-06T08:00:00Z\",\"hasNonZeroIncludedLimit\":true}"
        } else { throw QuotaConnectionError.invalidData }
        return .init(status: capturedStatus, data: Data(payload.utf8), etag: nil, retryAfter: retryAfter)
    }
}

@main struct CursorAccountValidation {
    @MainActor static func main() async throws {
        var failures = 0
        func check(_ condition: Bool, _ message: String) { if !condition { failures += 1; print("FAIL: \(message)") } }
        let clock = TestClock()
        let attempt = CursorQuotaLoginAttempt(at: clock.now)
        check(attempt.verifier.count == 43 && attempt.challenge.count == 43 && attempt.verifier != attempt.challenge,
              "Each owned login needs a random PKCE verifier and SHA256 challenge, never another app's credentials")
        check(attempt.loginURL.host == "cursor.com" && attempt.loginURL.path == "/loginDeepControl" &&
              !attempt.loginURL.absoluteString.contains(attempt.verifier), "Only the challenge goes to the official login page")
        let poll = CursorQuotaRequest.poll(attempt)
        check(poll.url?.host == "api2.cursor.sh" && poll.httpMethod == "GET" && poll.httpBody == nil,
              "The owned attempt polls only the verified authentication endpoint")
        let cursorPayload = Data(#"{"enabled":true,"billingCycleEnd":"1793491200000","planUsage":{"autoPercentUsed":12.5,"apiPercentUsed":25,"totalPercentUsed":99}}"#.utf8)
        let cursor = try CursorQuotaParser.parse(.cursor, data: cursorPayload, at: clock.now)
        check(cursor.pools.map(\.remaining) == [87, 75], "Cursor Models and Other Models stay independent; total percent is not substituted")
        check(cursor.resetsAt == Date(timeIntervalSince1970: 1_793_491_200), "Convert the verified billing epoch in milliseconds, not seconds or an invented monthly interval")
        let grokPayload = Data(#"{"usagePercent":101.5,"nextResetTimestampUtc":"2026-10-06T08:00:00Z","hasNonZeroIncludedLimit":true}"#.utf8)
        let grok = try CursorQuotaParser.parse(.grok, data: grokPayload, at: clock.now)
        check(grok.pools.first?.remaining == 0 && grok.resetsAt != cursor.resetsAt,
              "Grok Bot's weekly meter is independent and exhausted/over-limit usage cannot become negative remaining")
        for data in [Data("{}".utf8), Data(#"{"usagePercent":14,"usesPooledEnterpriseAllowance":true}"#.utf8)] {
            do { _ = try CursorQuotaParser.parse(.grok, data: data, at: clock.now); check(false, "Unknown or pooled enterprise meters cannot become a personal percentage") }
            catch {}
        }
        let request = try CursorQuotaRequest.usage(.grok, accessToken: "test-access-token")
        check(request.httpMethod == "POST" && request.httpBody == Data("{}".utf8) &&
              request.url?.path == "/aiserver.v1.DashboardService/GetSandUsageStatus" && !request.httpShouldHandleCookies,
              "Only the verified read RPC is allowed; no chat, reset-card consumption or billing mutation")
        do {
            _ = try await CursorQuotaHTTPClient.fetch(URLRequest(url: URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/UseSandBankedReset")!))
            check(false, "Transport rejects mutations before a request")
        } catch {}

        let suite = "local.paul.test.cursor-account.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let vault = CursorTestVault()
        let transport = CursorTestTransport()
        let store = CursorQuotaAccountStore(defaults: defaults, vault: vault, allowsConnections: true,
            transport: { try await transport.fetch($0) }, clock: { clock.now })
        store.refreshDue()
        check(await transport.counts.isEmpty && vault.reads == 0, "No opt-in means no login, credential read or quota request")
        store.beginLogin()
        await settleLogin(store)
        check(store.enabled && store.account(.cursor, now: clock.now).value == .percent(87) &&
              store.account(.grok, now: clock.now).value == .percent(87), "Only verified account responses enable the real cards")
        check(vault.saves == 1 && vault.key != nil && store.loginURL == nil, "Own login is securely saved after verification, never in preferences")
        let readCount = vault.reads
        await transport.configure(used: 42, failure: "/aiserver.v1.DashboardService/GetSandUsageStatus")
        clock.now = clock.now.addingTimeInterval(30)
        store.refreshDue()
        await settle(store)
        check(store.account(.cursor, now: clock.now).value == .percent(58) && store.account(.grok, now: clock.now).status == .stale,
              "Closed login UI is not a data source: background RPC changes one card while another fails independently")
        check(vault.reads == readCount, "Background quota ticks reuse the owned session without asking Keychain repeatedly")
        await transport.configure(used: 31, delayed: true)
        await transport.configureAuthentication(rotation: true)
        store.refreshDue(force: true)
        await settle(store)
        check(await transport.counts["/oauth/token"] == 1 && vault.refreshSaves == 1 && vault.saves == 1,
              "Concurrent expiry uses one shared owned-token rotation and only the noninteractive secure-save path")
        check(store.account(.cursor, now: clock.now).value == .percent(69) &&
              store.account(.grok, now: clock.now).value == .percent(69), "Both sources retry using the rotated session")
        store.stop()
        let restarted = CursorQuotaAccountStore(defaults: defaults, vault: vault, allowsConnections: true,
            transport: { try await transport.fetch($0) }, clock: { clock.now })
        let pollsBeforeRestart = await transport.counts["/auth/poll"]
        for provider in [DesktopQuotaProvider.cursor, .grok] {
            let pending = restarted.account(provider, now: clock.now)
            check(pending.value == .unknown && pending.timing == "正在自动恢复" &&
                  pending.unavailableReason == "正在恢复已保存的连接并核验额度",
                  "Cold start must show restoration, not ask for a redundant official login before any request finishes")
        }
        check(vault.reads == readCount && !restarted.isLoggingIn,
              "Rendering the restoring state must neither read credentials nor begin login")
        restarted.refreshDue()
        check(restarted.account(.cursor, now: clock.now).timing == "正在自动恢复",
              "A pending initial quota request is not authentication failure")
        await settle(restarted)
        let pollsAfterRestart = await transport.counts["/auth/poll"]
        check(restarted.account(.cursor, now: clock.now).status == .current && vault.reads == readCount + 1 &&
              pollsAfterRestart == pollsBeforeRestart,
              "Restart resumes the owned saved login once without opening a login page or repeatedly reading Keychain")
        restarted.stop()
        // A login endpoint's Retry-After applies to the explicit reconnect button too.
        await transport.configureAuthentication(poll: 429, retryAfter: 120)
        store.beginLogin(); await settleLogin(store)
        let limitedPolls = await transport.counts["/auth/poll"]
        for _ in 0..<10 { store.beginLogin(); await settleLogin(store) }
        check(await transport.counts["/auth/poll"] == limitedPolls,
              "Repeated login clicks must honor the server's Retry-After instead of creating an authentication request storm")
        clock.now = clock.now.addingTimeInterval(121)
        await transport.configureAuthentication()
        store.beginLogin(); await settleLogin(store)
        check(store.enabled && store.loginError == nil, "Explicit login can recover after the rate-limit deadline")
        await transport.configure(used: 63, delayed: true)
        for _ in 0..<10 { store.refreshDue(force: true) }
        store.disconnect()
        await settle(store)
        try await Task.sleep(for: .milliseconds(140))
        check(!store.enabled && vault.key == nil && store.account(.cursor, now: clock.now).value == .unknown,
              "Disconnect rejects late quota/login results and cannot recreate credentials")
        store.stop()
        let isolated = CursorQuotaAccountStore(defaults: defaults, vault: vault, allowsConnections: false,
            transport: { try await transport.fetch($0) }, clock: { clock.now })
        let beforePreview = await transport.counts
        isolated.beginLogin(); isolated.refreshDue(force: true)
        check(await transport.counts == beforePreview && vault.key == nil, "Preview cannot log in or query live accounts")
        guard failures == 0 else { exit(1) }
        print("PASS: owned Cursor PKCE, exact read-RPC boundary, separate monthly/weekly pools, source changes with closed login UI, independent failure, session reuse, late-result rejection and preview isolation")
    }
    @MainActor final class TestClock { var now = Date(timeIntervalSince1970: 1_790_827_200) }
    @MainActor static func settle(_ store: CursorQuotaAccountStore) async {
        for _ in 0..<150 where store.isRefreshing { try? await Task.sleep(for: .milliseconds(10)) }
    }
    @MainActor static func settleLogin(_ store: CursorQuotaAccountStore) async {
        for _ in 0..<150 where store.isLoggingIn { try? await Task.sleep(for: .milliseconds(10)) }
    }
}
