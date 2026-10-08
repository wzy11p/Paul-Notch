import Foundation
import Security

@main struct CredentialAgentPersistenceValidation {
    @MainActor static func main() throws {
        let args = CommandLine.arguments
        guard [4, 5].contains(args.count), args[2].hasPrefix("/tmp/paul-agent-fixture.") else { exit(2) }
        let operation = args[1], path = args[2], agentURL = URL(fileURLWithPath: args[3])
        // Make the client binaries genuinely different, just like app updates.
        #if CLIENT_AFTER_UPDATE
        let clientVersion = 2
        #else
        let clientVersion = 1
        #endif
        var keychain: SecKeychain?
        if operation == "create" {
            let password = "synthetic-keychain-fixture-only"
            let status = password.withCString { SecKeychainCreate(path, UInt32(password.utf8.count), $0, false, nil, &keychain) }
            guard status == errSecSuccess else { exit(3) }
            print("PASS: private synthetic Keychain created; owner secrets not read")
            return
        }
        guard SecKeychainOpen(path, &keychain) == errSecSuccess else { exit(4) }
        if operation == "remove" {
            guard SecKeychainDelete(keychain) == errSecSuccess else { exit(5) }; return
        }
        if operation == "lock" {
            guard SecKeychainLock(keychain) == errSecSuccess else { exit(12) }; return
        }
        if operation == "unlock" {
            let password = "synthetic-keychain-fixture-only"
            guard password.withCString({ SecKeychainUnlock(keychain, UInt32(password.utf8.count), $0, true) }) == errSecSuccess else { exit(13) }
            return
        }
        var previous = DarwinBoolean(false)
        SecKeychainGetUserInteractionAllowed(&previous); SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        let service = args.count == 5 ? args[4] : "local.paul.notch.quota.deepseek.v1"
        if operation.hasPrefix("legacy") {
            var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrAccount as String: "primary",
                kSecUseKeychain as String: keychain!]
            if operation == "legacy-save" {
                query[kSecValueData as String] = Data("synthetic-legacy-key".utf8)
                guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { exit(6) }
            } else {
                query[kSecMatchSearchList as String] = [keychain!]; query[kSecReturnData as String] = true
                var value: CFTypeRef?
                guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess else {
                    print("FAIL (expected before fix): another app build cannot restore the legacy per-binary credential")
                    exit(1)
                }
                guard value as? Data == Data("synthetic-legacy-key".utf8) else {
                    print("FAIL: stable operations changed the preserved legacy item"); exit(15)
                }
            }
            return
        }
        let agent = QuotaCredentialAgentClient(executable: agentURL, service: service, arguments: [path])
        switch operation {
        case "save": _ = try agent.request("save", value: "synthetic-stable-key")
        case "read": guard try agent.request("read") == "synthetic-stable-key" else { exit(7) }
        case "read-locked":
            do { _ = try agent.request("read"); exit(14) }
            catch QuotaConnectionError.keychainLocked {}
        case "rotate": _ = try agent.request("rotate", value: "synthetic-rotated-key")
        case "read-rotated": guard try agent.request("read") == "synthetic-rotated-key" else { exit(8) }
        case "delete": _ = try agent.request("delete")
        case "read-missing":
            do { guard try agent.request("read") == nil else { exit(9) } }
            catch { print("FAIL: missing stable item must not read the legacy primary record"); exit(9) }
        case "large":
            let value = String(repeating: "synthetic", count: 6000)
            _ = try agent.request("save", value: value)
            guard try agent.request("read") == value else { exit(10) }
        case "reject-scope":
            let outside = QuotaCredentialAgentClient(executable: agentURL,
                service: "unrelated.application.credential", arguments: [path])
            do { _ = try outside.request("read"); exit(16) }
            catch QuotaConnectionError.keychain {}
        default: exit(11)
        }
        print("PASS: stable credential agent \(operation), caller build \(clientVersion); no authentication UI")
    }
}
