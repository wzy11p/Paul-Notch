import AppKit
import WebKit
@testable import PaulNotchCore

/// Synthetic quota documents only; no real account or credential is accessed.
@main struct WebsiteQuotaMemoryValidation {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited); NSApp.finishLaunching()
        var amount = 20
        var loaded = 0
        var now = Date()
        weak var lastDocument: WKWebView?
        let browser = WebsiteQuotaBrowser(provider: .doubao, allowsConnections: true,
            loadImmediately: false, quotaLoader: { view, request in
                loaded += 1; lastDocument = view
                view.loadSimulatedRequest(request, responseHTML: document(used: amount))
            })
        let store = WebsiteQuotaStore(provider: .doubao, allowsConnections: true,
            factory: { _ in browser }, clock: { now })
        // The first page represents the owner's deliberate initial login.
        browser.webView.loadSimulatedRequest(URLRequest(url: WebsiteQuotaProvider.doubao.quotaURL),
                                             responseHTML: document(used: amount))
        lastDocument = browser.webView
        store.beginLogin(); store.finishLogin()
        await settle(store)
        try check(store.snapshot?.value == .percent(80), "initial login must verify a real document")
        try await Task.sleep(for: .milliseconds(250))
        try check(lastDocument == nil, "a completed, unmounted login must release its full WebView, not retain the entire website")
        for usage in [35, 50, 0] {
            amount = usage; now = now.addingTimeInterval(31)
            store.refreshDue(); await settle(store)
            try check(store.snapshot?.value == .percent(100 - usage), "background reads must remain fresh at the original 30-second cadence")
            try await Task.sleep(for: .milliseconds(250))
            try check(lastDocument == nil, "each background quota read must release the completed document")
        }
        try check(loaded == 3 && store.enabled && !store.isPresentingLogin,
                  "releasing a document must not disconnect or ask for another login")
        amount = -1; now = now.addingTimeInterval(31)
        store.refreshDue(); await settle(store)
        try await Task.sleep(for: .milliseconds(250))
        try check(lastDocument == nil && store.enabled && !store.needsLogin && store.error != nil,
                  "a malformed response must also release its page without treating it as an expired login")
        amount = 60
        store.refreshDue(force: true); await settle(store)
        try check(store.snapshot?.value == .percent(40) && store.error == nil,
                  "a subsequent valid response must recover automatically without reconnecting")
        store.stop()
        print("PASS: completed website reads release their full document without reducing freshness or forgetting the connection")
    }
    static func document(used: Int) -> String {
        """
        <html><body><div data-testid="personal_quota_view">
        <section><div><span>当前时段</span><span>已用 \(used)%</span></div><div></div><div>2 小时后重置</div></section>
        <section><div><span>近 7 天</span><span>已用 60%</span></div><div></div><div>3 天后重置</div></section>
        </div></body></html>
        """
    }
    @MainActor static func settle(_ store: WebsiteQuotaStore) async {
        for _ in 0..<250 where store.isRefreshing { try? await Task.sleep(for: .milliseconds(100)) }
    }
    static func check(_ valid: Bool, _ message: String) throws {
        if !valid { print("FAIL: \(message)"); exit(1) }
    }
}
