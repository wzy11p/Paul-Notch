import Foundation

enum QuotaSetupProvider: Equatable {
    case deepSeek, miniMax

    var name: String { self == .deepSeek ? "DeepSeek API" : "MiniMax API" }
    var website: URL {
        URL(string: self == .deepSeek ? "https://platform.deepseek.com/api_keys"
            : "https://platform.minimax.cn/console/access?tab=api-keys")!
    }
    var instruction: String {
        self == .deepSeek ? "登录左侧官网，进入 API keys，创建并复制密钥。"
            : "登录左侧官网，进入 API 密钥，创建并复制普通密钥（sk-api-），不要选 Token Plan。"
    }
    func permitsNavigation(to url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        let roots = self == .deepSeek ? ["deepseek.com"] : ["minimax.cn", "minimaxi.com"]
        return roots.contains { host == $0 || host.hasSuffix("." + $0) }
    }
    func preparedKey(_ value: String) throws -> String {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("sk-") else { throw QuotaConnectionError.invalidKey }
        if self == .deepSeek { _ = try QuotaReadRequest.deepSeek(key: key) }
        else { _ = try QuotaReadRequest.miniMaxWallet(key: key) }
        return key
    }
}
