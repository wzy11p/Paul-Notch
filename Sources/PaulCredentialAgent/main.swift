import Foundation
import Security
import LocalAuthentication

// Protocol v1 deliberately stays byte-for-byte unchanged across ordinary Paul
// updates. Keychain partitions bind a locally signed client to its binary hash.
// Only the pinned Paul parent may invoke it; no socket, file, log or telemetry.
struct Request: Decodable { let operation: String; let service: String; let value: String? }
struct Response: Encodable { let status: Int32; let value: String? }
let services = Set(["local.paul.notch.quota.deepseek.v1", "local.paul.notch.quota.minimax-cn-wallet.v1", "local.paul.notch.quota.cursor-account.v1"])
let parentRequirement = #"identifier "local.paul.home-preview-20260905" and certificate leaf = H"b93fcbf197e02d3e8568408d1ecdfc04adf1562e""#
func authorizedParent() -> Bool {
    var requirement: SecRequirement?; var parent: SecCode?
    let attributes = [kSecGuestAttributePid as String: NSNumber(value: getppid())] as CFDictionary
    return SecRequirementCreateWithString(parentRequirement as CFString, [], &requirement) == errSecSuccess &&
        SecCodeCopyGuestWithAttributes(nil, attributes, [], &parent) == errSecSuccess &&
        parent != nil && SecCodeCheckValidity(parent!, [], requirement) == errSecSuccess
}
#if CREDENTIAL_AGENT_FIXTURE
// This mode exists only in a separately compiled isolated test binary. It can
// use only a private temporary Keychain; it never queries the login Keychain.
guard CommandLine.arguments.count == 2,
      CommandLine.arguments[1].hasPrefix("/tmp/paul-agent-fixture.") else { exit(64) }
var fixtureKeychain: SecKeychain?
guard SecKeychainOpen(CommandLine.arguments[1], &fixtureKeychain) == errSecSuccess else { exit(65) }
#else
guard CommandLine.arguments.count == 1, authorizedParent() else { exit(64) }
#endif
func boundedInput() -> Data? {
    var data = Data()
    while let part = try? FileHandle.standardInput.read(upToCount: 4096), !part.isEmpty {
        data.append(part)
        if data.count > 65_536 { return nil }
    }
    return data
}
guard let input = boundedInput(), input.count <= 65_536,
      let request = try? JSONDecoder().decode(Request.self, from: input), services.contains(request.service),
      ["read", "authorize", "save", "rotate", "delete"].contains(request.operation),
      request.value.map({ !$0.isEmpty && $0.utf8.count <= 60_000 }) ?? true,
      (["save", "rotate"].contains(request.operation) == (request.value != nil)) else { exit(64) }
var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: request.service,
    kSecAttrAccount as String: "primary", kSecAttrSynchronizable as String: false]
#if CREDENTIAL_AGENT_FIXTURE
query[kSecUseKeychain as String] = fixtureKeychain
query[kSecMatchSearchList as String] = [fixtureKeychain!]
#endif
var previous = DarwinBoolean(false)
let interactive = request.operation == "authorize" || request.operation == "save" || request.operation == "delete"
guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
      SecKeychainSetUserInteractionAllowed(interactive) == errSecSuccess else { exit(65) }
defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
var status: OSStatus = errSecParam
var value: String?
switch request.operation {
case "read", "authorize":
    let context = LAContext(); context.interactionNotAllowed = !interactive
    query[kSecUseAuthenticationContext as String] = context
    query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecSuccess, let data = result as? Data, data.count <= 60_000 {
        value = String(data: data, encoding: .utf8)
        if value == nil { status = errSecDecode }
    }
case "save", "rotate":
    let bytes = Data(request.value!.utf8)
    status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: bytes] as CFDictionary)
    if status == errSecItemNotFound {
        query[kSecMatchSearchList as String] = nil
        query[kSecValueData as String] = bytes
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        status = SecItemAdd(query as CFDictionary, nil)
    }
case "delete": status = SecItemDelete(query as CFDictionary)
default: break
}
if status != errSecSuccess && status != errSecItemNotFound {
    var keychain: SecKeychain?
    #if CREDENTIAL_AGENT_FIXTURE
    keychain = fixtureKeychain
    #else
    _ = SecKeychainCopyDefault(&keychain)
    #endif
    var state: SecKeychainStatus = 0
    if let keychain, SecKeychainGetStatus(keychain, &state) == errSecSuccess,
       state & UInt32(kSecUnlockStateStatus) == 0 { status = errSecNotAvailable }
}
// Only the inherited anonymous pipe to the authenticated parent carries data.
let response = try JSONEncoder().encode(Response(status: status, value: value))
try FileHandle.standardOutput.write(contentsOf: response)
