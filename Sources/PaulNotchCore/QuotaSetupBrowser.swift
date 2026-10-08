import AppKit
import SwiftUI
import WebKit

/// Official pages are for the owner's manual login/copy only. No DOM injection,
/// cookie import/export, message handlers or bridge to provider credentials.
@MainActor final class QuotaSetupBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let provider: QuotaSetupProvider
    let webView: WKWebView
    @Published private(set) var host: String
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?

    init(provider: QuotaSetupProvider) {
        self.provider = provider
        host = provider.website.host ?? ""
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = QuotaInteractiveWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    func openOfficialPage() {
        // The notch can retain this object across disappearance/reappearance.
        // Restore the security delegates before any navigation can resume.
        webView.navigationDelegate = self
        webView.uiDelegate = self
        guard AppEnvironment.ownedQuotaConnectionsEnabled else {
            error = "隔离预览不会打开账户网站。正式版会在这里显示官方页面。"
            return
        }
        error = nil
        webView.load(URLRequest(url: provider.website))
    }

    func stop() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, provider.permitsNavigation(to: url) else {
            error = "这个链接不属于当前平台。若官网要求第三方登录，请使用下方的登录帮助。"
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        guard navigationResponse.canShowMIMEType else {
            error = "此连接页面不下载文件。请在官网复制 API Key，再粘贴到密钥输入框。"
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true; error = nil
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        host = webView.url?.host ?? provider.website.host ?? ""
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { isLoading = false }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    private func failed(_ failure: Error) {
        isLoading = false
        guard (failure as NSError).code != NSURLErrorCancelled else { return }
        error = "官网暂时没有加载成功。可以重新加载；若官网限制内嵌登录，再使用系统浏览器。"
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, provider.permitsNavigation(to: url) {
            webView.load(navigationAction.request)
        } else {
            error = "官网请求打开其他站点，已暂停。请使用登录帮助中的系统浏览器入口。"
        }
        return nil
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) { completionHandler(nil) }
}

struct QuotaOfficialWebView: NSViewRepresentable {
    let browser: QuotaSetupBrowser
    func makeNSView(context: Context) -> WKWebView { browser.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
