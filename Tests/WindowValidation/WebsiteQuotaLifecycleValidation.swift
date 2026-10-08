import AppKit
import WebKit
import SwiftUI
@testable import PaulNotchCore

@MainActor private final class WebsiteFixtureSession: WebsiteQuotaSession {
    var reads = 0
    var stops = 0
    var amount = 12.0
    var rejects = false
    var delayed = false
    func read(reloading: Bool) async throws -> WebsiteQuotaSnapshot {
        reads += 1
        let captured = amount
        if delayed { try? await Task.sleep(for: .milliseconds(80)) }
        if rejects { throw QuotaConnectionError.unavailable }
        return .init(value: .percent(Int(captured)), timing: "fixture reset", details: [], observedAt: .now)
    }
    func stop() { stops += 1 }
}
@MainActor private final class WebsiteFixtureFactory {
    var sessions: [WebsiteFixtureSession] = []
    func make(_ provider: WebsiteQuotaProvider) -> any WebsiteQuotaSession {
        let session = WebsiteFixtureSession(); sessions.append(session); return session
    }
}

@main struct WebsiteQuotaLifecycleValidation {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited); NSApp.finishLaunching()
        var failures = 0
        func check(_ condition: Bool, _ message: String) { if !condition { failures += 1; print("FAIL: \(message)") } }
        var now = Date()
        let factory = WebsiteFixtureFactory()
        let store = WebsiteQuotaStore(provider: .doubao, allowsConnections: true, factory: factory.make, clock: { now })
        store.refreshDue(force: true)
        check(factory.sessions.isEmpty && !store.enabled, "Default/off state creates no browser, request, password or credential access")
        store.beginLogin()
        check(factory.sessions.count == 1 && !store.enabled, "Opening a login page must not be counted as a connected quota")
        store.finishLogin(); await settle(store)
        check(store.enabled && store.snapshot?.value == .percent(12), "Only a verified own-page source enables the card")
        store.cancelLogin() // Like closing the setup route after successful login.
        factory.sessions[0].amount = 83
        now = now.addingTimeInterval(31)
        store.refreshDue(); await settle(store)
        check(store.snapshot?.value == .percent(83) && factory.sessions.count == 1,
              "Closing the quota login view retains an owned session; background source changes replace data without new windows")
        store.beginLogin(); factory.sessions[1].rejects = true
        store.finishLogin(); await settle(store)
        check(store.enabled && store.account(now: .now).status == .current && store.snapshot?.value == .percent(83),
              "A failed replacement login must preserve the existing verified connection and its healthy presentation")
        store.cancelLogin()
        factory.sessions[0].delayed = true
        let before = factory.sessions[0].reads
        for _ in 0..<10 { store.refreshDue(force: true) }
        store.stop()
        try await Task.sleep(for: .milliseconds(130))
        check(factory.sessions[0].reads <= before + 1 && !store.enabled && store.snapshot == nil && factory.sessions[0].stops == 1,
              "Coalesce repeated refresh; stopping/disconnect rejects late callbacks and destroys owned login RAM")
        let isolated = WebsiteQuotaStore(provider: .miniMaxCN, allowsConnections: false, factory: factory.make)
        isolated.beginLogin(); isolated.finishLogin(); isolated.refreshDue(force: true)
        check(factory.sessions.count == 2, "Preview cannot start an owned account page")
        let pendingFactory = WebsiteFixtureFactory()
        let pending = WebsiteQuotaStore(provider: .doubao, allowsConnections: true, factory: pendingFactory.make, clock: { now })
        pending.beginLogin()
        var disappeared = false
        let host = NSHostingView(rootView: AnyView(WebsiteQuotaConnectionView(store: pending).onDisappear { disappeared = true }))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 600, height: 438),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0
        window.contentView = host; window.orderBack(nil); host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.rootView = AnyView(EmptyView())
        for _ in 0..<100 where !disappeared { try await Task.sleep(for: .milliseconds(10)) }
        check(disappeared && pending.isPresentingLogin && pendingFactory.sessions[0].stops == 0,
              "Actual SwiftUI setup disappearance must retain unfinished login when the notch hides or the owner switches apps")
        pending.cancelLogin()
        check(!pending.isPresentingLogin && pendingFactory.sessions[0].stops == 1,
              "Only explicit cancel destroys an unfinished owned login, with no change to other accounts")
        pending.beginLogin()
        now = now.addingTimeInterval(601)
        pending.refreshDue()
        check(!pending.isPresentingLogin && pendingFactory.sessions[1].stops == 1 && pending.loginError?.contains("超时") == true,
              "Abandoned owned login expires after ten minutes instead of retaining an indefinite hidden session")
        pending.stop(); window.orderOut(nil); window.close()
        guard failures == 0 else { exit(1) }

        // Actual WebKit, with a simulated HTTPS document and in-memory fake fetch.
        // No account, Cookie, shared browser or real network request is involved.
        let audio = WebsiteQuotaBrowser(provider: .miniMaxCN, allowsConnections: true, loadImmediately: false)
        let fixtureFetch = #"""
        window.fetch = async function(input) {
          const path = new URL(input,location.href).pathname;
          const data = path.includes('/credit') ? {total_credit:0, api_wallet:999, token:'DO-NOT-EXPORT'} :
            {current_subscribe:{current_credit_reload_time:'2026-10-03 12:00',current_subscribe_end_time:'2026-11-01 12:00',password:'DO-NOT-EXPORT'}};
          return new Response(JSON.stringify({statusInfo:{code:0},data}),{status:200});
        };
        """#
        let controller = audio.webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: fixtureFetch, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: WebsiteQuotaBrowser.audioReadScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        audio.webView.loadSimulatedRequest(URLRequest(url: WebsiteQuotaProvider.miniMaxCN.quotaURL), responseHTML: "<html><body>Price plan: 1,000,000 credits. Default UI: 0</body></html>")
        try await waitDocument(audio.webView)
        _ = try await audio.webView.evaluateJavaScript("fetch('/v1/api/audio/billing/credit'); fetch('/v1/api/audio/charge/subscribe/page'); null;")
        try await Task.sleep(for: .milliseconds(100))
        let confirmedZero = try await audio.read(reloading: false)
        check(confirmedZero.value == .credits(0, unit: "声贝") && confirmedZero.details.contains(where: { $0.label == "声贝重置" }),
              "Actual WebKit captures only completed billing credit and current subscription responses, not page example totals or API money")
        check(!WebsiteQuotaBrowser.audioReadScript.contains("localStorage") && !WebsiteQuotaBrowser.audioReadScript.contains("document.cookie"),
              "Owned-page bridge cannot access stored credentials or Cookies")
        audio.stop()
        check(!audio.webView.configuration.websiteDataStore.isPersistent && controller.userScripts.isEmpty,
              "Website session is ephemeral and stop removes its capture bridge")

        let doubao = WebsiteQuotaBrowser(provider: .doubao, allowsConnections: true, loadImmediately: false)
        doubao.webView.loadSimulatedRequest(URLRequest(url: WebsiteQuotaProvider.doubao.quotaURL), responseHTML: """
        <html><body><div>Chat: 99%</div><div data-testid="personal_quota_view">
          <div><div><div>当前时段</div><div>已用 13%</div></div><div></div><div>2 小时后重置</div></div>
          <div><div><div>近 7 天</div><div>未消耗</div></div><div></div><div>开始使用后计时</div></div>
        </div></body></html>
        """)
        try await waitDocument(doubao.webView)
        let rows = try await doubao.read(reloading: false)
        check(rows.value == .percent(87) && !rows.details.contains(where: { $0.value == "99%" }),
              "Actual DOM capture is restricted to the verified personal quota component and both separately named windows")
        let feishuAuthorization = URL(string: "https://accounts.feishu.cn/open-apis/authen/v1/authorize?client_id=fixture")!
        doubao.webView.loadSimulatedRequest(URLRequest(url: feishuAuthorization),
                                           responseHTML: "<html><body>Official authentication fixture, not personal quota</body></html>")
        try? await waitDocument(doubao.webView)
        check(doubao.webView.url?.host == "accounts.feishu.cn" && doubao.error == nil,
              "Actual WebKit navigation must admit Doubao's verified Feishu authentication instead of stopping on its old page")
        doubao.stop()
        let popupLogin = WebsiteQuotaBrowser(provider: .doubao, allowsConnections: true, loadImmediately: false)
        // Test-only user-gesture substitute, on a synthetic document. Production
        // automatic popups remain disabled. There is no real login or network.
        popupLogin.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        popupLogin.webView.loadSimulatedRequest(URLRequest(url: WebsiteQuotaProvider.doubao.quotaURL),
            responseHTML: "<html><body>Owned login fixture</body></html>")
        try await waitDocument(popupLogin.webView)
        let hasPopup = try await popupLogin.webView.evaluateJavaScript("""
            window.fixturePopup = window.open('about:blank', '_blank');
            Boolean(window.fixturePopup);
            """) as? Bool
        check(hasPopup == true && popupLogin.webView.url == WebsiteQuotaProvider.doubao.quotaURL,
              "Official login popup must have a real child context and retain its opener, not load into or discard the original quota page")
        if hasPopup == true {
            let child = popupLogin.loginPopup
            check(child != nil && child!.configuration.websiteDataStore === popupLogin.webView.configuration.websiteDataStore &&
                  !child!.configuration.websiteDataStore.isPersistent,
                  "Authentication child uses the same ephemeral owned session, never another browser's cookies or disk store")
            let hasOpener = try await popupLogin.webView.evaluateJavaScript("Boolean(window.fixturePopup.opener)") as? Bool
            check(hasOpener == true, "Authentication callback keeps official opener semantics without exporting credentials to Swift")
            _ = try await popupLogin.webView.evaluateJavaScript("window.fixturePopup.close(); null;")
            for _ in 0..<100 where popupLogin.loginPopup != nil { try await Task.sleep(for: .milliseconds(10)) }
            check(popupLogin.loginPopup == nil && child?.navigationDelegate == nil && child?.uiDelegate == nil,
                  "Official popup close returns to the retained quota page and detaches child delegates")
        }
        popupLogin.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let outsidePopup = try await popupLogin.webView.evaluateJavaScript(
            "Boolean(window.open('https://outside-paul-login.invalid/', '_blank'))") as? Bool
        check(outsidePopup == false && popupLogin.loginPopup == nil,
              "An unrelated popup remains denied even when the synthetic fixture permits JavaScript window creation")
        popupLogin.stop()
        guard failures == 0 else { exit(1) }
        print("PASS: owned website lifecycle, closed-view background source change, no false replacement, cancellation, real WebKit narrow capture, real zero and ephemeral isolation")
    }
    @MainActor static func settle(_ store: WebsiteQuotaStore) async {
        for _ in 0..<200 where store.isRefreshing { try? await Task.sleep(for: .milliseconds(10)) }
    }
    @MainActor static func waitDocument(_ webView: WKWebView) async throws {
        for _ in 0..<200 {
            if !webView.isLoading, webView.url != nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw QuotaConnectionError.unavailable
    }
}
