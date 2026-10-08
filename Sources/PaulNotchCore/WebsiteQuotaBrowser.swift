import AppKit
import WebKit

/// Own quota page. This bridge observes only two MiniMax billing
/// GET responses, Doubao's personal quota rows, or Muse General's usage bars. It never imports or
/// exports credentials, reads chat, submits a form, or invokes a paid API.
@MainActor final class WebsiteQuotaBrowser: NSObject, WebsiteQuotaSession, ObservableObject,
    WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let provider: WebsiteQuotaProvider
    let webView: WKWebView
    @Published private(set) var loginPopup: WKWebView?
    @Published private(set) var error: String?
    var displayedWebView: WKWebView { loginPopup ?? webView }
    private struct Credit { let amount: Double; let observedAt: Date }
    private struct Plan { let reload: String?; let ends: String? }
    private var credits: [String: Credit] = [:]
    private var plans: [String: Plan] = [:]
    private var active = true
    private var reading = false
    private var navigationRevision = 0
    private var museLayoutToken: String?
    private let quotaLoader: (WKWebView, URLRequest) -> Void
    private static let channel = "paulQuotaReadOnly"

    init(provider: WebsiteQuotaProvider, allowsConnections: Bool, loadImmediately: Bool = true,
         profileIdentifier: UUID? = nil, quotaLoader: ((WKWebView, URLRequest) -> Void)? = nil) {
        self.provider = provider
        self.quotaLoader = quotaLoader ?? { view, request in _ = view.load(request) }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        if #available(macOS 14, *), allowsConnections, let profileIdentifier {
            configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: profileIdentifier)
        }
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.suppressesIncrementalRendering = false
        webView = QuotaInteractiveWebView(frame: NSRect(x: 0, y: 0, width: 568, height: 310), configuration: configuration)
        super.init()
        webView.navigationDelegate = self; webView.uiDelegate = self
        if provider.isAudio {
            configuration.userContentController.add(self, name: Self.channel)
            configuration.userContentController.addUserScript(WKUserScript(source: Self.audioReadScript,
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        if provider == .muse {
            configuration.userContentController.addUserScript(WKUserScript(source: Self.museBackgroundLayoutScript,
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        guard allowsConnections else { active = false; error = "隔离验证不会加载账户页面"; return }
        if loadImmediately { self.quotaLoader(webView, URLRequest(url: provider.quotaURL)) }
    }

    func read(reloading: Bool) async throws -> WebsiteQuotaSnapshot {
        guard active, !reading else { throw QuotaConnectionError.unavailable }
        reading = true
        let layoutToken = provider == .muse ? UUID().uuidString : nil
        let preferences = webView.configuration.preferences
        var restoreScheduling: (() -> Void)?
        if #available(macOS 14, *), layoutToken != nil {
            let previous = preferences.inactiveSchedulingPolicy
            preferences.inactiveSchedulingPolicy = .none
            restoreScheduling = { preferences.inactiveSchedulingPolicy = previous }
        }
        museLayoutToken = layoutToken
        defer {
            if let layoutToken { endMuseLayout(layoutToken) }
            restoreScheduling?()
            reading = false
        }
        if reloading {
            credits = [:]; plans = [:]
            // Fixed, known quota route; never a chat page or a login navigation.
            quotaLoader(webView, URLRequest(url: provider.quotaURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15))
        }
        var returnedToMuseQuota = false
        var layoutRevision: Int?
        for attempt in 0..<150 {
            try Task.checkCancellation()
            guard active else { throw CancellationError() }
            if let layoutToken, !webView.isLoading, webView.url.map(provider.permitsCapture) == true,
               layoutRevision != navigationRevision {
                let revision = navigationRevision
                _ = try await webView.evaluateJavaScript("window.__PaulMuseBackgroundLayout?.begin('\(layoutToken)')")
                try Task.checkCancellation()
                guard active else { throw CancellationError() }
                if revision == navigationRevision { layoutRevision = revision }
            }
            if provider == .muse, !returnedToMuseQuota, loginPopup == nil, !webView.isLoading,
               let url = webView.url, url.scheme == "https", url.host == provider.host,
               provider.permitsCapture(url), url.query?.isEmpty != false {
                // The official shell consumes settings_tab after opening the
                // sheet. Reopen only if General has not rendered; otherwise a
                // reload would repeatedly discard a correct completed page.
                let documentRevision = navigationRevision
                let hasGeneral = try await webView.evaluateJavaScript(Self.museGeneralRenderedScript) as? Bool
                let needsLogin = try await webView.evaluateJavaScript(Self.museLoginRequiredScript) as? Bool
                try Task.checkCancellation()
                guard active else { throw CancellationError() }
                guard documentRevision == navigationRevision, webView.url == url,
                      !webView.isLoading, loginPopup == nil else { continue }
                if hasGeneral == false, needsLogin == false {
                    returnedToMuseQuota = true
                    quotaLoader(webView, URLRequest(url: provider.quotaURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15))
                    continue
                }
            }
            if !webView.isLoading, let url = webView.url, provider.permitsCapture(url) {
                if provider == .doubao {
                    let raw = try await webView.evaluateJavaScript(Self.doubaoReadScript)
                    try Task.checkCancellation()
                    if let text = raw as? String, text.utf8.count <= 2048,
                       let data = text.data(using: .utf8),
                       let rows = try? JSONDecoder().decode([ReadRow].self, from: data), rows.count == 2 {
                        return try WebsiteQuotaParser.doubao(rows: rows.map { .init(name: $0.name, usage: $0.usage, timing: $0.timing) }, at: .now)
                    }
                } else if provider == .muse {
                    let documentRevision = navigationRevision
                    let raw = try await webView.evaluateJavaScript(Self.museReadScript)
                    try Task.checkCancellation()
                    if active, documentRevision == navigationRevision,
                       webView.url.map(provider.permitsCapture) == true,
                       let text = raw as? String, text.utf8.count <= 1024,
                       let data = text.data(using: .utf8),
                       let fields = try? JSONDecoder().decode(MuseQuotaRead.self, from: data) {
                        return try fields.snapshot(at: .now)
                    }
                } else {
                    // This identifier was created by our script, not account
                    // state. Old-document response messages cannot publish.
                    let raw = try await webView.evaluateJavaScript("window.__PaulQuotaDocumentID || null")
                    try Task.checkCancellation()
                    if let id = raw as? String, let credit = credits[id], Date().timeIntervalSince(credit.observedAt) <= 90 {
                        let plan = plans[id]
                        if plan != nil || attempt >= 145 {
                            return try WebsiteQuotaParser.audio(amount: credit.amount, reload: plan?.reload, ends: plan?.ends, at: credit.observedAt)
                        }
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        // A blocked/transient navigation is not evidence of revoked login.
        if self.error != nil || webView.isLoading { throw QuotaConnectionError.unavailable }
        if provider == .muse {
            if let url = webView.url, provider.permitsOrigin(url), url.host != provider.host {
                throw QuotaConnectionError.authentication
            }
            if (try? await webView.evaluateJavaScript(Self.museLoginRequiredScript) as? Bool) == true {
                throw QuotaConnectionError.authentication
            }
        } else if let url = webView.url, !provider.permitsCapture(url) { throw QuotaConnectionError.authentication }
        if !webView.isLoading, provider == .doubao, let url = webView.url, provider.permitsCapture(url),
           (try? await webView.evaluateJavaScript(Self.doubaoLoginRequiredScript) as? Bool) == true {
            throw QuotaConnectionError.authentication
        }
        throw QuotaConnectionError.invalidData
    }
    private struct ReadRow: Decodable { let name, usage, timing: String }

    private func endMuseLayout(_ token: String) {
        // The document-side token fences delayed cleanup against a later read.
        webView.evaluateJavaScript("window.__PaulMuseBackgroundLayout?.end('\(token)')", completionHandler: nil)
        if museLayoutToken == token { museLayoutToken = nil }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard active, provider.isAudio, message.name == Self.channel, message.frameInfo.isMainFrame,
              let frameURL = message.frameInfo.request.url, provider.permitsCapture(frameURL),
              let value = message.body as? [String: Any], value.count <= 5,
              let id = value["documentID"] as? String, (8...64).contains(id.count),
              let kind = value["kind"] as? String else { return }
        switch kind {
        case "audioCredit":
            guard let amount = value["amount"] as? NSNumber, CFGetTypeID(amount) != CFBooleanGetTypeID(),
                  (try? WebsiteQuotaParser.audio(amount: amount.doubleValue, reload: nil, ends: nil, at: .now)) != nil else { return }
            if credits.count >= 3 { credits.removeAll() }
            credits[id] = Credit(amount: amount.doubleValue, observedAt: .now)
        case "audioPlan":
            func text(_ key: String) -> String? {
                guard let text = value[key] as? String, !text.isEmpty, text.count <= 120 else { return nil }
                return text
            }
            if plans.count >= 3 { plans.removeAll() }
            plans[id] = Plan(reload: text("reload"), ends: text("ends"))
        default: break
        }
    }
    func stop() {
        if let token = museLayoutToken { endMuseLayout(token) }
        active = false; navigationRevision += 1; credits = [:]; plans = [:]
        closeLoginPopup()
        webView.stopLoading(); webView.navigationDelegate = nil; webView.uiDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.channel)
        webView.configuration.userContentController.removeAllUserScripts()
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        // Only a new, owned child may start with about:blank. Main-page, file,
        // custom-scheme and arbitrary-origin navigation stay denied.
        let ownedBlank = url?.absoluteString == "about:blank" &&
            (webView === loginPopup || navigationAction.targetFrame == nil && trustedSource(navigationAction))
        let permitted = active && (url.map(provider.permitsOrigin) == true || ownedBlank)
        if !permitted {
            let destination = url?.host.map { "（\($0.prefix(80))）" } ?? ""
            error = "已阻止未适配的登录跳转\(destination)。请返回重试；不会自动打开其他应用。"
        }
        decisionHandler(permitted ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(active && navigationResponse.canShowMIMEType ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationRevision += 1; credits = [:]; plans = [:]; error = nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        self.error = "官方页面暂未加载成功，请重试连接；没有使用示例额度。"
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard active, loginPopup == nil, navigationAction.targetFrame == nil,
              trustedSource(navigationAction), configuration.websiteDataStore === self.webView.configuration.websiteDataStore,
              let url = navigationAction.request.url,
              provider.permitsOrigin(url) || url.absoluteString == "about:blank" else {
            error = "该登录窗口未能打开。请返回重试；尚未接通额度。"
            return nil
        }
        // WebKit's supplied configuration preserves the official opener and
        // owned profile (persistent or ephemeral). Loading into the parent and
        // returning nil loses both. A foreign/default profile remains denied.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let child = QuotaInteractiveWebView(frame: webView.bounds, configuration: configuration)
        child.navigationDelegate = self; child.uiDelegate = self
        loginPopup = child; error = nil
        return child
    }
    private func trustedSource(_ action: WKNavigationAction) -> Bool {
        action.sourceFrame.request.url.map(provider.permitsOrigin) == true
    }
    func closeLoginPopup() {
        guard let child = loginPopup else { return }
        child.stopLoading(); child.navigationDelegate = nil; child.uiDelegate = nil
        loginPopup = nil
    }
    func webViewDidClose(_ webView: WKWebView) {
        if webView === loginPopup { closeLoginPopup() }
    }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) { completionHandler(nil) }

    /// Only IDs journaled by this source are supplied, never browser-wide data.
    static func removeOwnedProfile(_ identifier: UUID) async -> Bool {
        guard #available(macOS 14, *) else { return false }
        await clearOwnedProfile(identifier)
        do { try await WKWebsiteDataStore.remove(forIdentifier: identifier); return true }
        catch { return false }
    }
    @available(macOS 14, *) private static func clearOwnedProfile(_ identifier: UUID) async {
        // Release this data-store reference before asking WebKit to remove the
        // profile container. Retaining it makes removal fail as "still in use".
        let dataStore = WKWebsiteDataStore(forIdentifier: identifier)
        await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    static let doubaoLoginRequiredScript = #"""
    (() => {
      if (location.hostname !== 'www.doubao.com' || location.pathname !== '/member/quota-management') return false;
      return Array.from(document.querySelectorAll('button')).slice(0,80).some(e => {
        const text = (e.innerText || '').trim(), r = e.getBoundingClientRect();
        return text === '飞书账号一键登录' && r.width > 0 && r.height > 0 && !e.closest('[aria-hidden="true"],[inert]');
      });
    })()
    """#
    static let doubaoReadScript = #"""
    (() => {
      if (location.hostname !== 'www.doubao.com' || location.pathname !== '/member/quota-management') return null;
      const roots = document.querySelectorAll('[data-testid="personal_quota_view"]');
      if (roots.length !== 1) return null;
      const root = roots[0], rows = [];
      if (root.closest('[aria-hidden="true"],[inert]')) return null;
      for (const name of ['当前时段', '近 7 天']) {
        const labels = Array.from(root.querySelectorAll('div,span')).slice(0,1200)
          .filter(e => !e.children.length && (e.innerText || '').trim().replace(/\s/g,'') === name.replace(/\s/g,''));
        if (labels.length !== 1) return null;
        const label = labels[0], header = label.parentElement, card = header && header.parentElement;
        if (!card || !root.contains(card) || header.children.length !== 2 || card.children.length !== 3) return null;
        const usage = (header.children[1].innerText || '').trim(), timing = (card.children[2].innerText || '').trim();
        if (usage.length > 80 || timing.length > 150 || card.querySelector('input,textarea,[contenteditable="true"]')) return null;
        rows.push({name, usage, timing});
      }
      return JSON.stringify(rows);
    })()
    """#

    /// Observe official page requests without accessing headers, passwords,
    /// Cookies, storage, request bodies, chat responses or other API routes.
    static let audioReadScript = #"""
    (() => {
      if (!['www.minimax.cn','www.minimax.io'].includes(location.hostname) || location.pathname !== '/audio/subscribe') return;
      const documentID = crypto.randomUUID();
      window.__PaulQuotaDocumentID = documentID;
      const creditPath = '/v1/api/audio/billing/credit', planPath = '/v1/api/audio/charge/subscribe/page';
      const allowed = (url, method) => {
        try { const u = new URL(url, location.href); return method.toUpperCase() === 'GET' && u.origin === location.origin && [creditPath,planPath].includes(u.pathname) ? u.pathname : null; } catch { return null; }
      };
      const observed = (path, status, data) => {
        if (status !== 200 || !data || !data.statusInfo || data.statusInfo.code !== 0 || !data.data) return;
        const d = data.data;
        if (path === creditPath) {
          const raw = d.total_credit;
          if (!(typeof raw === 'number' || typeof raw === 'string' && /^\d{1,13}$/.test(raw))) return;
          const amount = Number(raw);
          if (!Number.isSafeInteger(amount) || amount < 0 || amount > 1000000000000) return;
          window.webkit.messageHandlers.paulQuotaReadOnly.postMessage({kind:'audioCredit', documentID, amount});
        } else if (path === planPath && d.current_subscribe) {
          const current = d.current_subscribe;
          const text = v => typeof v === 'string' && v.length <= 120 ? v : null;
          window.webkit.messageHandlers.paulQuotaReadOnly.postMessage({kind:'audioPlan', documentID,
            reload:text(current.current_credit_reload_time), ends:text(current.current_subscribe_end_time)});
        }
      };
      const opens = new WeakMap(), open = XMLHttpRequest.prototype.open, send = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function(method,url,...rest) {
        opens.set(this, allowed(url,method)); return open.call(this,method,url,...rest);
      };
      XMLHttpRequest.prototype.send = function(...args) {
        const path = opens.get(this);
        if (path) this.addEventListener('load', () => {
          try { if (this.responseType !== 'json' && this.responseText.length > 262144) return;
            const data = this.responseType === 'json' ? this.response : JSON.parse(this.responseText); observed(path,this.status,data); } catch {}
        }, {once:true});
        return send.apply(this,args);
      };
      const fetch = window.fetch;
      window.fetch = async function(input,init) {
        const response = await fetch.call(this,input,init);
        const path = allowed(typeof input === 'string' || input instanceof URL ? String(input) : input.url,
          init && init.method || input && input.method || 'GET');
        if (path) response.clone().text().then(text => { if (text.length <= 262144) observed(path,response.status,JSON.parse(text)); }).catch(()=>{});
        return response;
      };
    })();
    """#
}
