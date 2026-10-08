import AppKit
import SwiftUI
@testable import PaulNotchCore

@MainActor private struct UnusedQuotaVault: QuotaCredentialStoring {
    func read() throws -> String? { nil }
    func save(_ value: String) throws { fatalError("Layout checks must not save credentials") }
    func delete() throws { fatalError("Layout checks must not delete credentials") }
}

@main struct QuotaFeedLayoutValidation {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let suite = "test.paul.feed-layout.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = Data(#"{"schemaVersion":1,"checkedAt":"2026-09-27T12:00:00+08:00","monitor":{"status":"healthy"},"events":[{"id":"test-event","type":"direct_reset","status":"confirmed","title":"测试公告","updatedAt":"2026-09-27T12:00:00+08:00","posts":[{"text":"只用于界面验证的公开消息样例"}]}]}"#.utf8)
        let store = QuotaConnectionsStore(defaults: defaults, vault: UnusedQuotaVault(), allowsConnections: true,
                                          transport: { _ in QuotaHTTPResponse(status: 200, data: fixture, etag: nil) })
        store.setFeedEnabled(true)
        for _ in 0..<100 {
            if !store.isFeedRefreshing { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard store.feedSnapshot?.events.count == 1 else { fatalError("Fixture failed to load") }
        let host = NSHostingController(rootView: QuotaResetFeedView(connections: store))
        let size = host.view.fittingSize
        guard size.height >= 380 && size.height <= 620 else {
            print("FAIL: Loaded public feed collapsed its scrolling event viewport: \(size)")
            exit(1)
        }
        store.stop()
        print("PASS: loaded public feed keeps a visible, bounded native popover viewport: \(size)")
    }
}
