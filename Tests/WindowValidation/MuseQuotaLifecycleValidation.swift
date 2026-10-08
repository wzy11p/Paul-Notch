import AppKit
import WebKit
import SwiftUI
@testable import PaulNotchCore

@MainActor private final class MuseSourceFixture: WebsiteQuotaSession {
    var used = 29.0
    var reloads: [Bool] = []
    var failure: QuotaConnectionError?
    var reset: String?
    func read(reloading: Bool) async throws -> WebsiteQuotaSnapshot {
        reloads.append(reloading)
        if let failure { throw failure }
        return try WebsiteQuotaParser.muse(used: used, reset: reset, extraBalance: nil,
            extraDisplay: nil, extraNeverExpires: false, at: .now)
    }
    func stop() {}
}

@main struct MuseQuotaLifecycleValidation {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited); NSApp.finishLaunching()
        let suite = "local.paul.muse-fixture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var made: [(WebsiteQuotaProvider, UUID, MuseSourceFixture)] = []
        var now = Date()
        func make() -> WebsiteQuotaStore {
            WebsiteQuotaStore(provider: .muse, allowsConnections: true,
                factory: { _ in MuseSourceFixture() }, defaults: defaults,
                persistentFactory: { provider, id in
                    let source = MuseSourceFixture(); made.append((provider, id, source)); return source
                }, clock: { now })
        }
        let initial = make()
        try check(!initial.enabled && made.isEmpty, "Unconnected Muse must not open a page or create a saved login by appearing")
        initial.beginLogin(); initial.finishLogin(); await settle(initial)
        try check(initial.enabled && initial.account(now: .now).group == .membership && initial.account(now: .now).kind == .membership,
                  "Verified Muse quota must be a membership, never the Audio wallet")
        try check(initial.account(now: .now).id == "muse" && initial.account(now: .now).value == .percent(71),
                  "Muse canonical Home must publish its real source, not a catalog placeholder")
        let firstID = made[0].1
        made[0].2.used = 43
        now = now.addingTimeInterval(31)
        initial.refreshDue(); await settle(initial)
        try check(initial.account(now: .now).value == .percent(57) && !initial.isPresentingLogin && made.count == 1,
                  "A hidden connection page keeps reading changed source values without opening a login")
        initial.beginLogin(); made.last!.2.failure = .authentication
        initial.finishLogin(); await settle(initial)
        try check(!initial.needsLogin && initial.account(now: .now).displayValue == "57%",
                  "A rejected replacement login must not invalidate the already verified Muse account")
        initial.cancelLogin()
        initial.stop()
        let cold = make()
        try check(cold.enabled && cold.snapshot == nil, "Cold start retains login but cannot show yesterday's quota as current")
        cold.refreshDue(); await settle(cold)
        try check(made.last?.1 == firstID && cold.account(now: .now).value == .percent(71) && !cold.isPresentingLogin,
                  "A new store restores the same Muse profile and queries without repeating first setup")
        made.last!.2.failure = .unavailable
        cold.refreshDue(force: true); await settle(cold)
        try check(cold.enabled && cold.account(now: .now).displayValue == "—" && !cold.needsLogin,
                  "A temporary network failure hides current values but cannot erase or expire saved login")
        made.last!.2.failure = nil
        made.last!.2.reset = "2026-01-01T00:00:00Z"
        cold.refreshDue(force: true); await settle(cold)
        try check(cold.account(now: .now).displayValue == "—" && cold.enabled && !cold.needsLogin,
                  "A newly loaded but pre-reset source cannot display last cycle's quota as current")
        cold.stop()

        // The owner explicitly finishes first login, but a renderer/transport
        // failure must not discard that login just because quota is unverified.
        let retrySuite = "local.paul.muse-retry-fixture.\(UUID().uuidString)"
        let retryDefaults = UserDefaults(suiteName: retrySuite)!
        defer { retryDefaults.removePersistentDomain(forName: retrySuite) }
        var retryMade: [(UUID, MuseSourceFixture)] = []
        func retryStore() -> WebsiteQuotaStore {
            .init(provider: .muse, allowsConnections: true, factory: { _ in MuseSourceFixture() },
                  defaults: retryDefaults, persistentFactory: { _, id in
                      let source = MuseSourceFixture(); retryMade.append((id, source)); return source
                  }, clock: { now })
        }
        let unread = retryStore()
        unread.beginLogin(); let unreadID = retryMade[0].0
        retryMade[0].1.failure = .invalidData
        unread.finishLogin(); await settle(unread)
        try check(!unread.enabled && unread.snapshot == nil, "Finished authentication without verified quota must not claim connected or show fake values")
        now = now.addingTimeInterval(601); unread.refreshDue()
        try check(unread.isPresentingLogin, "Explicitly finished Muse login must not be wiped by the abandoned-form ten-minute timer")
        unread.stop()
        let retryAfterUpdate = retryStore()
        retryAfterUpdate.refreshDue(); await settle(retryAfterUpdate)
        try check(retryMade.count == 2 && retryMade.last?.0 == unreadID && retryAfterUpdate.enabled &&
                  retryAfterUpdate.snapshot?.value == .percent(71) && !retryAfterUpdate.isPresentingLogin,
                  "A quota-read repair/relaunch must retry the same first-login profile silently, not require another account login")
        retryAfterUpdate.disconnect()

        let readRetry = retryStore()
        readRetry.beginLogin(); retryMade.last!.1.failure = .invalidData
        readRetry.finishLogin(); await settle(readRetry)
        retryMade.last!.1.failure = nil; retryMade.last!.1.used = 52
        now = now.addingTimeInterval(31)
        readRetry.refreshDue(); await settle(readRetry)
        try check(readRetry.enabled && readRetry.snapshot?.value == .percent(48) && !readRetry.isPresentingLogin,
                  "Completed Muse login retries a transient quota failure on the existing cadence, even after the setup view hides")
        readRetry.disconnect()

        let cancelled = retryStore()
        cancelled.beginLogin(); retryMade.last!.1.failure = .invalidData
        cancelled.finishLogin(); await settle(cancelled); cancelled.cancelLogin(); cancelled.stop()
        let madeBeforeCancelRestore = retryMade.count
        let afterCancel = retryStore(); afterCancel.refreshDue(); await settle(afterCancel)
        try check(!afterCancel.enabled && retryMade.count == madeBeforeCancelRestore,
                  "Explicit cancel/disconnect still removes unverified Muse login; it cannot resurrect on restart")

        // Real WebKit with a synthetic document. No owner account or network.
        let browser = WebsiteQuotaBrowser(provider: .muse, allowsConnections: true, loadImmediately: false)
        defer { browser.stop() }
        browser.webView.loadSimulatedRequest(URLRequest(url: WebsiteQuotaProvider.muse.quotaURL), responseHTML: page(used: 27))
        try await document(browser.webView)
        let read = try await browser.read(reloading: false)
        try check(read.value == .percent(73) && read.timing == "每周限额将在 10月10日重置",
                  "Actual owned quota DOM must supply its used percentage and date-only reset without an invented clock")
        try check(read.details.contains { $0.label == "额外余额（页面显示）" && $0.value == "剩余 2.5 万个词元" },
                  "Extra token display must stay independent and retain the page's rounding")
        let sourceStore = WebsiteQuotaStore(provider: .muse, allowsConnections: true, factory: { _ in browser })
        sourceStore.beginLogin(); sourceStore.finishLogin(); await settle(sourceStore)
        let sourceHost = NSHostingView(rootView: AnyView(WebsiteQuotaConnectionView(store: sourceStore)))
        sourceHost.sizingOptions = []
        let sourceWindow = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 760, height: 620),
            styleMask: [.borderless], backing: .buffered, defer: false)
        sourceWindow.isReleasedWhenClosed = false; sourceWindow.alphaValue = 0
        sourceWindow.contentView = sourceHost; sourceWindow.orderBack(nil); sourceHost.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        try check(browser.webView.window === sourceWindow && sourceStore.enabled &&
                  !sourceStore.isPresentingLogin && sourceStore.candidateBrowser == nil,
                  "The established Muse setup must show its existing quota browser without starting a replacement login")
        sourceHost.rootView = AnyView(EmptyView()); sourceWindow.orderOut(nil); sourceWindow.close()
        // Official Muse consumes settings_tab using history.replaceState after
        // opening General. A completed rendered quota is still the same source.
        _ = try await browser.webView.evaluateJavaScript("history.replaceState({}, '', '/'); null;")
        do {
            let afterDeepLink = try await browser.read(reloading: false)
            try check(afterDeepLink.value == .percent(73),
                      "Consumed General deep link must not discard already rendered personal quota")
        } catch {
            try check(false, "Consumed General deep link must not discard already rendered personal quota: \(error)")
        }
        _ = try await browser.webView.evaluateJavaScript("document.querySelector('[role=progressbar]').setAttribute('aria-busy','true'); null;")
        let busy = try await browser.webView.evaluateJavaScript(WebsiteQuotaBrowser.museReadScript)
        try check(busy is NSNull, "Busy progress with retained old captions must not look fresh")
        _ = try await browser.webView.evaluateJavaScript("const loginLabel = document.createElement('button'); loginLabel.textContent = '登录'; document.body.append(loginLabel); null;")
        let falseExpiry = try await browser.webView.evaluateJavaScript(WebsiteQuotaBrowser.museLoginRequiredScript) as? Bool
        try check(falseExpiry == false, "An unrelated login label on a loaded settings page must not invalidate the saved Muse account")
        _ = try await browser.webView.evaluateJavaScript("document.querySelector('[role=progressbar]').removeAttribute('aria-valuenow'); document.querySelector('[role=progressbar]').removeAttribute('aria-busy'); null;")
        let missing = try await browser.webView.evaluateJavaScript(WebsiteQuotaBrowser.museReadScript)
        try check(missing is NSNull, "Missing progress cannot become the framework's default zero or 100 percent")
        browser.webView.loadSimulatedRequest(URLRequest(url: WebsiteQuotaProvider.muse.quotaURL), responseHTML: "<html><body><textarea>Private chat is not quota</textarea><h2>Usage</h2><div role=progressbar aria-valuenow=0></div></body></html>")
        try await document(browser.webView)
        let unrelated = try await browser.webView.evaluateJavaScript(WebsiteQuotaBrowser.museReadScript)
        try check(unrelated is NSNull, "A chat quoting quota text cannot pass the settings and weekly-caption gates")
        browser.webView.loadSimulatedRequest(URLRequest(url: URL(string: "https://muse.ai/")!),
            responseHTML: "<html><body><form><input placeholder='手机号或邮箱' autocomplete='username'><button>登录</button></form></body></html>")
        try await document(browser.webView)
        let genuineLogin = try await browser.webView.evaluateJavaScript(WebsiteQuotaBrowser.museLoginRequiredScript) as? Bool
        try check(genuineLogin == true, "Only an actual anonymous login form indicates deliberate reauthentication is needed")
        let anonymousScheduler = try await browser.webView.evaluateJavaScript("typeof window.__PaulMuseBackgroundLayout") as? String
        try check(anonymousScheduler == "undefined", "A login/root page must never install the quota-only frame scheduler")

        let mobileGeneral = page(used: 38)
            .replacingOccurrences(of: "aria-label=\"通用\"", with: "aria-labelledby=\"general-title\"")
            .replacingOccurrences(of: "<h1>通用</h1>", with: "<div><span id=\"general-title\">通用</span></div>")
        browser.webView.loadSimulatedRequest(URLRequest(url: URL(string: "https://muse.ai/")!), responseHTML: mobileGeneral)
        try await document(browser.webView)
        let mobileRead = try await browser.webView.evaluateJavaScript(WebsiteQuotaBrowser.museReadScript) as? String
        try check(mobileRead.flatMap { $0.data(using: .utf8) }.flatMap {
            try? JSONDecoder().decode(MuseQuotaRead.self, from: $0)
        }?.used == 38, "Mobile General sheet title is a labeled span, not necessarily an h1/h2")

        // Public General renders Usage's heading and SettingsCard as siblings
        // in the full settings content. Appearance contains real radio inputs;
        // those are not part of the personal Usage card.
        browser.webView.loadSimulatedRequest(URLRequest(url: URL(string: "https://muse.ai/")!),
            responseHTML: siblingCardPage(used: 19))
        try await document(browser.webView)
        let siblingRead = try await browser.webView.evaluateJavaScript(WebsiteQuotaBrowser.museReadScript) as? String
        try check(siblingRead.flatMap { $0.data(using: .utf8) }.flatMap {
            try? JSONDecoder().decode(MuseQuotaRead.self, from: $0)
        }?.used == 19, "Official Usage sibling card must be read without treating unrelated Appearance radio inputs as quota editors")
        _ = try await browser.webView.evaluateJavaScript("document.querySelector('[data-slot=\"settings-card-item\"]').append(document.createElement('input')); null;")
        let quotaEditor = try await browser.webView.evaluateJavaScript(WebsiteQuotaBrowser.museReadScript)
        try check(quotaEditor is NSNull, "An editor within the quota card still rejects capture; unrelated General preferences alone do not")
        browser.webView.loadSimulatedRequest(URLRequest(url: URL(string: "https://muse.ai/")!),
            responseHTML: page(used: 61).replacingOccurrences(of: "role=\"dialog\" aria-label=\"通用\"", with: "id=\"chat-fixture\""))
        try await document(browser.webView)
        let quotedQuota = try await browser.webView.evaluateJavaScript(WebsiteQuotaBrowser.museReadScript)
        try check(quotedQuota is NSNull, "Cleared root cannot turn chat-quoted complete quota markup into personal settings usage")

        var returnedRequests: [URLRequest] = []
        let returned = WebsiteQuotaBrowser(provider: .muse, allowsConnections: true, loadImmediately: false,
            quotaLoader: { view, request in
                returnedRequests.append(request)
                view.loadSimulatedRequest(request, responseHTML: mobileGeneral + "<script>history.replaceState({}, '', '/')</script>")
            })
        defer { returned.stop() }
        returned.webView.loadSimulatedRequest(URLRequest(url: URL(string: "https://muse.ai/")!),
            responseHTML: "<html><body><div role='dialog' aria-label='设置'><button>通用</button><button>连接器</button></div></body></html>")
        try await document(returned.webView)
        do {
            let returnedRead = try await returned.read(reloading: false)
            try check(returnedRead.value == .percent(62) && returnedRequests.count == 1 &&
                      returnedRequests.first?.url == WebsiteQuotaProvider.muse.quotaURL,
                      "SSO Settings root must reopen the known quota route once, then accept its consumed General deep link")
        } catch {
            try check(false, "SSO Settings root must reopen General without requesting another login: \(error)")
        }

        var servedUsed = 33
        var requests: [URLRequest] = []
        let hidden = WebsiteQuotaBrowser(provider: .muse, allowsConnections: true, loadImmediately: false,
            quotaLoader: { view, request in
                requests.append(request)
                view.loadSimulatedRequest(request, responseHTML: page(used: servedUsed))
            })
        defer { hidden.stop() }
        let firstRead = try await hidden.read(reloading: true)
        servedUsed = 47
        let changedRead = try await hidden.read(reloading: true)
        try check(firstRead.value == .percent(67) && changedRead.value == .percent(53) &&
                  requests.count == 2 && requests.allSatisfy {
                      $0.url == WebsiteQuotaProvider.muse.quotaURL && $0.cachePolicy == .reloadIgnoringLocalCacheData
                  } && !NSApp.isActive && hidden.loginPopup == nil,
                  "Real hidden WebKit refresh must load a new uncached quota document, update its source, and never activate or open a popup")

        // The real site hydrates General after the HTML load completes. A
        // fully rendered static fixture cannot catch detached-view suspension.
        let hydrated = WebsiteQuotaBrowser(provider: .muse, allowsConnections: true, loadImmediately: false,
            quotaLoader: { view, request in
                let markup = try! JSONSerialization.data(withJSONObject: [page(used: 51)])
                let encoded = String(data: markup, encoding: .utf8)!
                view.loadSimulatedRequest(request, responseHTML:
                    "<html><body><script>setTimeout(() => { document.body.innerHTML = (\(encoded))[0]; }, 250);</script></body></html>")
            })
        defer { hydrated.stop() }
        do {
            let hydratedRead = try await hydrated.read(reloading: true)
            try check(hydratedRead.value == .percent(49) && hydrated.webView.window == nil && !NSApp.isActive,
                      "Detached background Muse must finish asynchronous General hydration without opening a window or taking focus")
        } catch {
            try check(false, "Detached background Muse must finish asynchronous General hydration: \(error)")
        }

        let frameHydrated = WebsiteQuotaBrowser(provider: .muse, allowsConnections: true, loadImmediately: false,
            quotaLoader: { view, request in
                let markup = try! JSONSerialization.data(withJSONObject: [page(used: 58)])
                let encoded = String(data: markup, encoding: .utf8)!
                view.loadSimulatedRequest(request, responseHTML:
                    """
                    <html><body><script>
                    window.fixtureFrames = 0; window.fixtureCancelled = false;
                    const cancelled = requestAnimationFrame(() => { window.fixtureCancelled = true; });
                    cancelAnimationFrame(cancelled);
                    requestAnimationFrame(() => requestAnimationFrame(() => {
                      window.fixtureFrames += 1; document.body.innerHTML = (\(encoded))[0];
                      const loop = () => { window.fixtureFrames += 1; requestAnimationFrame(loop); };
                      requestAnimationFrame(loop);
                    }));
                    </script></body></html>
                    """)
            })
        defer { frameHydrated.stop() }
        do {
            let frameRead = try await frameHydrated.read(reloading: true)
            try check(frameRead.value == .percent(42) && frameHydrated.webView.window == nil && !NSApp.isActive,
                      "Background Muse must complete frame-scheduled General layout without a window or foreground activation")
            let framesAfterRead = try await frameHydrated.webView.evaluateJavaScript("window.fixtureFrames") as? Int
            try await Task.sleep(for: .milliseconds(150))
            let framesLater = try await frameHydrated.webView.evaluateJavaScript("window.fixtureFrames") as? Int
            let cancelledRan = try await frameHydrated.webView.evaluateJavaScript("window.fixtureCancelled") as? Bool
            try check(framesAfterRead == framesLater && (framesAfterRead ?? 0) > 0 && cancelledRan == false,
                      "Cancelled frames never fire, and completed quota reads cannot leave an offscreen animation loop running")
            if #available(macOS 14, *) {
                try check(frameHydrated.webView.configuration.preferences.inactiveSchedulingPolicy == .suspend,
                          "Every completed Muse read restores WebKit's ordinary low-power scheduling policy")
            }
            let cleanupFence = try await frameHydrated.webView.evaluateJavaScript("""
              (() => { const s = window.__PaulMuseBackgroundLayout;
                return s.begin('fixture-new-read') && !s.end('fixture-old-read') && s.end('fixture-new-read'); })()
            """) as? Bool
            try check(cleanupFence == true, "A delayed old-read cleanup cannot stop a newer quota read")
        } catch {
            try check(false, "Background Muse frame-scheduled General layout stalls: \(error)")
        }

        let cancelledRead = WebsiteQuotaBrowser(provider: .muse, allowsConnections: true, loadImmediately: false,
            quotaLoader: { view, request in
                view.loadSimulatedRequest(request, responseHTML: """
                  <html><body><script>window.fixtureFrames = 0;
                  const loop = () => { window.fixtureFrames++; requestAnimationFrame(loop); };
                  requestAnimationFrame(loop);</script></body></html>
                """)
            })
        defer { cancelledRead.stop() }
        let interrupted = Task { try await cancelledRead.read(reloading: true) }
        try await Task.sleep(for: .milliseconds(350))
        interrupted.cancel()
        do { _ = try await interrupted.value; try check(false, "An interrupted read cannot publish quota") }
        catch is CancellationError {}
        let cancelledFrames = try await cancelledRead.webView.evaluateJavaScript("window.fixtureFrames") as? Int
        try await Task.sleep(for: .milliseconds(150))
        let cancelledFramesLater = try await cancelledRead.webView.evaluateJavaScript("window.fixtureFrames") as? Int
        try check(cancelledFrames == cancelledFramesLater && !NSApp.isActive,
                  "Cancelling a hidden read must stop fallback animation work without focus changes")
        if #available(macOS 14, *) {
            try check(cancelledRead.webView.configuration.preferences.inactiveSchedulingPolicy == .suspend,
                      "Cancellation restores normal WebKit inactive policy just like successful reads")
        }

        // The temporary structural probe was useful for diagnosis, but is not
        // part of the retained account reader's production data contract.
        let failedRead = WebsiteQuotaBrowser(provider: .muse, allowsConnections: true, loadImmediately: false,
            quotaLoader: { view, request in
                view.loadSimulatedRequest(request, responseHTML: "<html><body>No quota fixture</body></html>")
            })
        defer { failedRead.stop() }
        do { _ = try await failedRead.read(reloading: true); try check(false, "Missing quota cannot publish a value") }
        catch QuotaConnectionError.invalidData {}
        let probeFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("paul-muse-structure-\(ProcessInfo.processInfo.processIdentifier).json")
        try check(!FileManager.default.fileExists(atPath: probeFile.path),
                  "A failed production Muse read must not leave an investigation sidecar file")

        print("PASS: Muse source changes while hidden, same-profile cold restore, offline retention, real WebKit quota-only capture and loading rejection")
    }
    static func page(used: Int) -> String {
        """
        <html><head><style>[role=progressbar]{height:6px;width:200px}</style></head><body><main role="dialog" aria-label="通用"><h1>通用</h1><section><h2>使用情况</h2>
          <div><p>测试套餐 每周限额将在 10月10日重置 已使用 \(used)%</p>
            <div role="progressbar" aria-label="测试套餐" aria-valuenow="\(used)" aria-valuemin="0" aria-valuemax="100"></div></div>
          <div><p>额外的使用额度 从不过期 已使用 0%（剩余 2.5 万个词元）</p>
            <div role="progressbar" aria-label="额外的使用额度" aria-valuenow="0" aria-valuemin="0" aria-valuemax="100"></div></div>
        </section></main><aside>Unrelated price plan 100%; chat 99%</aside></body></html>
        """
    }
    static func siblingCardPage(used: Int) -> String {
        """
        <html><head><style>[role=progressbar]{height:6px;width:200px}</style></head><body>
        <main role="dialog" aria-labelledby="general-title"><h2 id="general-title">通用</h2>
          <div><button>Meta 账户</button><h2>使用情况</h2>
            <div><div><div data-slot="settings-card-item"><div><div>
              <div><p>测试套餐 每周限额将在 10月10日重置 已使用 \(used)%</p>
                <div role="progressbar" aria-valuenow="\(used)" aria-valuemin="0" aria-valuemax="100"></div></div>
              <div><p>额外的使用额度 从不过期 已使用 0%（剩余 3 亿个词元）</p>
                <div role="progressbar" aria-valuenow="0" aria-valuemin="0" aria-valuemax="100"></div></div>
            </div><button>升级</button></div></div></div></div>
            <button>语言</button><h2>外观</h2><div role="radiogroup" aria-label="主题颜色"><input type="radio" name="fixture-theme"></div>
          </div>
        </main><aside>Unrelated chat 99%</aside></body></html>
        """
    }
    @MainActor static func document(_ view: WKWebView) async throws {
        for _ in 0..<200 {
            if !view.isLoading, view.url != nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw QuotaConnectionError.unavailable
    }
    @MainActor static func settle(_ store: WebsiteQuotaStore) async {
        for _ in 0..<200 where store.isRefreshing { try? await Task.sleep(for: .milliseconds(10)) }
    }
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { print("FAIL: \(message)"); fflush(nil); exit(1) }
    }
}
