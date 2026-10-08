import Foundation

@main struct QuotaSetupSafetyValidation {
    static func main() throws {
        let cases: [(QuotaSetupProvider, String, Bool)] = [
            (.deepSeek, "https://platform.deepseek.com/api_keys", true),
            (.miniMax, "https://platform.minimaxi.com/user-center/basic-information/interface-key", true),
            (.miniMax, "https://platform.minimax.cn/console/access?tab=api-keys", true),
            (.deepSeek, "https://platform.deepseek.com.evil.example/api_keys", false),
            (.deepSeek, "https://evil-deepseek.com", false),
            (.deepSeek, "http://platform.deepseek.com", false),
            (.deepSeek, "https://user:password@platform.deepseek.com", false),
            (.deepSeek, "https://platform.deepseek.com:8443", false),
            (.deepSeek, "file:///etc/passwd", false),
            (.deepSeek, "javascript:alert(1)", false),
            (.deepSeek, "https://platform.minimax.cn", false),
            (.miniMax, "https://platform.minimax.cn.evil.example", false)
        ]
        for (provider, address, allowed) in cases {
            guard provider.permitsNavigation(to: URL(string: address)!) == allowed else {
                print("FAIL: official-page navigation must reject untrusted origins, schemes, ports and embedded credentials")
                exit(1)
            }
        }
        guard try QuotaSetupProvider.deepSeek.preparedKey("  sk-test-only-key\n") == "sk-test-only-key",
              try QuotaSetupProvider.miniMax.preparedKey("\nsk-api-test-only-key ") == "sk-api-test-only-key" else {
            print("FAIL: explicit paste should trim surrounding whitespace without modifying the credential")
            exit(1)
        }
        for value in ["", "a password", "https://platform.minimax.cn", "sk-cp-test-only", "sk-api-with space"] {
            do { _ = try QuotaSetupProvider.miniMax.preparedKey(value); print("FAIL: reject an unrelated clipboard value"); exit(1) }
            catch QuotaConnectionError.invalidKey {}
        }
        print("PASS: trusted in-app navigation and explicit clipboard credential validation")
    }
}
