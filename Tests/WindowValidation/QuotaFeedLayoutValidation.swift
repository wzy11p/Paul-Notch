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
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 460, height: 230),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: QuotaResetFeedView(connections: store))
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let scrolls = scrollViews(in: host)
        guard let scroll = scrolls.first, scroll.contentView.bounds.height >= 80,
              scroll.frame.height <= host.bounds.height else {
            print("FAIL: Public events need a visible scrolling viewport inside the compact panel")
            exit(1)
        }
        guard host.bounds.width == 460 && host.bounds.height == 230 else {
            print("FAIL: Public feed must not enlarge its parent window")
            exit(1)
        }
        if let destination = ProcessInfo.processInfo.environment["PAUL_PREVIEW_DIRECTORY"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination).appendingPathComponent("reset-feed-native.png"))
        }
        store.stop()
        print("PASS: public events scroll inside a 460×230 native page without a popover or oversized window")
    }
    @MainActor static func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }
}
