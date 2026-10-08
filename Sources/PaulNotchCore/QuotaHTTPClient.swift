import Foundation

struct QuotaHTTPResponse: Sendable {
    let status: Int
    let data: Data
    let etag: String?
    var retryAfter: TimeInterval? = nil
}

/// No shared cookies, credential storage, redirects, POST requests or unbounded bodies.
enum QuotaHTTPClient {
    private final class RedirectBlocker: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
    }
    static func fetch(_ request: URLRequest) async throws -> QuotaHTTPResponse {
        guard request.httpMethod == "GET", request.httpBody == nil,
              ["https://api.deepseek.com/user/balance", "https://aihot.news/api/v1/codex-resets",
               "https://api.minimaxi.com/account/query_balance"].contains(request.url?.absoluteString ?? "") else {
            throw QuotaConnectionError.invalidData
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 25
        let session = URLSession(configuration: configuration, delegate: RedirectBlocker(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw QuotaConnectionError.invalidData }
        let miniMaxBusinessError = response.statusCode == 400 && request.url?.host == "api.minimaxi.com"
        guard response.statusCode == 200 || miniMaxBusinessError else {
            let delay = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            return QuotaHTTPResponse(status: response.statusCode, data: Data(), etag: nil,
                                     retryAfter: delay.flatMap { $0.isFinite && $0 > 0 ? $0 : nil })
        }
        guard response.mimeType?.lowercased().contains("json") == true, response.expectedContentLength <= 1_048_576 else {
            throw QuotaConnectionError.invalidData
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 1_048_576 else { throw QuotaConnectionError.invalidData }
            data.append(byte)
        }
        return QuotaHTTPResponse(status: response.statusCode, data: data, etag: response.value(forHTTPHeaderField: "ETag"))
    }
}
