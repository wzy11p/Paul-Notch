import Foundation

/// Explicitly invoked public-feed smoke only. Never reads credentials or personal accounts.
@main struct QuotaConnectionLiveValidation {
    static func main() async throws {
        let response = try await QuotaHTTPClient.fetch(QuotaReadRequest.resetFeed(etag: nil))
        guard response.status == 200 else { throw QuotaConnectionError.unavailable }
        let snapshot = try QuotaResetFeed.decode(response.data)
        print("PASS: app transport decoded the public feed; events=\(snapshot.events.count), monitor=\(snapshot.monitorStatus)")
        guard let etag = response.etag else { throw QuotaConnectionError.invalidData }
        let conditional = try await QuotaHTTPClient.fetch(QuotaReadRequest.resetFeed(etag: etag))
        guard conditional.status == 304 || conditional.status == 200 else { throw QuotaConnectionError.invalidData }
        if conditional.status == 200 { _ = try QuotaResetFeed.decode(conditional.data) }
        print("PASS: conditional read status=\(conditional.status), no credentials/cookies sent")
    }
}
