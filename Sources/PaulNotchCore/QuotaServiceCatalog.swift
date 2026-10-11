import Foundation

/// Discovery is not connection: aliases never fabricate a connector or balance.
enum QuotaServiceCatalog {
    static func matches(_ account: QuotaOverviewAccount, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return true }
        let aliases: [String: String] = [
            "codex": "openai chatgpt gpt chatgpt.com",
            "cursor": "cursor.com",
            "grok": "grok bot cursor 通过 cursor 计费",
            "doubao": "豆包 工作 doubao.com",
            "muse": "meta muse meta.ai",
            "deepseek": "deepseek.com api.deepseek.com 深度求索",
            "minimax-api": "minimaxi.com minimax.io 海螺 api 钱包",
            "minimax-audio": "minimax.io audio 配音 声贝"
        ]
        return "\(account.name) \(account.account) \(aliases[account.id] ?? "")".lowercased().contains(query)
    }
    static let openRouter = CustomQuotaPreset(
        name: "OpenRouter API", endpoint: "https://openrouter.ai/api/v1/credits", auth: .bearer,
        mapping: .init(remainingPath: "/data/total_credits", subtractPath: "/data/total_usage", unit: .usd),
        keyNote: "需要 OpenRouter 的管理 Key（Management Key），普通模型 Key 没有此余额接口权限。",
        documentation: URL(string: "https://openrouter.ai/docs/api/api-reference/credits/get-credits")!)
    static func showsOpenRouter(query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return query.isEmpty || "openrouter openrouter.ai api".contains(query)
    }
}

struct CustomQuotaPreset {
    let name: String
    let endpoint: String
    let auth: CustomQuotaAuth
    let mapping: CustomQuotaMapping
    let keyNote: String
    let documentation: URL
}
