import Foundation
import Security
import LocalAuthentication

@MainActor struct CustomQuotaCredentialVault: QuotaCredentialStoring {
    let id: String
    private static let service = "local.paul.notch.quota.custom-api.v1"
    private func agent() throws -> QuotaCredentialAgentClient? {
        guard AppEnvironment.ownedQuotaConnectionsEnabled else { throw QuotaConnectionError.preview }
        guard let uuid = UUID(uuidString: String(id.dropFirst(7))), id == "custom-" + uuid.uuidString.lowercased()
        else { throw QuotaConnectionError.keychain }
        // Public builds use their own Keychain identity, just like built-in API
        // accounts. A rejected pinned helper never falls back to direct access.
        return try QuotaCredentialAgentClient.bundled(service: Self.service, generation: .customV1, account: id)
    }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service, kSecAttrAccount as String: id,
         kSecAttrSynchronizable as String: false]
    }
    func read() throws -> String? {
        if let agent = try agent() { return try agent.request("read") }
        // The file-based Keychain needs its process-local UI gate as well as
        // LAContext. Restore the prior gate, including on locked/denied reads.
        var previous = DarwinBoolean(false)
        guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { throw QuotaConnectionError.keychain }
        defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext(); context.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        if status != errSecSuccess {
            var keychain: SecKeychain?
            var state: SecKeychainStatus = 0
            if SecKeychainCopyDefault(&keychain) == errSecSuccess, let keychain,
               SecKeychainGetStatus(keychain, &state) == errSecSuccess,
               state & UInt32(kSecUnlockStateStatus) == 0 {
                throw QuotaConnectionError.keychainLocked
            }
        }
        guard status == errSecSuccess, let bytes = result as? Data,
              let value = String(data: bytes, encoding: .utf8) else { throw QuotaConnectionError.keychain }
        return value
    }
    func save(_ value: String) throws {
        if let client = try agent() {
            _ = try client.request("save", value: value)
            // The personal release proves recovery with a fresh pinned helper.
            guard try client.request("read") == value else { throw QuotaConnectionError.keychain }
            return
        }
        let bytes = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: bytes] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = bytes
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw QuotaConnectionError.keychain }
        } else if status != errSecSuccess { throw QuotaConnectionError.keychain }
        guard try read() == value else { throw QuotaConnectionError.keychain }
    }
    func delete() throws {
        if let client = try agent() { _ = try client.request("delete"); return }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw QuotaConnectionError.keychain }
    }
}
