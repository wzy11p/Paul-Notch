import Foundation

@MainActor private final class GateVault: QuotaCredentialStoring {
    var reads = 0
    var blocked = true
    var authorizationReads = 0
    var authorizationBlocked = true
    func read() throws -> String? {
        reads += 1
        if blocked { throw QuotaConnectionError.keychain }
        return "sk-api-test-only-session"
    }
    func readForAuthorization() throws -> String? {
        authorizationReads += 1
        if authorizationBlocked { throw QuotaConnectionError.keychain }
        return "sk-api-test-authorized-session"
    }
    func save(_ value: String) throws {}
    func delete() throws {}
}
@MainActor private final class RebootVault: QuotaCredentialStoring {
    var locked = false
    var interactiveReads = 0
    func read() throws -> String? {
        if locked { throw QuotaConnectionError.keychainLocked }
        return "sk-api-test-retained-key"
    }
    func readForAuthorization() throws -> String? { interactiveReads += 1; throw QuotaConnectionError.keychain }
    func save(_ value: String) throws {}
    func delete() throws {}
}

private actor BalanceTransport {
    var calls = 0
    func fetch(_ request: URLRequest) async throws -> QuotaHTTPResponse {
        calls += 1
        let body = request.url?.host == "api.deepseek.com"
            ? #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"12.34","granted_balance":"0","topped_up_balance":"12.34"}]}"#
            : #"{"available_amount":"12.34","cash_balance":"12.34","voucher_balance":"0","credit_balance":"0","owed_amount":"0","base_resp":{"status_code":0}}"#
        return QuotaHTTPResponse(status: 200, data: Data(body.utf8), etag: nil)
    }
}

@main struct QuotaCredentialRetryValidation {
    @MainActor static func main() async {
        let suite = "test.paul.credential-gate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "quota.deepseek.enabled.v1")
        defaults.set(true, forKey: "quota.minimax-cn-wallet.enabled.v1")
        let deepVault = GateVault(), miniVault = GateVault()
        let transport = BalanceTransport()
        let deep = QuotaConnectionsStore(defaults: defaults, vault: deepVault, allowsConnections: true,
            transport: { try await transport.fetch($0) })
        let mini = MiniMaxWalletStore(defaults: defaults, vault: miniVault, allowsConnections: true,
            transport: { try await transport.fetch($0) })
        var failures: [String] = []
        func check(_ value: Bool, _ message: String) { if !value { failures.append(message); print("FAIL: \(message)") } }
        deep.refreshDeepSeek(); mini.refresh()
        await settle(deep, mini)
        for _ in 0..<5 {
            deep.refreshDeepSeek(force: true); mini.refresh(force: true)
            await settle(deep, mini)
        }
        check(deep.deepSeekNeedsAuthorization && mini.needsAuthorization,
              "Keychain rejection pauses both connectors instead of scheduling another authorization attempt")
        let rejectedCalls = await transport.calls
        check(deepVault.reads == 1 && miniVault.reads == 1 && rejectedCalls == 0,
              "Background and global refresh cannot repeat a rejected Keychain read")

        deep.authorizeDeepSeek(); mini.authorizeSavedKey()
        for _ in 0..<3 {
            deep.refreshDeepSeek(force: true); mini.refresh(force: true)
            await settle(deep, mini)
        }
        check(deep.deepSeekKeychainBlocked && mini.keychainBlocked &&
              deepVault.authorizationReads == 1 && miniVault.authorizationReads == 1 &&
              deepVault.reads == 1 && miniVault.reads == 1,
              "Cancelling an explicit authorization remains paused without another system request")
        deepVault.authorizationBlocked = false; miniVault.authorizationBlocked = false
        deep.authorizeDeepSeek(); mini.authorizeSavedKey()
        await settle(deep, mini)
        for _ in 0..<3 {
            deep.refreshDeepSeek(force: true); mini.refresh(force: true)
            await settle(deep, mini)
        }
        check(!deep.deepSeekNeedsAuthorization && !mini.needsAuthorization &&
              deep.deepSeekSnapshot != nil && mini.snapshot != nil &&
              deepVault.reads == 1 && miniVault.reads == 1 &&
              deepVault.authorizationReads == 2 && miniVault.authorizationReads == 2,
              "One deliberate authorization restores periodic reads without re-entering or re-reading the saved key")

        deepVault.blocked = false; miniVault.blocked = false
        _ = deep.connectDeepSeek("sk-api-test-explicit-input")
        _ = mini.connect("sk-api-test-explicit-input")
        await settle(deep, mini)
        let deepReads = deepVault.reads, miniReads = miniVault.reads
        for _ in 0..<3 {
            deep.refreshDeepSeek(force: true); mini.refresh(force: true)
            await settle(deep, mini)
        }
        check(deep.deepSeekSnapshot != nil && mini.snapshot != nil, "Explicit connection still returns parsed balances")
        check(deepVault.reads == deepReads && miniVault.reads == miniReads,
              "Authorized session refresh reuses the in-memory key instead of reopening Keychain every five minutes")
        deep.stop(); mini.stop()
        deepVault.blocked = true; miniVault.blocked = true
        deep.refreshDeepSeek(force: true); mini.refresh(force: true)
        await settle(deep, mini)
        check(deep.deepSeekNeedsAuthorization && mini.needsAuthorization,
              "Stopping a session clears cached credentials before another refresh")
        let retained = RebootVault()
        var rebootTime = Date()
        var restoredDeep = QuotaConnectionsStore(defaults: defaults, vault: retained, allowsConnections: true,
            transport: { try await transport.fetch($0) }, clock: { rebootTime })
        var restoredMini = MiniMaxWalletStore(defaults: defaults, vault: retained, allowsConnections: true,
            transport: { try await transport.fetch($0) }, clock: { rebootTime })
        restoredDeep.refreshDeepSeek(); restoredMini.refresh(); await settle(restoredDeep, restoredMini)
        check(restoredDeep.deepSeekSnapshot != nil && restoredMini.snapshot != nil && retained.interactiveReads == 0,
              "Cold start restores enabled API wallets with saved credentials, not manual connection or authorization")
        restoredDeep.stop(); restoredMini.stop()
        retained.locked = true
        restoredDeep = QuotaConnectionsStore(defaults: defaults, vault: retained, allowsConnections: true,
            transport: { try await transport.fetch($0) }, clock: { rebootTime })
        restoredMini = MiniMaxWalletStore(defaults: defaults, vault: retained, allowsConnections: true,
            transport: { try await transport.fetch($0) }, clock: { rebootTime })
        restoredDeep.refreshDeepSeek(); restoredMini.refresh(); await settle(restoredDeep, restoredMini)
        check(!restoredDeep.deepSeekNeedsAuthorization && !restoredMini.needsAuthorization &&
              restoredDeep.deepSeekEnabled && restoredMini.enabled && retained.interactiveReads == 0,
              "Locked startup retains opt-in and waits without asking for keys or opening a system prompt")
        retained.locked = false; rebootTime = rebootTime.addingTimeInterval(31)
        restoredDeep.refreshDeepSeek(); restoredMini.refresh(); await settle(restoredDeep, restoredMini)
        check(restoredDeep.deepSeekSnapshot != nil && restoredMini.snapshot != nil && retained.interactiveReads == 0,
              "Unlock automatically recovers the original saved wallets on the next due read")
        guard failures.isEmpty else { exit(1) }
        print("PASS: paused background retries, explicit recovery, session reuse and credential invalidation")
    }
    @MainActor static func settle(_ deep: QuotaConnectionsStore, _ mini: MiniMaxWalletStore) async {
        for _ in 0..<150 {
            if !deep.isDeepSeekRefreshing && !mini.isRefreshing { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
