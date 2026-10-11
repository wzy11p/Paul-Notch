import Foundation
import Security
import LocalAuthentication

// New, owner-approved storage. No access to legacy services and no interactive
// operation. Preserve these shipped bytes on every ordinary future UI update.
struct Request: Decodable { let operation, service, account: String; let value: String? }
struct Response: Encodable { let status: Int32; let value: String? }
let service = "local.paul.notch.quota.custom-api.v1"
let parentRequirement = #"identifier "local.paul.home-preview-20260905" and certificate leaf = H"b93fcbf197e02d3e8568408d1ecdfc04adf1562e""#
func authorizedParent() -> Bool {
    var parent: SecCode?, requirement: SecRequirement?
    return SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: NSNumber(value: getppid())] as CFDictionary, [], &parent) == errSecSuccess
        && SecRequirementCreateWithString(parentRequirement as CFString, [], &requirement) == errSecSuccess
        && parent != nil && SecCodeCheckValidity(parent!, [], requirement) == errSecSuccess
}
#if CUSTOM_QUOTA_AGENT_FIXTURE
guard CommandLine.arguments.count == 2,
      CommandLine.arguments[1].hasPrefix("/tmp/paul-custom-agent-fixture."),
      CommandLine.arguments[1].hasSuffix("/accounts.keychain") else { exit(64) }
var fixture: SecKeychain?
guard SecKeychainOpen(CommandLine.arguments[1], &fixture) == errSecSuccess else { exit(65) }
#else
guard CommandLine.arguments.count == 1, authorizedParent() else { exit(64) }
#endif
var data = Data()
while let part = try? FileHandle.standardInput.read(upToCount: 4096), !part.isEmpty {
    data.append(part)
    if data.count > 16_384 { exit(64) }
}
guard let request = try? JSONDecoder().decode(Request.self, from: data), request.service == service,
      request.account.hasPrefix("custom-"), let id = UUID(uuidString: String(request.account.dropFirst(7))),
      request.account == "custom-" + id.uuidString.lowercased(), ["read", "save", "delete"].contains(request.operation),
      (request.operation == "save") == (request.value != nil),
      request.value.map({ !$0.isEmpty && $0.utf8.count <= 8192 && $0.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }) }) ?? true
else { exit(64) }
var previous = DarwinBoolean(false)
guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
      SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { exit(65) }
defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
    kSecAttrAccount as String: request.account, kSecAttrSynchronizable as String: false]
#if CUSTOM_QUOTA_AGENT_FIXTURE
query[kSecUseKeychain as String] = fixture
query[kSecMatchSearchList as String] = [fixture!]
#endif
var status: OSStatus = errSecParam
var value: String?
switch request.operation {
case "read":
    let context = LAContext(); context.interactionNotAllowed = true
    query[kSecUseAuthenticationContext as String] = context
    query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecSuccess {
        if let data = result as? Data, !data.isEmpty, data.count <= 8192, let decoded = String(data: data, encoding: .utf8) { value = decoded }
        else { status = errSecDecode }
    }
case "save":
    let bytes = Data(request.value!.utf8)
    status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: bytes] as CFDictionary)
    if status == errSecItemNotFound {
        query[kSecMatchSearchList as String] = nil
        query[kSecValueData as String] = bytes
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        // Default own-helper ACL: never broad trusted applications or ACL removal.
        status = SecItemAdd(query as CFDictionary, nil)
    }
case "delete": status = SecItemDelete(query as CFDictionary)
default: break
}
if status != errSecSuccess && status != errSecItemNotFound {
    var keychain: SecKeychain?
    #if CUSTOM_QUOTA_AGENT_FIXTURE
    keychain = fixture
    #else
    _ = SecKeychainCopyDefault(&keychain)
    #endif
    var state: SecKeychainStatus = 0
    if let keychain, SecKeychainGetStatus(keychain, &state) == errSecSuccess,
       state & UInt32(kSecUnlockStateStatus) == 0 { status = errSecNotAvailable }
}
// Only the authenticated parent's inherited anonymous pipe carries a secret.
try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(Response(status: status, value: value)))
