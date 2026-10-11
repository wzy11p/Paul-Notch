import Foundation
import CoreFoundation

enum CustomQuotaIssue: Error, LocalizedError {
    case endpoint, key, payload, mapping, registry, limit, expired, storage, unsupported
    var errorDescription: String? {
        switch self {
        case .endpoint: "请填写 HTTPS 只读额度接口，不是官网首页或模型生成接口；网址不能含 Key、账号密码或查询参数。"
        case .key: "请粘贴完整 API Key，不要包含空格、换行或登录密码。"
        case .payload: "接口没有返回有效的额度 JSON。请检查官方余额接口及 Key 权限，不会把错误码当成余额。"
        case .mapping: "选中的字段不是有效剩余额度或重置时间。请按平台的字段说明重新选择。"
        case .registry: "本机连接配置无法读取，原记录已保留。请勿反复重连或覆盖。"
        case .limit: "最多可保存 32 个自定义 API 连接，请先移除不再使用的连接。"
        case .expired: "这次验证已过期，请重新读取当前额度后保存。"
        case .storage: "未能完成连接保存，请解锁本机钥匙串后重试。不会把未完成的连接显示为成功。"
        case .unsupported: "暂未适配这个产品的自动额度读取。仅凭官网地址或模型 Key 无法查询会员余额。"
        }
    }
}

enum CustomQuotaAuth: String, Codable, CaseIterable, Identifiable {
    case bearer, apiKey, none
    var id: Self { self }
    var title: String {
        switch self { case .bearer: "Bearer Key"; case .apiKey: "X-API-Key"; case .none: "无需 Key" }
    }
}

enum CustomQuotaUnit: String, Codable, CaseIterable, Identifiable {
    case cny, usd, percent, ratio, credits, tokens
    var id: Self { self }
    var title: String {
        switch self {
        case .cny: "人民币"; case .usd: "美元"; case .percent: "百分比（0–100）"
        case .ratio: "比例（0–1）"; case .credits: "积分"; case .tokens: "Token 数"
        }
    }
}

enum CustomQuotaEndpoint {
    static func prepare(_ text: String) throws -> URL {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 2048, !text.contains(where: { $0.isWhitespace || $0.isNewline }),
              let parts = URLComponents(string: text), parts.scheme == "https",
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port == nil || parts.port == 443, let host = parts.host?.lowercased(),
              host.contains("."), !host.hasSuffix("."), !host.hasSuffix(".local"),
              !host.hasSuffix(".localhost"), !host.contains(":"),
              host.range(of: #"^[a-z0-9-]+(\.[a-z0-9-]+)+$"#, options: .regularExpression) != nil,
              host.split(separator: ".").allSatisfy({ !$0.hasPrefix("-") && !$0.hasSuffix("-") && $0.count <= 63 }),
              host.split(separator: ".").last?.allSatisfy(\.isNumber) == false,
              let decoded = parts.percentEncodedPath.removingPercentEncoding,
              !decoded.contains(where: { $0.isNewline || $0.asciiValue.map { $0 < 32 } == true }),
              !decoded.split(separator: "/").contains(where: { ["..", "."].contains(String($0)) }),
              let url = parts.url else { throw CustomQuotaIssue.endpoint }
        let components = decoded.lowercased().split(separator: "/").map(String.init)
        let forbidden = ["chat", "completions", "responses", "messages", "generate", "generation", "purchase", "delete", "remove", "recharge", "create"]
        guard !components.contains(where: { forbidden.contains($0) }),
              let last = components.last,
              ["balance", "query_balance", "get_balance", "credits", "quota", "usage", "limits", "rate-limits", "subscription", "balance_summary"].contains(last)
        else { throw CustomQuotaIssue.endpoint }
        return url
    }

    static func request(endpoint: String, auth: CustomQuotaAuth, key: String?) throws -> URLRequest {
        let url = try prepare(endpoint)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"; request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if auth != .none {
            guard let key, !key.isEmpty, key.utf8.count <= 8192,
                  key.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }) else { throw CustomQuotaIssue.key }
            request.setValue(auth == .bearer ? "Bearer \(key)" : key,
                             forHTTPHeaderField: auth == .bearer ? "Authorization" : "X-API-Key")
        }
        return request
    }
}

struct CustomQuotaField: Identifiable, Equatable, Sendable {
    let path: String
    var number: Decimal?
    var date: Date?
    var id: String { path }
    var label: String {
        path.split(separator: "/").map { $0.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~") }.joined(separator: " → ")
    }
    var summary: String {
        if let number { return "\(label) · \(NSDecimalNumber(decimal: number).stringValue)" }
        return label
    }
}

struct CustomQuotaMapping: Codable, Equatable, Sendable {
    let remainingPath: String
    var subtractPath: String? = nil
    var resetPath: String? = nil
    let unit: CustomQuotaUnit
}

struct CustomQuotaSnapshot: Sendable, Equatable {
    let amount: Decimal
    let resetsAt: Date?
    let observedAt: Date
    let unit: CustomQuotaUnit
}

/// Only numeric and date leaves survive; raw responses, names, tokens and chat do not.
struct CustomQuotaPayload: Sendable {
    let fields: [CustomQuotaField]
    var numberFields: [CustomQuotaField] { fields.filter { $0.number != nil } }
    var dateFields: [CustomQuotaField] { fields.filter { $0.date != nil } }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 262_144, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              !(root["success"] as? Bool == false), root["error"] == nil || root["error"] is NSNull else { throw CustomQuotaIssue.payload }
        var fields = [CustomQuotaField]()
        func walk(_ value: Any, path: String, depth: Int) throws {
            guard depth <= 8, fields.count <= 128 else { throw CustomQuotaIssue.payload }
            if let object = value as? [String: Any] {
                guard object.count <= 128 else { throw CustomQuotaIssue.payload }
                for key in object.keys.sorted() {
                    guard key.utf8.count <= 128, !key.unicodeScalars.contains(where: { $0.value < 32 }) else { throw CustomQuotaIssue.payload }
                    let escaped = key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
                    try walk(object[key]!, path: path + "/" + escaped, depth: depth + 1)
                }
            } else if let array = value as? [Any] {
                guard array.count <= 16 else { throw CustomQuotaIssue.payload }
                for (index, item) in array.enumerated() { try walk(item, path: path + "/\(index)", depth: depth + 1) }
            } else {
                let text: String?
                if let value = value as? NSNumber {
                    guard CFGetTypeID(value) != CFBooleanGetTypeID() else { return }
                    text = value.stringValue
                } else { text = value as? String }
                guard let text, text.utf8.count <= 64 else { return }
                var number: Decimal?
                if text.range(of: #"^-?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil,
                   let parsed = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
                   !parsed.isNaN, abs(NSDecimalNumber(decimal: parsed).doubleValue) <= 1_000_000_000_000 { number = parsed }
                var date: Date?
                if let number {
                    var seconds = NSDecimalNumber(decimal: number).doubleValue
                    if seconds > 10_000_000_000 { seconds /= 1000 }
                    if (946_684_800...4_102_444_800).contains(seconds) { date = Date(timeIntervalSince1970: seconds) }
                } else if text.contains("T") {
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    date = formatter.date(from: text)
                    if date == nil { formatter.formatOptions = [.withInternetDateTime]; date = formatter.date(from: text) }
                    if let parsed = date, !(946_684_800...4_102_444_800).contains(parsed.timeIntervalSince1970) { date = nil }
                }
                if number != nil || date != nil { fields.append(.init(path: path, number: number, date: date)) }
            }
        }
        try walk(root, path: "", depth: 0)
        guard fields.count <= 128, fields.contains(where: { $0.number != nil }) else { throw CustomQuotaIssue.payload }
        return .init(fields: fields)
    }

    func snapshot(mapping: CustomQuotaMapping, at date: Date) throws -> CustomQuotaSnapshot {
        guard var amount = fields.first(where: { $0.path == mapping.remainingPath })?.number else { throw CustomQuotaIssue.mapping }
        if let path = mapping.subtractPath {
            guard path != mapping.remainingPath, let used = fields.first(where: { $0.path == path })?.number else { throw CustomQuotaIssue.mapping }
            amount -= used
        }
        switch mapping.unit {
        case .percent: guard amount >= 0 && amount <= 100 else { throw CustomQuotaIssue.mapping }
        case .ratio:
            guard amount >= 0 && amount <= 1 else { throw CustomQuotaIssue.mapping }
            amount *= 100
        case .credits, .tokens:
            var raw = amount, rounded = Decimal(); NSDecimalRound(&rounded, &raw, 0, .down)
            guard amount >= 0, amount == rounded else { throw CustomQuotaIssue.mapping }
        case .cny, .usd: break
        }
        guard !amount.isNaN, abs(NSDecimalNumber(decimal: amount).doubleValue) <= 1_000_000_000_000 else { throw CustomQuotaIssue.mapping }
        var reset: Date?
        if let path = mapping.resetPath {
            guard let parsed = fields.first(where: { $0.path == path })?.date else { throw CustomQuotaIssue.mapping }
            reset = parsed
        }
        return .init(amount: amount, resetsAt: reset, observedAt: date, unit: mapping.unit)
    }
}

struct CustomQuotaDefinition: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let endpoint: String
    let auth: CustomQuotaAuth
    let mapping: CustomQuotaMapping

    func validate() throws {
        guard id.hasPrefix("custom-"), let uuid = UUID(uuidString: String(id.dropFirst(7))),
              id == "custom-" + uuid.uuidString.lowercased(), !name.isEmpty, name.count <= 40,
              name == name.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.unicodeScalars.contains(where: { $0.value < 32 }),
              [mapping.remainingPath, mapping.subtractPath, mapping.resetPath].compactMap({ $0 }).allSatisfy({
                  $0.hasPrefix("/") && $0.utf8.count <= 1024 && !$0.unicodeScalars.contains(where: { $0.value < 32 })
              }), mapping.subtractPath != mapping.remainingPath else { throw CustomQuotaIssue.registry }
        _ = try CustomQuotaEndpoint.prepare(endpoint)
    }
}

enum CustomQuotaRegistry {
    private struct Envelope: Codable { let schemaVersion: Int; let definitions: [CustomQuotaDefinition] }
    static func encode(_ definitions: [CustomQuotaDefinition]) throws -> Data {
        guard definitions.count <= 32, Set(definitions.map(\.id)).count == definitions.count else { throw CustomQuotaIssue.registry }
        try definitions.forEach { try $0.validate() }
        let data = try JSONEncoder().encode(Envelope(schemaVersion: 1, definitions: definitions))
        guard data.count <= 131_072 else { throw CustomQuotaIssue.registry }
        return data
    }
    static func decode(_ data: Data) throws -> [CustomQuotaDefinition] {
        guard data.count <= 131_072, let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.schemaVersion == 1 else { throw CustomQuotaIssue.registry }
        _ = try encode(envelope.definitions)
        return envelope.definitions
    }
}
