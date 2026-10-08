import Foundation

enum QuotaConnectionError: Error, LocalizedError, Sendable {
    case invalidData, invalidKey, authentication, rateLimited, unavailable, keychain, keychainLocked, preview
    var errorDescription: String? {
        switch self {
        case .invalidData: "返回数据不完整，保留上次记录，请稍后重试。"
        case .invalidKey: "请填写有效的 API Key，不要包含换行或空格。"
        case .authentication: "授权已失效，请重新填写 API Key。"
        case .rateLimited: "服务暂时限制查询，稍后自动重试。"
        case .unavailable: "暂时无法连接，保留上次记录，请检查网络后重试。"
        case .keychain: "钥匙串操作未获许可或已取消，不会自动再次请求。可主动授权读取，或重新连接。"
        case .keychainLocked: "本机安全存储尚未解锁；解锁后自动恢复，无需重新填写连接。"
        case .preview: "隔离预览不保存或读取真实凭证，请在正式版连接。"
        }
    }
}

struct DeepSeekBalance: Sendable {
    struct Entry: Sendable { let currency: String; let total: Decimal; let granted: Decimal; let toppedUp: Decimal }
    let entries: [Entry]
    let observedAt: Date
    let isAvailable: Bool
    static func decode(_ data: Data, at date: Date) throws -> Self {
        struct Payload: Decodable {
            struct Row: Decodable { let currency, total_balance, granted_balance, topped_up_balance: String }
            let is_available: Bool
            let balance_infos: [Row]
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              !payload.balance_infos.isEmpty, payload.balance_infos.count <= 10,
              Set(payload.balance_infos.map(\.currency)).count == payload.balance_infos.count else {
            throw QuotaConnectionError.invalidData
        }
        func decimal(_ value: String) throws -> Decimal {
            guard value.count <= 40, value.range(of: #"^-?[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
                  let amount = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")), !amount.isNaN else {
                throw QuotaConnectionError.invalidData
            }
            return amount
        }
        let entries = try payload.balance_infos.map { row in
            guard ["CNY", "USD"].contains(row.currency) else { throw QuotaConnectionError.invalidData }
            return try Entry(currency: row.currency, total: decimal(row.total_balance),
                             granted: decimal(row.granted_balance), toppedUp: decimal(row.topped_up_balance))
        }
        return Self(entries: entries, observedAt: date, isAvailable: payload.is_available)
    }
}

enum QuotaReadRequest {
    static func miniMaxWallet(key: String) throws -> URLRequest {
        guard key.hasPrefix("sk-api-"), (12...4096).contains(key.utf8.count),
              key.utf8.allSatisfy({ (33...126).contains($0) }) else { throw QuotaConnectionError.invalidKey }
        var request = base("https://api.minimaxi.com/account/query_balance")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return request
    }
    static func deepSeek(key: String) throws -> URLRequest {
        guard (8...4096).contains(key.utf8.count), key.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw QuotaConnectionError.invalidKey
        }
        var request = base("https://api.deepseek.com/user/balance")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return request
    }
    static func resetFeed(etag: String?) -> URLRequest {
        var request = base("https://aihot.news/api/v1/codex-resets")
        if let etag, etag.utf8.count <= 512, !etag.contains("\r"), !etag.contains("\n") {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        return request
    }
    private static func base(_ url: String) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}

struct QuotaResetFeed: Sendable {
    struct Event: Sendable {
        let id, type, status, title, text: String
        let confirmationBasis: String?
        let updatedAt: Date
        let sourceURL: URL?
        var typeLabel: String { type == "direct_reset" ? "额度重置" : type == "reset_credit" ? "重置卡" : "重置消息" }
        var statusLabel: String {
            if status == "announced" { return "预告 · 时间未确认" }
            if status == "confirmed" { return confirmationBasis == "receipt_review" ? "社区回执核验" : "已有确认消息" }
            return "状态待核对"
        }
    }
    let events: [Event]
    let checkedAt: Date
    let monitorStatus: String
    static func decode(_ data: Data) throws -> Self {
        struct Payload: Decodable {
            struct Monitor: Decodable { let status: String }
            struct Item: Decodable {
                struct Post: Decodable { let text: String?; let originalText: String?; let url: String? }
                let id, type, status, title, updatedAt: String
                let confirmationBasis: String?
                let posts: [Post]
            }
            let schemaVersion: Int
            let checkedAt: String
            let monitor: Monitor
            let events: [Item]
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data), payload.schemaVersion == 1,
              payload.events.count <= 1000, let checkedAt = date(payload.checkedAt),
              Set(payload.events.map(\.id)).count == payload.events.count else { throw QuotaConnectionError.invalidData }
        let events = try payload.events.map { item -> Event in
            guard !item.id.isEmpty, item.id.count <= 256, let updatedAt = date(item.updatedAt) else {
                throw QuotaConnectionError.invalidData
            }
            let source = item.posts.first?.url.flatMap(URL.init(string:))
            let safeSource = source.flatMap { url -> URL? in
                guard url.scheme == "https", ["x.com", "www.x.com", "twitter.com", "www.twitter.com"].contains(url.host ?? ""),
                      url.user == nil, url.password == nil, url.port == nil else { return nil }
                return url
            }
            return Event(id: item.id, type: item.type, status: item.status, title: String(item.title.prefix(300)),
                         text: String((item.posts.first?.text ?? item.posts.first?.originalText ?? "暂无原帖摘要").prefix(3000)),
                         confirmationBasis: item.confirmationBasis, updatedAt: updatedAt, sourceURL: safeSource)
        }.sorted { $0.updatedAt > $1.updatedAt }
        // Deliberately ignore `estimate`: upstream can publish model-inferred dates.
        // A public forecast is never an account reset timestamp or a balance update.
        return Self(events: events, checkedAt: checkedAt, monitorStatus: payload.monitor.status)
    }
    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
