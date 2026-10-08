import Foundation

/// Explicit --live invocation only. Reuses the accepted account-read path; never starts a thread or turn.
@main struct CodexQuotaLiveValidation {
    static func main() async throws {
        let client = IslandCodexAppServerClient()
        do {
            let quota = try await client.readQuota()
            guard !quota.windows.isEmpty, quota.freshness == .fresh else {
                throw IslandCodexClientError.rpc("No fresh quota windows returned")
            }
            await client.stop()
            print("PASS: the located desktop launcher returned fresh account quota through the existing read-only client")
        } catch {
            await client.stop()
            throw error
        }
    }
}
