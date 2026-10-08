import Foundation
import CryptoKit

/// Protocol facts verified against the installed official Cursor/Grok clients.
/// Implements a new owned login, never imports their credential files or Cookies.
struct CursorQuotaLoginAttempt: Sendable {
    let id: UUID
    let verifier: String
    let challenge: String
    let deadline: Date
    init(at date: Date) {
        id = UUID()
        let key = SymmetricKey(size: .bits256)
        verifier = key.withUnsafeBytes { Self.urlBase64(Data($0)) }
        challenge = Self.urlBase64(Data(SHA256.hash(data: Data(verifier.utf8))))
        deadline = date.addingTimeInterval(600)
    }
    var loginURL: URL {
        var url = URLComponents(string: "https://cursor.com/loginDeepControl")!
        url.queryItems = [.init(name: "challenge", value: challenge), .init(name: "uuid", value: id.uuidString),
                          .init(name: "mode", value: "login"), .init(name: "redirectTarget", value: "cli")]
        return url.url!
    }
    private static func urlBase64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

struct CursorQuotaTokenPair: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    func validated() throws -> Self {
        for value in [accessToken, refreshToken] {
            guard (8...16_384).contains(value.utf8.count), value.utf8.allSatisfy({ (33...126).contains($0) }) else {
                throw QuotaConnectionError.authentication
            }
        }
        return self
    }
    static func decodeLogin(_ data: Data) throws -> Self {
        guard data.count <= 65_536, let pair = try? JSONDecoder().decode(Self.self, from: data) else {
            throw QuotaConnectionError.authentication
        }
        return try pair.validated()
    }
    var serialized: String { get throws { String(decoding: try JSONEncoder().encode(self), as: UTF8.self) } }
    var expiresAt: Date? {
        let parts = accessToken.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        struct Claims: Decodable { let exp: Double? }
        guard let bytes = Data(base64Encoded: encoded), let claims = try? JSONDecoder().decode(Claims.self, from: bytes),
              let exp = claims.exp, exp.isFinite, (1_577_836_800...4_102_444_800).contains(exp) else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}

enum CursorQuotaRequest {
    static let monthlyPath = "/aiserver.v1.DashboardService/GetCurrentPeriodUsage"
    static let weeklyPath = "/aiserver.v1.DashboardService/GetSandUsageStatus"
    static func poll(_ attempt: CursorQuotaLoginAttempt) -> URLRequest {
        var url = URLComponents(string: "https://api2.cursor.sh/auth/poll")!
        url.queryItems = [.init(name: "uuid", value: attempt.id.uuidString), .init(name: "verifier", value: attempt.verifier)]
        return base(url.url!, method: "GET")
    }
    static func usage(_ provider: DesktopQuotaProvider, accessToken: String) throws -> URLRequest {
        guard [.cursor, .grok].contains(provider), (8...16_384).contains(accessToken.utf8.count),
              accessToken.utf8.allSatisfy({ (33...126).contains($0) }) else { throw QuotaConnectionError.invalidData }
        var request = base(URL(string: "https://api2.cursor.sh" + (provider == .cursor ? monthlyPath : weeklyPath))!, method: "POST")
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        return request
    }
    static func refresh(_ pair: CursorQuotaTokenPair) throws -> URLRequest {
        _ = try pair.validated()
        var request = base(URL(string: "https://api2.cursor.sh/oauth/token")!, method: "POST")
        // Public native-client identifier, not a client secret or account credential.
        request.httpBody = try JSONSerialization.data(withJSONObject: ["client_id": "KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB",
            "grant_type": "refresh_token", "refresh_token": pair.refreshToken])
        return request
    }
    private static func base(_ url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.httpMethod = method; request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("PaulNotch/1.0 QuotaReadOnly", forHTTPHeaderField: "User-Agent")
        return request
    }
    static func permits(_ request: URLRequest) -> Bool {
        guard let url = request.url, url.scheme == "https", url.host == "api2.cursor.sh", url.port == nil,
              url.user == nil, url.password == nil, url.fragment == nil, !request.httpShouldHandleCookies else { return false }
        if url.path == "/auth/poll" {
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            return request.httpMethod == "GET" && request.httpBody == nil && query.count == 2 &&
                Set(query.map(\.name)) == ["uuid", "verifier"] &&
                query.first(where: { $0.name == "uuid" })?.value.flatMap(UUID.init(uuidString:)) != nil &&
                query.first(where: { $0.name == "verifier" })?.value?.range(of: #"^[A-Za-z0-9_-]{43,128}$"#, options: .regularExpression) != nil
        }
        guard request.httpMethod == "POST", url.query == nil, let body = request.httpBody else { return false }
        if [monthlyPath, weeklyPath].contains(url.path) {
            return body == Data("{}".utf8) && request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true
        }
        if url.path == "/oauth/token", body.count <= 65_536,
           let data = try? JSONSerialization.jsonObject(with: body) as? [String: String] {
            return Set(data.keys) == ["client_id", "grant_type", "refresh_token"] &&
                data["client_id"] == "KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB" && data["grant_type"] == "refresh_token"
        }
        return false
    }
}

enum CursorQuotaParser {
    static func parse(_ provider: DesktopQuotaProvider, data: Data, at date: Date) throws -> DesktopQuotaSnapshot {
        guard data.count <= 262_144 else { throw QuotaConnectionError.invalidData }
        let decoder = JSONDecoder()
        func pool(_ name: String, _ used: Double?) throws -> DesktopQuotaPool {
            guard let used, used.isFinite, (0...10_000).contains(used) else { throw QuotaConnectionError.invalidData }
            return .init(name: name, used: used)
        }
        switch provider {
        case .cursor:
            struct Monthly: Decodable {
                struct Plan: Decodable { let autoPercentUsed, apiPercentUsed: Double? }
                let planUsage: Plan?
                let billingCycleEnd: String?
                let enabled: Bool?
            }
            guard let source = try? decoder.decode(Monthly.self, from: data), source.enabled != false,
                  let plan = source.planUsage else { throw QuotaConnectionError.invalidData }
            var pools: [DesktopQuotaPool] = []
            if let used = plan.autoPercentUsed { pools.append(try pool("Cursor Models", used)) }
            if let used = plan.apiPercentUsed { pools.append(try pool("Other Models", used)) }
            guard !pools.isEmpty else { throw QuotaConnectionError.invalidData }
            var reset: Date?
            if let raw = source.billingCycleEnd {
                guard let millis = Double(raw), millis.isFinite, (1_577_836_800_000...4_102_444_800_000).contains(millis) else {
                    throw QuotaConnectionError.invalidData
                }
                reset = Date(timeIntervalSince1970: millis / 1000)
            }
            return .init(pools: pools, resetLabel: nil, observedAt: date, resetsAt: reset,
                         sourceName: "Cursor 官方账号 GetCurrentPeriodUsage")
        case .grok:
            struct Weekly: Decodable {
                let usagePercent: Double?
                let nextResetTimestampUtc: String?
                let usesPooledEnterpriseAllowance: Bool?
            }
            guard let source = try? decoder.decode(Weekly.self, from: data), source.usesPooledEnterpriseAllowance != true else {
                throw QuotaConnectionError.invalidData
            }
            var reset: Date?
            if let raw = source.nextResetTimestampUtc {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                reset = formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
                guard let reset, (1_577_836_800...4_102_444_800).contains(reset.timeIntervalSince1970) else {
                    throw QuotaConnectionError.invalidData
                }
            }
            return .init(pools: [try pool("每周额度", source.usagePercent)], resetLabel: nil, observedAt: date,
                         resetsAt: reset, sourceName: "Cursor 官方账号 GetSandUsageStatus · Grok Bot")
        case .doubao: throw QuotaConnectionError.invalidData
        }
    }
}

/// A separate, closed allowlist: POST here means authentication or the two
/// verified read-only RPCs. The existing wallet/feed GET transport stays unchanged.
enum CursorQuotaHTTPClient {
    private final class RedirectBlocker: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
    }
    static func fetch(_ request: URLRequest) async throws -> QuotaHTTPResponse {
        guard CursorQuotaRequest.permits(request) else { throw QuotaConnectionError.invalidData }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 12; configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration, delegate: RedirectBlocker(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw QuotaConnectionError.invalidData }
        let retry = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            .flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        guard response.statusCode == 200 else { return .init(status: response.statusCode, data: Data(), etag: nil, retryAfter: retry) }
        guard response.mimeType?.lowercased().contains("json") == true, response.expectedContentLength <= 262_144 else {
            throw QuotaConnectionError.invalidData
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 262_144 else { throw QuotaConnectionError.invalidData }
            data.append(byte)
        }
        return .init(status: response.statusCode, data: data, etag: nil, retryAfter: retry)
    }
}
