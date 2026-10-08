import Foundation
import Security

// Only the external Keychain operation is replaced. The production vault builds
// the request and must close the legacy macOS UI gate before reaching this call.
@MainActor enum AppEnvironment {
    static var isPersonal = false
    static var isPreview = false
    static var ownedQuotaConnectionsEnabled: Bool { !isPreview }
    static let suite = "test.paul.keychain-gate.\(UUID().uuidString)"
    static let defaults = UserDefaults(suiteName: suite)!
}
@MainActor private var keychainCalls = 0
@MainActor private var observedInteractiveRead = false
@MainActor private var keychainUpdates = 0
@MainActor private var observedInteractiveUpdate = false
@MainActor func SecItemCopyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
    keychainCalls += 1
    var interactive = DarwinBoolean(false)
    guard Security.SecKeychainGetUserInteractionAllowed(&interactive) == errSecSuccess else { return errSecInternalError }
    observedInteractiveRead = observedInteractiveRead || interactive.boolValue
    return errSecInteractionNotAllowed
}
@MainActor func SecItemUpdate(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
    keychainUpdates += 1
    var interactive = DarwinBoolean(false)
    guard Security.SecKeychainGetUserInteractionAllowed(&interactive) == errSecSuccess else { return errSecInternalError }
    observedInteractiveUpdate = observedInteractiveUpdate || interactive.boolValue
    return errSecInteractionNotAllowed
}

@main struct QuotaKeychainPromptValidation {
    @MainActor static func main() throws {
        defer { AppEnvironment.defaults.removePersistentDomain(forName: AppEnvironment.suite) }
        var original = DarwinBoolean(false)
        guard SecKeychainGetUserInteractionAllowed(&original) == errSecSuccess else { exit(2) }
        defer { SecKeychainSetUserInteractionAllowed(original.boolValue) }
        // This changes only the disposable test process, never Keychain ACLs.
        SecKeychainSetUserInteractionAllowed(true)
        do { _ = try QuotaCredentialVault().read(); print("FAIL: blocked Keychain read must throw"); exit(1) }
        catch QuotaConnectionError.keychain {}
        catch QuotaConnectionError.preview {
            print("FAIL: ordinary public runtime must permit its own opt-in quota credentials"); exit(1)
        }
        var restored = DarwinBoolean(false)
        SecKeychainGetUserInteractionAllowed(&restored)
        guard keychainCalls == 1, !observedInteractiveRead, restored.boolValue else {
            print("FAIL: background quota read reaches legacy Keychain with authentication UI allowed")
            exit(1)
        }
        SecKeychainSetUserInteractionAllowed(false)
        _ = try? QuotaCredentialVault(service: .miniMaxCN).read()
        SecKeychainGetUserInteractionAllowed(&restored)
        guard !restored.boolValue else { print("FAIL: read must not enable a previously disabled UI gate"); exit(1) }
        SecKeychainSetUserInteractionAllowed(true)
        observedInteractiveRead = false
        _ = try? QuotaCredentialVault().readForAuthorization()
        guard observedInteractiveRead else { print("FAIL: explicit authorization must retain the system permission flow"); exit(1) }
        do {
            try QuotaCredentialVault(service: .cursorAccount).saveForRefresh("synthetic-owned-session")
            print("FAIL: denied background secure update must throw"); exit(1)
        } catch QuotaConnectionError.keychain {}
        SecKeychainGetUserInteractionAllowed(&restored)
        guard keychainUpdates == 1, !observedInteractiveUpdate, restored.boolValue else {
            print("FAIL: token rotation must suppress secure-update UI and restore the previous gate on failure"); exit(1)
        }
        AppEnvironment.isPreview = true
        let before = keychainCalls
        _ = try? QuotaCredentialVault().read()
        _ = try? QuotaCredentialVault().readForAuthorization()
        _ = try? QuotaCredentialVault(service: .cursorAccount).saveForRefresh("synthetic-owned-session")
        guard keychainCalls == before else { print("FAIL: preview must never reach real credentials"); exit(1) }
        guard keychainUpdates == 1 else { print("FAIL: preview must never update real credentials"); exit(1) }
        print("PASS: production vault suppresses legacy Keychain UI, restores its process-local gate and denies preview access")
    }
}
