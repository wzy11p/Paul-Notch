import Foundation
import Security

@main struct CustomQuotaAgentValidation {
    @MainActor static func main() throws {
        let action = CommandLine.arguments[1], path = CommandLine.arguments[2]
        let helper = URL(fileURLWithPath: CommandLine.arguments[3])
        let service = "local.paul.notch.quota.custom-api.v1"
        let first = "custom-11111111-1111-4111-8111-111111111111"
        let second = "custom-22222222-2222-4222-8222-222222222222"
        func client(_ id: String, serviceName: String = service) -> QuotaCredentialAgentClient {
            .init(executable: helper, service: serviceName, arguments: [path], account: id)
        }
        var keychain: SecKeychain?
        let password = "private-fixture-only"
        if action == "create" {
            let status = password.withCString { SecKeychainCreate(path, UInt32(password.utf8.count), $0, false, nil, &keychain) }
            guard status == errSecSuccess else { exit(1) }
            _ = try client(first).request("save", value: "first-fixture-key-not-real")
            _ = try client(second).request("save", value: "second-fixture-key-not-real")
            print("PASS: custom records saved in the private fixture Keychain")
        } else if action == "read" {
            guard try client(first).request("read") == "first-fixture-key-not-real",
                  try client(second).request("read") == "second-fixture-key-not-real" else { exit(1) }
            #if CLIENT_AFTER_UPDATE
            print("PASS: changed caller cold-process recovery and separate account keys")
            #else
            print("PASS: first caller cold-process recovery and separate account keys")
            #endif
        } else if action == "scope" {
            for invalid in [client(first, serviceName: "local.paul.notch.quota.deepseek.v1"), client("codex"), client("custom-../primary"), client(first.uppercased())] {
                do { _ = try invalid.request("read"); print("FAIL: custom helper accepted another service or invalid account"); exit(1) }
                catch QuotaConnectionError.keychain {}
            }
            do { _ = try client(first).request("authorize"); print("FAIL: custom helper can request an interactive password"); exit(1) }
            catch QuotaConnectionError.keychain {}
            print("PASS: no old-service access, invalid identities or interactive authorization")
        } else if action == "delete-one" {
            _ = try client(first).request("delete")
            guard try client(first).request("read") == nil,
                  try client(second).request("read") == "second-fixture-key-not-real" else { exit(1) }
            print("PASS: disconnect affects only its own custom account")
        } else if action == "remove" {
            guard SecKeychainOpen(path, &keychain) == errSecSuccess, let keychain else { exit(1) }
            guard SecKeychainDelete(keychain) == errSecSuccess else { exit(1) }
        } else { exit(64) }
    }
}
