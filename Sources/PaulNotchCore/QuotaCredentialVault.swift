import Foundation
import Security
import LocalAuthentication

/// A dedicated opt-in provider key, separate from the legacy credentials vault.
@MainActor struct QuotaCredentialVault: QuotaCredentialStoring {
    enum Service: String {
        case deepSeek = "local.paul.notch.quota.deepseek.v1"
        case miniMaxCN = "local.paul.notch.quota.minimax-cn-wallet.v1"
        case cursorAccount = "local.paul.notch.quota.cursor-account.v1"
    }
    var service: Service = .deepSeek
    private var retiredLegacyKey: String { "quota.credential.stable-v2.\(service.rawValue)" }
    private func stableAgent() throws -> QuotaCredentialAgentClient? {
        try .bundled(service: service.rawValue, generation: .stableV2)
    }
    /// Only an explicit recovery action may read the legacy item interactively.
    /// Import that successful read once; do not re-read its unchanged old ACL.
    private func recover(using agent: QuotaCredentialAgentClient, interactive: Bool) throws -> String? {
        if let current = try agent.request("read") { return current }
        guard !AppEnvironment.defaults.bool(forKey: retiredLegacyKey) else { return nil }
        guard let legacy = try QuotaCredentialAgentClient.bundled(service: service.rawValue, generation: .legacyV1),
              let value = try legacy.request(interactive ? "authorize" : "read") else { return nil }
        // A fresh v2 item is created by the immutable v2 component itself, so
        // its default app ACL/partition never belongs to a changing UI build.
        _ = try agent.request("rotate", value: value)
        guard try agent.request("read") == value else { throw QuotaConnectionError.keychain }
        AppEnvironment.defaults.set(true, forKey: retiredLegacyKey)
        return value
    }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service.rawValue,
         kSecAttrAccount as String: "primary",
         kSecAttrSynchronizable as String: false]
    }
    func read() throws -> String? {
        guard AppEnvironment.ownedQuotaConnectionsEnabled else { throw QuotaConnectionError.preview }
        if let agent = try stableAgent() {
            return try recover(using: agent, interactive: false)
        }
        // Existing items live in the file-based macOS Keychain. LAContext alone
        // does not suppress that implementation's ACL prompts. Scope its legacy
        // UI gate to this synchronous MainActor read and restore it on every exit.
        // This changes neither an item's ACL nor the user's Keychain settings.
        var previous = DarwinBoolean(false)
        guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
            throw QuotaConnectionError.keychain
        }
        defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        return try copyKey(interactive: false)
    }
    func readForAuthorization() throws -> String? {
        // Only a dedicated, explicit user action may call this path.
        guard AppEnvironment.ownedQuotaConnectionsEnabled else { throw QuotaConnectionError.preview }
        if let agent = try stableAgent() {
            return try recover(using: agent, interactive: true)
        }
        return try copyKey(interactive: true)
    }
    private func copyKey(interactive: Bool) throws -> String? {
        guard AppEnvironment.ownedQuotaConnectionsEnabled else { throw QuotaConnectionError.preview }
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = !interactive
        request[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes = result as? Data,
              let key = String(data: bytes, encoding: .utf8) else { throw QuotaConnectionError.keychain }
        return key
    }
    func save(_ value: String) throws {
        guard AppEnvironment.ownedQuotaConnectionsEnabled else { throw QuotaConnectionError.preview }
        if let agent = try stableAgent() {
            _ = try agent.request("save", value: value)
            guard try agent.request("read") == value else { throw QuotaConnectionError.keychain }
            AppEnvironment.defaults.set(true, forKey: retiredLegacyKey)
            return
        }
        let bytes = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: bytes] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw QuotaConnectionError.keychain }
        var item = query
        item[kSecValueData as String] = bytes
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw QuotaConnectionError.keychain }
    }
    func saveForRefresh(_ value: String) throws {
        guard AppEnvironment.ownedQuotaConnectionsEnabled else { throw QuotaConnectionError.preview }
        if let agent = try stableAgent() {
            _ = try agent.request("rotate", value: value); return
        }
        var previous = DarwinBoolean(false)
        guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { throw QuotaConnectionError.keychain }
        defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        try save(value)
    }
    func delete() throws {
        guard AppEnvironment.ownedQuotaConnectionsEnabled else { throw QuotaConnectionError.preview }
        if let agent = try stableAgent() {
            // Keep the legacy rollback item, but never resurrect it after an
            // explicit disconnect, even if a secure deletion is interrupted.
            AppEnvironment.defaults.set(true, forKey: retiredLegacyKey)
            _ = try agent.request("delete"); return
        }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw QuotaConnectionError.keychain }
    }
}
