import Foundation
import Security

// Replace only the system Keychain boundary: no real credentials are accessed.
@MainActor enum AppEnvironment {
    static var isPersonal = false
    static var ownedQuotaConnectionsEnabled = true
}
@MainActor protocol QuotaCredentialStoring {
    func read() throws -> String?
    func save(_ value: String) throws
    func delete() throws
}
@MainActor private var items: [String: Data] = [:]
@MainActor private var calls = 0
@MainActor private var denyReads = false
@MainActor private var locked = false
@MainActor private var badScope = false
@MainActor private var interactiveReads = false
@MainActor func SecKeychainGetStatus(_ keychain: SecKeychain, _ state: UnsafeMutablePointer<SecKeychainStatus>) -> OSStatus {
    state.pointee = locked ? 0 : UInt32(kSecUnlockStateStatus)
    return errSecSuccess
}
@MainActor private func account(_ query: CFDictionary) -> String {
    calls += 1
    let values = query as NSDictionary
    if values[kSecAttrService] as? String != "local.paul.notch.quota.custom-api.v1"
        || values[kSecAttrSynchronizable] as? Bool != false { badScope = true }
    return values[kSecAttrAccount] as? String ?? ""
}
@MainActor func SecItemCopyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
    let id = account(query)
    var allowed = DarwinBoolean(false)
    Security.SecKeychainGetUserInteractionAllowed(&allowed)
    interactiveReads = interactiveReads || allowed.boolValue
    if denyReads { return errSecInteractionNotAllowed }
    guard let data = items[id] else { return errSecItemNotFound }
    result?.pointee = data as CFData
    return errSecSuccess
}
@MainActor func SecItemUpdate(_ query: CFDictionary, _ values: CFDictionary) -> OSStatus {
    let id = account(query)
    guard items[id] != nil else { return errSecItemNotFound }
    items[id] = (values as NSDictionary)[kSecValueData] as? Data
    return errSecSuccess
}
@MainActor func SecItemAdd(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
    let id = account(query)
    guard items[id] == nil else { return errSecDuplicateItem }
    items[id] = (query as NSDictionary)[kSecValueData] as? Data
    return errSecSuccess
}
@MainActor func SecItemDelete(_ query: CFDictionary) -> OSStatus {
    items.removeValue(forKey: account(query)) == nil ? errSecItemNotFound : errSecSuccess
}

@main struct PublicCustomQuotaVaultValidation {
    @MainActor static func main() {
        do {
            let firstID = "custom-00000000-0000-0000-0000-000000000001"
            let secondID = "custom-00000000-0000-0000-0000-000000000002"
            let first = CustomQuotaCredentialVault(id: firstID)
            let second = CustomQuotaCredentialVault(id: secondID)
            var prior = DarwinBoolean(false)
            guard SecKeychainGetUserInteractionAllowed(&prior) == errSecSuccess else { exit(2) }
            defer { SecKeychainSetUserInteractionAllowed(prior.boolValue) }
            SecKeychainSetUserInteractionAllowed(true)
            try first.save("synthetic-first")
            try second.save("synthetic-second")
            guard try CustomQuotaCredentialVault(id: firstID).read() == "synthetic-first",
                  try second.read() == "synthetic-second" else { throw Failure.wrongAccount }
            try first.save("synthetic-replaced")
            guard try first.read() == "synthetic-replaced" else { throw Failure.wrongAccount }
            try first.delete()
            guard try first.read() == nil, try second.read() == "synthetic-second" else { throw Failure.wrongAccount }
            let before = calls
            for invalid in ["primary", "custom-invalid", "other-" + String(firstID.dropFirst(7))] {
                _ = try? CustomQuotaCredentialVault(id: invalid).read()
                try? CustomQuotaCredentialVault(id: invalid).save("synthetic")
                try? CustomQuotaCredentialVault(id: invalid).delete()
            }
            AppEnvironment.ownedQuotaConnectionsEnabled = false
            _ = try? second.read(); try? second.save("synthetic"); try? second.delete()
            guard calls == before else { throw Failure.invalidAccess }
            AppEnvironment.ownedQuotaConnectionsEnabled = true
            denyReads = true
            do { _ = try second.read(); throw Failure.acceptedDeniedRead } catch QuotaConnectionError.keychain {}
            var restored = DarwinBoolean(false)
            SecKeychainGetUserInteractionAllowed(&restored)
            guard !badScope, !interactiveReads, restored.boolValue else { throw Failure.invalidAccess }
            locked = true
            do { _ = try second.read(); throw Failure.acceptedDeniedRead }
            catch QuotaConnectionError.keychainLocked {}
            catch {
                print("FAIL: verified temporary Keychain lock must remain retryable after unlock")
                exit(1)
            }
            locked = false; denyReads = false
            guard try second.read() == "synthetic-second" else { throw Failure.wrongAccount }
            SecKeychainSetUserInteractionAllowed(false)
            _ = try? second.read()
            SecKeychainGetUserInteractionAllowed(&restored)
            guard !restored.boolValue else { throw Failure.invalidAccess }
            print("PASS: public custom API vault saves independently, restores fresh reads, scopes deletion, rejects preview and suppresses background prompts")
        } catch {
            print("FAIL: public custom API credentials unavailable or unsafe: \(type(of: error))")
            exit(1)
        }
    }
    enum Failure: Error { case wrongAccount, invalidAccess, acceptedDeniedRead }
}
