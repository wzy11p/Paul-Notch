import Foundation

enum CustomQuotaHTTPClient {
    static func validate(_ request: URLRequest) throws {
        guard request.httpMethod == "GET", request.httpBody == nil, request.httpBodyStream == nil,
              let url = request.url, try CustomQuotaEndpoint.prepare(url.absoluteString) == url,
              request.value(forHTTPHeaderField: "Cookie") == nil,
              !(request.value(forHTTPHeaderField: "Authorization") != nil && request.value(forHTTPHeaderField: "X-API-Key") != nil),
              (request.allHTTPHeaderFields ?? [:]).allSatisfy({ name, value in
                  ["accept", "authorization", "x-api-key"].contains(name.lowercased())
                    && !value.contains("\r") && !value.contains("\n")
              }) else { throw CustomQuotaIssue.endpoint }
    }
    static func fetch(_ request: URLRequest) async throws -> QuotaHTTPResponse {
        try validate(request)
        return try await QuotaHTTPClient.fetchBounded(request, maximumBytes: 262_144)
    }
}
