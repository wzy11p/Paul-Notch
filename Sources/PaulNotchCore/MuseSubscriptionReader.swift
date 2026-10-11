import WebKit

/// A tiny same-origin document uses only Paul's existing WebKit profile.
/// Cookies remain inside WebKit: no cookie import, export, header or key read.
@MainActor final class MuseSubscriptionReader: NSObject, WKNavigationDelegate {
    private let dataStore: WKWebsiteDataStore
    private var webView: WKWebView?
    private var active = true
    init(dataStore: WKWebsiteDataStore) { self.dataStore = dataStore }

    func read(actionID: String?) async throws -> MuseSubscriptionResult {
        guard active, webView == nil else { throw QuotaConnectionError.unavailable }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        webView = view; view.navigationDelegate = self
        defer { stop() }
        view.loadSimulatedRequest(URLRequest(url: URL(string: "https://muse.ai/")!), responseHTML:
            "<html><head><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; connect-src https://muse.ai;\"></head><body></body></html>")
        for _ in 0..<100 {
            try Task.checkCancellation()
            guard active else { throw CancellationError() }
            if !view.isLoading && view.url?.absoluteString == "https://muse.ai/" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard !view.isLoading, view.url?.absoluteString == "https://muse.ai/" else { throw QuotaConnectionError.unavailable }
        let raw = try await view.callAsyncJavaScript(Self.script, arguments: ["cachedActionID": actionID ?? ""],
                                                    in: nil, contentWorld: .defaultClient)
        try Task.checkCancellation()
        guard active, let text = raw as? String, text.utf8.count <= 4096 else { throw QuotaConnectionError.invalidData }
        return try JSONDecoder().decode(MuseSubscriptionResult.self, from: Data(text.utf8))
    }
    func stop() {
        active = false
        webView?.stopLoading(); webView?.navigationDelegate = nil
        webView = nil
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        decisionHandler(active && action.request.url?.absoluteString == "https://muse.ai/" ? .allow : .cancel)
    }
}

struct MuseSubscriptionResult: Decodable {
    let state: String
    let actionID: String?
    let used: Double?
    let resetsAt: Double?
    let renewsAt: Double?
    let plan: String?
    let extra: String?

    func snapshot(at now: Date) throws -> WebsiteQuotaSnapshot {
        guard state == "ok" else {
            if state == "authentication" { throw QuotaConnectionError.authentication }
            throw state == "format" ? QuotaConnectionError.invalidData : QuotaConnectionError.unavailable
        }
        guard let used, let actionID, actionID.range(of: "^[0-9a-f]{40,80}$", options: .regularExpression) != nil else {
            throw QuotaConnectionError.invalidData
        }
        func date(_ seconds: Double?) throws -> Date? {
            guard let seconds else { return nil }
            guard seconds.isFinite, (1_577_836_800...4_102_444_800).contains(seconds) else { throw QuotaConnectionError.invalidData }
            return Date(timeIntervalSince1970: seconds)
        }
        let reset = try date(resetsAt), renewal = try date(renewsAt)
        var value = try WebsiteQuotaParser.muse(used: used, reset: reset.map { ISO8601DateFormatter().string(from: $0) },
            extraBalance: nil, extraDisplay: extra, extraNeverExpires: false, at: now)
        var details = value.details
        if let plan, !plan.isEmpty, plan.count <= 80 { details.append(.init(label: "会员套餐", value: plan)) }
        if let renewal { details.append(.init(label: "订阅续期", value: renewal.formatted(date: .abbreviated, time: .shortened))) }
        details.append(.init(label: "读取方式", value: "Muse 官方订阅查询 · 轻量读取"))
        value = .init(value: value.value, timing: value.timing, details: details, observedAt: now,
                      resetsAt: reset, endsAt: renewal, pools: value.pools, hasExactResetTime: reset != nil)
        return value
    }
}
