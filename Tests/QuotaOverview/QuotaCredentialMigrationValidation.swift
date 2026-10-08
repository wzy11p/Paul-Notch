import Foundation

@MainActor protocol QuotaCredentialStoring {
    func read() throws -> String?
    func readForAuthorization() throws -> String?
    func save(_ value: String) throws
    func saveForRefresh(_ value: String) throws
    func delete() throws
}

// Only the OS permission boundary is substituted here: a one-time approval
// cannot be driven unattended. Real subprocess/Keychain persistence is covered
// separately by test-credential-agent.sh with private synthetic items.
@MainActor enum AppEnvironment {
    static var isPersonal = true
    static var ownedQuotaConnectionsEnabled = true
    static let suite = "test.paul.migration.\(UUID().uuidString)"
    static let defaults = UserDefaults(suiteName: suite)!
}

@MainActor struct QuotaCredentialAgentClient {
    enum Generation { case legacyV1, stableV2 }
    let generation: Generation
    static var legacyValue: String? = "synthetic-legacy-owned-key"
    static var stableValue: String?
    static var legacyAuthorizations = 0
    static var legacyReads = 0
    static var cancelAuthorization = false
    static var blockStableWrite = false
    static var stableLocked = false
    static func bundled(service: String, generation: Generation = .legacyV1) throws -> Self? {
        .init(generation: generation)
    }
    func request(_ operation: String, value: String? = nil) throws -> String? {
        if generation == .legacyV1 {
            switch operation {
            case "authorize":
                Self.legacyAuthorizations += 1
                if Self.cancelAuthorization { throw QuotaConnectionError.keychain }
                return Self.legacyValue
            case "read":
                Self.legacyReads += 1
                throw QuotaConnectionError.keychain // macOS "Allow once" didn't change its ACL.
            default: throw QuotaConnectionError.keychain
            }
        }
        if Self.stableLocked { throw QuotaConnectionError.keychainLocked }
        switch operation {
        case "read", "authorize": return Self.stableValue
        case "save", "rotate":
            if Self.blockStableWrite { throw QuotaConnectionError.keychain }
            Self.stableValue = value; return nil
        case "delete": Self.stableValue = nil; return nil
        default: throw QuotaConnectionError.keychain
        }
    }
    static func reset() {
        legacyValue = "synthetic-legacy-owned-key"; stableValue = nil
        legacyAuthorizations = 0; legacyReads = 0
        cancelAuthorization = false; blockStableWrite = false; stableLocked = false
        AppEnvironment.defaults.removePersistentDomain(forName: AppEnvironment.suite)
    }
}

@main struct QuotaCredentialMigrationValidation {
    @MainActor static func main() throws {
        defer { QuotaCredentialAgentClient.reset() }
        var failures = 0
        func check(_ condition: Bool, _ description: String) {
            if !condition { failures += 1; print("FAIL: \(description)") }
        }
        // Catches the observed bug: verifying the old per-build record again
        // discards a successful one-time approval instead of making it durable.
        QuotaCredentialAgentClient.reset()
        let vault = QuotaCredentialVault(service: .miniMaxCN)
        do {
            let value = try vault.readForAuthorization()
            check(value == "synthetic-legacy-owned-key", "legacy approval must restore the saved value")
            check(QuotaCredentialAgentClient.stableValue == value, "approval must create the stable owned record")
            let restarted = QuotaCredentialVault(service: .miniMaxCN)
            check(try restarted.read() == value, "new app instance must restore without an authorization action")
            check(QuotaCredentialAgentClient.legacyAuthorizations == 1 && QuotaCredentialAgentClient.legacyReads == 0,
                  "successful legacy approval must be used once, never re-read against its unchanged ACL")
        } catch {
            check(false, "one-time legacy approval must create independently readable stable storage")
        }
        // Cancelling the final legacy approval must leave both old storage and
        // the migration marker untouched so the owner can retry safely.
        QuotaCredentialAgentClient.reset(); QuotaCredentialAgentClient.cancelAuthorization = true
        do { _ = try vault.readForAuthorization(); check(false, "cancelled approval must not succeed") } catch {}
        check(QuotaCredentialAgentClient.legacyValue == "synthetic-legacy-owned-key" &&
              QuotaCredentialAgentClient.stableValue == nil, "cancelled migration must preserve legacy storage")
        QuotaCredentialAgentClient.cancelAuthorization = false
        do { check(try vault.readForAuthorization() != nil, "cancelled migration must remain retryable") }
        catch { check(false, "cancelled migration must remain retryable") }

        QuotaCredentialAgentClient.reset(); QuotaCredentialAgentClient.blockStableWrite = true
        do { _ = try vault.readForAuthorization(); check(false, "failed stable write must not claim restoration") } catch {}
        check(QuotaCredentialAgentClient.legacyValue == "synthetic-legacy-owned-key" &&
              QuotaCredentialAgentClient.stableValue == nil, "failed import must preserve legacy storage")
        QuotaCredentialAgentClient.blockStableWrite = false
        do { check(try vault.readForAuthorization() != nil, "failed import must remain retryable") }
        catch { check(false, "failed import must remain retryable") }

        // A temporary Keychain lock must retry current storage, not import or
        // prompt through a legacy fallback. A different instance sees recovery.
        QuotaCredentialAgentClient.reset()
        QuotaCredentialAgentClient.stableValue = "synthetic-current-key"
        QuotaCredentialAgentClient.stableLocked = true
        do { _ = try vault.read(); check(false, "locked storage must not report a missing login") }
        catch QuotaConnectionError.keychainLocked {} catch { check(false, "locked storage needs its retryable error") }
        check(QuotaCredentialAgentClient.legacyReads == 0 && QuotaCredentialAgentClient.legacyAuthorizations == 0,
              "locked current storage must not fall back to a legacy permission prompt")
        QuotaCredentialAgentClient.stableLocked = false
        do { check(try QuotaCredentialVault(service: .miniMaxCN).read() == "synthetic-current-key",
                   "unlock must restore the current connection without input") }
        catch { check(false, "unlock must restore the current connection without input") }

        // Disconnect and replacement must never resurrect an older account.
        QuotaCredentialAgentClient.reset()
        do {
            try vault.save("synthetic-replacement-key")
            check(try vault.read() == "synthetic-replacement-key", "replacement must prefer stable storage")
            try vault.delete()
            check(try vault.read() == nil, "disconnect must not re-import the retained old account")
            check(QuotaCredentialAgentClient.legacyReads == 0, "retired legacy storage must stay ignored")
            check(QuotaCredentialAgentClient.legacyValue == "synthetic-legacy-owned-key", "rollback copy must not be destroyed")
        } catch { check(false, "stable save/read/disconnect must finish without touching legacy credentials") }
        guard failures == 0 else { exit(1) }
        print("PASS: one-time legacy migration, restart recovery, cancellation, failed import, lock retry and no disconnected-account resurrection")
    }
}
