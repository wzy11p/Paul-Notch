import Foundation
import Combine
@testable import PaulNotchCore

@MainActor private final class CustomKeyBank {
    var keys: [String: String] = [:]
    var saves = 0
    var rejectsSave = false
    var rejectsAfterSave = false
    var rejectsDelete = false
    var readFailure: QuotaConnectionError?
    func vault(_ id: String) -> any QuotaCredentialStoring { AccountVault(bank: self, id: id) }
}
@MainActor private struct AccountVault: QuotaCredentialStoring {
    let bank: CustomKeyBank; let id: String
    func read() throws -> String? {
        if let error = bank.readFailure { throw error }
        return bank.keys[id]
    }
    func save(_ value: String) throws {
        bank.saves += 1
        if bank.rejectsSave { throw QuotaConnectionError.keychain }
        bank.keys[id] = value
        if bank.rejectsAfterSave { throw QuotaConnectionError.keychain }
    }
    func delete() throws {
        if bank.rejectsDelete { throw QuotaConnectionError.keychain }
        bank.keys[id] = nil
    }
}
@MainActor private final class FailableRegistry: CustomQuotaRegistryStoring {
    var saved: [CustomQuotaDefinition] = []
    var rejectsSave = false
    func load() throws -> [CustomQuotaDefinition] { saved }
    func save(_ definitions: [CustomQuotaDefinition]) throws {
        if rejectsSave { throw CustomQuotaIssue.storage }
        saved = definitions
    }
}
actor CustomResponseFixture {
    var amount = "12.40", status = 200, calls = 0, delay = false
    var retryAfter: TimeInterval? = nil
    func configure(amount: String = "12.40", status: Int = 200, delay: Bool = false, retryAfter: TimeInterval? = nil) {
        self.amount = amount; self.status = status; self.delay = delay; self.retryAfter = retryAfter
    }
    func fetch(_ request: URLRequest) async throws -> QuotaHTTPResponse {
        guard request.url?.absoluteString == "https://api.example.com/balance", request.httpMethod == "GET", request.httpBody == nil,
              request.value(forHTTPHeaderField: "Cookie") == nil else { throw CustomQuotaIssue.endpoint }
        calls += 1
        let captured = (amount, status, retryAfter)
        if delay { try? await Task.sleep(for: .milliseconds(100)) }
        return .init(status: captured.1, data: Data("{\"data\":{\"balance\":\"\(captured.0)\"}}".utf8), etag: nil, retryAfter: captured.2)
    }
}

@main struct CustomQuotaLifecycleValidation {
    @MainActor static func main() async throws {
        let suite = "test.paul.custom.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = CustomQuotaDefaultsRegistry(defaults: defaults)
        let bank = CustomKeyBank(), fixture = CustomResponseFixture()
        let mapping = CustomQuotaMapping(remainingPath: "/data/balance", unit: .cny)
        let store = CustomQuotaConnectionsStore(registry: registry, allowsConnections: true, vault: bank.vault,
            transport: { try await fixture.fetch($0) })
        store.refreshDue()
        guard await fixture.calls == 0, bank.saves == 0 else { print("FAIL: empty startup cannot read a provider or save credentials"); exit(1) }
        store.verify(name: "My API", endpoint: "https://api.example.com/balance", auth: .bearer, key: "fixture-first-key")
        await settle(store)
        guard store.setupFields?.contains(where: { $0.path == "/data/balance" }) == true else {
            print("FAIL: a genuine custom response must offer its quota fields without another code adapter"); exit(1)
        }
        guard bank.saves == 0, store.accounts(now: .now).isEmpty, try registry.load().isEmpty else {
            print("FAIL: verification alone cannot persist credentials, publish an account or claim connected"); exit(1)
        }
        guard let id = store.commit(mapping: mapping), bank.keys[id] == "fixture-first-key",
              store.accounts(now: .now).first?.displayValue == "¥12.40" else {
            print("FAIL: explicit verified commit must save its own key and publish the actual response amount"); exit(1)
        }
        guard let bytes = defaults.data(forKey: CustomQuotaDefaultsRegistry.key),
              !String(decoding: bytes, as: UTF8.self).contains("fixture-first-key"),
              !String(decoding: bytes, as: UTF8.self).contains("12.40") else {
            print("FAIL: registry cannot contain credentials or stale balance snapshots"); exit(1)
        }
        store.stop()
        await fixture.configure(amount: "8.20")
        let restored = CustomQuotaConnectionsStore(registry: registry, allowsConnections: true, vault: bank.vault,
            transport: { try await fixture.fetch($0) })
        guard restored.accounts(now: .now).first?.displayValue == "—" else { print("FAIL: restoration cannot manufacture a fresh cached value"); exit(1) }
        restored.refreshDue(); await settle(restored)
        guard restored.accounts(now: .now).first?.displayValue == "¥8.20" else { print("FAIL: restored connections must read saved keys and new balances without setup"); exit(1) }
        await fixture.configure(status: 401)
        restored.verify(name: "My API", endpoint: "https://api.example.com/balance", auth: .bearer, key: "fixture-bad-key", replacingID: id)
        await settle(restored)
        guard restored.setupError != nil, restored.commit(mapping: mapping) == nil, bank.keys[id] == "fixture-first-key",
              try registry.load().count == 1 else { print("FAIL: rejected replacements must preserve the working saved account"); exit(1) }
        restored.cancelSetup()
        await fixture.configure(amount: "7.15")
        restored.refreshDue(force: true); await settle(restored)
        guard restored.accounts(now: .now).first?.displayValue == "¥7.15" else { print("FAIL: automatic source recovery must survive failed setup attempts"); exit(1) }
        let calls = await fixture.calls
        restored.refreshDue(); await settle(restored)
        guard await fixture.calls == calls else { print("FAIL: quota polling cannot ignore its cadence"); exit(1) }
        await fixture.configure(amount: "3.10", delay: true)
        restored.refreshDue(force: true)
        guard restored.disconnect(id) else { print("FAIL: explicit disconnect must be actionable"); exit(1) }
        try await Task.sleep(for: .milliseconds(150))
        guard restored.accounts(now: .now).isEmpty, bank.keys[id] == nil, try registry.load().isEmpty else { print("FAIL: a late response cannot restore a removed account"); exit(1) }
        let failing = FailableRegistry(); failing.rejectsSave = true
        let failure = CustomQuotaConnectionsStore(registry: failing, allowsConnections: true, vault: bank.vault,
            transport: { try await fixture.fetch($0) })
        await fixture.configure()
        failure.verify(name: "My API", endpoint: "https://api.example.com/balance", auth: .bearer, key: "fixture-unsaved-key")
        await settle(failure)
        guard failure.commit(mapping: mapping) == nil, bank.keys.isEmpty, failing.saved.isEmpty else { print("FAIL: metadata save failure cannot leave a connected card or orphaned new key"); exit(1) }
        let isolated = CustomQuotaConnectionsStore(registry: registry, allowsConnections: false, vault: bank.vault,
            transport: { try await fixture.fetch($0) })
        let beforePreview = await fixture.calls
        isolated.verify(name: "Preview", endpoint: "https://api.example.com/balance", auth: .bearer, key: "fixture-preview")
        isolated.refreshDue(force: true); await settle(isolated)
        guard await fixture.calls == beforePreview, bank.keys.isEmpty else { print("FAIL: an isolated preview cannot call custom destinations or save keys"); exit(1) }
        try await verifyFailureBoundaries(mapping)
        await verifyLockRecovery(mapping)
        print("PASS: real-field verification before save, genuine live values, key-free registry, restart/cadence, failed replacement retention, cancellation, rollback and preview isolation")
    }
    @MainActor static func verifyLockRecovery(_ mapping: CustomQuotaMapping) async {
        let registry = FailableRegistry(), bank = CustomKeyBank(), fixture = CustomResponseFixture()
        let id = "custom-00000000-0000-0000-0000-000000000001"
        registry.saved = [.init(id: id, name: "Saved API", endpoint: "https://api.example.com/balance", auth: .bearer, mapping: mapping)]
        bank.keys[id] = "fixture-retained-key"; bank.readFailure = .keychainLocked
        var now = Date()
        let store = CustomQuotaConnectionsStore(registry: registry, allowsConnections: true, vault: bank.vault,
            transport: { try await fixture.fetch($0) }, clock: { now })
        store.refreshDue(); await settle(store)
        guard await fixture.calls == 0 else { print("FAIL: a locked vault must not query without its key"); exit(1) }
        bank.readFailure = nil; now += 31
        store.refreshDue(); await settle(store)
        guard store.accounts(now: now).first?.displayValue == "¥12.40", await fixture.calls == 1, bank.saves == 0 else {
            print("FAIL: unlocked saved credentials must recover automatically without re-entry or re-save"); exit(1)
        }
        store.stop()
        print("PASS: temporary Keychain lock resumes on the existing refresh schedule without reconnecting")
    }
    @MainActor static func verifyFailureBoundaries(_ mapping: CustomQuotaMapping) async throws {
        let registry = FailableRegistry(), bank = CustomKeyBank(), fixture = CustomResponseFixture()
        var now = Date()
        let store = CustomQuotaConnectionsStore(registry: registry, allowsConnections: true, vault: bank.vault,
            transport: { try await fixture.fetch($0) }, clock: { now })
        for index in 0..<5 {
            store.verify(name: "Account \(index)", endpoint: "https://api.example.com/balance", auth: .bearer, key: "fixture-\(index)")
            await settle(store)
            guard store.commit(mapping: mapping) != nil else { print("FAIL: multiple verified accounts must commit independently"); exit(1) }
        }
        await fixture.configure(amount: "9.30", delay: true)
        let beforeForce = await fixture.calls
        store.refreshDue(force: true); await settle(store)
        guard await fixture.calls == beforeForce + 5, store.accounts(now: now).allSatisfy({ $0.displayValue == "¥9.30" }) else {
            print("FAIL: a manual refresh must queue all five accounts, not only the first two"); exit(1)
        }
        await fixture.configure(status: 429, retryAfter: 240)
        store.refreshDue(force: true); await settle(store)
        let throttled = await fixture.calls
        now += 239
        store.refreshDue(force: true); await settle(store)
        guard await fixture.calls == throttled else { print("FAIL: manual refresh cannot bypass the provider Retry-After deadline"); exit(1) }
        now += 2
        await fixture.configure(amount: "4.10")
        store.refreshDue(); await settle(store)
        guard store.accounts(now: now).allSatisfy({ $0.displayValue == "¥4.10" }) else { print("FAIL: throttled accounts must recover automatically after the actual deadline"); exit(1) }
        let first = store.definitions[0].id
        bank.rejectsDelete = true
        guard !store.disconnect(first), store.definitions.count == 5, registry.saved.count == 5,
              bank.keys[first] != nil, store.registryError == nil else {
            print("FAIL: denied deletion must retain recoverable metadata without blocking unrelated connections"); exit(1)
        }
        bank.rejectsDelete = false
        guard store.disconnect(first), store.definitions.count == 4, bank.keys[first] == nil else {
            print("FAIL: a failed disconnect must remain retryable"); exit(1)
        }
        let beforePartial = bank.keys
        bank.rejectsAfterSave = true
        store.verify(name: "Interrupted save", endpoint: "https://api.example.com/balance", auth: .bearer, key: "fixture-partial")
        await settle(store)
        guard store.commit(mapping: mapping) == nil, bank.keys == beforePartial, store.definitions.count == 4 else {
            print("FAIL: partial new-key save cannot leave an orphan credential or connected card"); exit(1)
        }
        bank.rejectsAfterSave = false
        store.cancelSetup()
        let replacement = store.definitions[0]
        bank.rejectsAfterSave = true
        store.verify(name: replacement.name, endpoint: replacement.endpoint, auth: replacement.auth,
                     key: "fixture-partial-replacement", replacingID: replacement.id)
        await settle(store)
        guard store.commit(mapping: mapping) == nil, bank.keys == beforePartial else {
            print("FAIL: partial replacement save must restore the previous key, not silently break a paid account"); exit(1)
        }
        bank.rejectsAfterSave = false; store.cancelSetup()
        store.verify(name: "Expired", endpoint: "https://api.example.com/balance", auth: .bearer, key: "fixture-expired")
        await settle(store)
        now += 91
        guard store.commit(mapping: mapping) == nil, bank.keys == beforePartial else { print("FAIL: stale verification cannot be saved as current quota"); exit(1) }
        store.stop()
        print("PASS: queued refresh, provider backoff, disconnect rollback, partial-save cleanup and freshness")
    }
    @MainActor static func settle(_ store: CustomQuotaConnectionsStore) async {
        for _ in 0..<100 {
            if !store.isVerifying && !store.isRefreshing { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
