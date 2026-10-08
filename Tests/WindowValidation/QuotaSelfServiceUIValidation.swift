import AppKit
import SwiftUI
import Vision
import WebKit
@testable import PaulNotchCore

@MainActor private final class IsolatedConnectionVault: QuotaCredentialStoring {
    var rejectsRead = false
    private(set) var readCount = 0
    func read() throws -> String? {
        readCount += 1
        if rejectsRead { throw QuotaConnectionError.keychain }
        return nil
    }
    func save(_ value: String) throws { throw QuotaConnectionError.preview }
    func delete() throws {}
}

@main struct QuotaSelfServiceUIValidation {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.finishLaunching()
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let suite = "test.paul.self-service.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let connections = QuotaConnectionsStore(defaults: defaults, vault: IsolatedConnectionVault(),
                                               allowsConnections: false, transport: { _ in
            throw QuotaConnectionError.preview
        }, miniMax: MiniMaxWalletStore(defaults: defaults, vault: IsolatedConnectionVault(),
                                      allowsConnections: false, transport: { _ in throw QuotaConnectionError.preview }),
            desktop: DesktopQuotaStore(defaults: defaults, allowsReads: false, reader: { _, _ in
                throw DesktopQuotaFailure.preview
            }))
        let codex = CodexStatusStore()
        let home = QuotaHomeView(codexStatus: codex, connections: connections, tools: [],
                                 onSelectTool: { _ in }, onClose: {})
        let homeText = try renderText(home, to: output.appendingPathComponent("self-service-home.png"))
        guard homeText.contains("连接") else {
            print("FAIL: Home must expose a visible Add Service control without opening an account first")
            exit(1)
        }
        let accounts = QuotaHomePresentation.accounts(snapshot: nil, error: nil, readsEnabled: false, now: .now)
        func manager(_ id: String?, store: QuotaConnectionsStore = connections) -> some View {
            QuotaServiceConnectionsView(connections: store, accounts: accounts,
                selectedProvider: .constant(id), codexReadsEnabled: false, isCodexRefreshing: false,
                onCheckCodex: {}, onClose: {})
        }
        let muse = try renderText(manager("muse"), to: output.appendingPathComponent("self-service-muse.png"))
        guard muse.contains("Meta Muse"), muse.contains("尚不能自动同步"),
              !muse.contains("保存并查询余额"), !muse.contains("粘贴 Key") else {
            print("FAIL: Muse setup must identify the actual desktop membership and explain the missing source without accepting an unrelated API Key")
            exit(1)
        }
        let catalog = try renderText(manager(nil), to: output.appendingPathComponent("self-service-catalog.png"))
        guard catalog.contains("可直接连接"), catalog.contains("暂不支持自动同步") else {
            print("FAIL: setup must separate working connectors from unsupported memberships before the user chooses")
            exit(1)
        }
        guard catalog.contains("DeepSeek"), catalog.contains("API Key"), catalog.contains("Codex") else {
            print("FAIL: the catalog must show the actual key and local-login connection choices")
            exit(1)
        }
        let keyForm = try renderText(manager("deepseek"), to: output.appendingPathComponent("self-service-key.png"))
        guard keyForm.contains("在这里获取"), keyForm.contains("粘贴") else {
            print("FAIL: a new API connection must expose in-app key acquisition and an explicit paste action, not only an external website link")
            exit(1)
        }
        guard keyForm.contains("连接充值余额"), keyForm.contains("保存并查询余额") else {
            print("FAIL: the key form and submission action must fit without scrolling")
            exit(1)
        }
        defaults.set(true, forKey: "quota.deepseek.enabled.v1")
        let configured = QuotaConnectionsStore(defaults: defaults, vault: IsolatedConnectionVault(),
                                               allowsConnections: true, transport: { _ in
            throw QuotaConnectionError.preview
        })
        let replacement = try renderText(manager("deepseek", store: configured),
                                         to: output.appendingPathComponent("self-service-replace-key.png"))
        guard replacement.contains("保存并查询余额"), replacement.contains("替换") else {
            print("FAIL: an existing connection must not hide the manual key entry or account replacement warning")
            exit(1)
        }
        let miniMax = try renderText(manager("minimax-api"), to: output.appendingPathComponent("self-service-minimax.png"))
        guard miniMax.contains("API Key"), miniMax.contains("连接并查询余额"), miniMax.contains("人民币") else {
            print("FAIL: MiniMax API wallet must provide real key input and a balance-query action, not an unsupported link")
            exit(1)
        }
        let unsupported = try renderText(manager("minimax-audio"), to: output.appendingPathComponent("self-service-unsupported.png"))
        guard unsupported.contains("尚不支持自动同步"), !unsupported.contains("保存并查询余额") else {
            print("FAIL: unsupported providers must not accept unrelated credentials or pretend to connect")
            exit(1)
        }
        let local = try renderText(manager("codex"), to: output.appendingPathComponent("self-service-local.png"))
        guard local.contains("连接本机"), local.contains("Codex"), local.contains("重新检查") else {
            print("FAIL: local-account setup must provide an explicit check action")
            print("Fixture OCR: \(local)")
            exit(1)
        }
        for provider in DesktopQuotaProvider.allCases {
            let windowCount = NSApp.windows.count
            let text = try renderText(manager(provider.rawValue), to: output.appendingPathComponent("desktop-\(provider.rawValue).png"))
            guard text.contains("连接并读取额度"), text.contains("不用 API Key"), text.contains("额度页") else {
                print("FAIL: membership setup must make the real read action and source understandable inside the notch")
                exit(1)
            }
            guard NSApp.windows.filter({ $0.isVisible }).count == 0, NSApp.windows.count <= windowCount + 1 else {
                print("FAIL: opening membership setup must not create a standalone user-facing window")
                exit(1)
            }
        }
        let nativeConnectors = QuotaConnectionsStore(defaults: defaults, vault: IsolatedConnectionVault(),
            allowsConnections: false, transport: { _ in throw QuotaConnectionError.preview },
            cursorAccount: CursorQuotaAccountStore(defaults: defaults, vault: IsolatedConnectionVault(),
                allowsConnections: true, transport: { _ in .init(status: 404, data: Data(), etag: nil, retryAfter: nil) }),
            websiteMemberships: [
                "doubao": WebsiteQuotaStore(provider: .doubao, allowsConnections: true,
                    factory: { WebsiteQuotaBrowser(provider: $0, allowsConnections: false) }),
                "minimax-audio": WebsiteQuotaStore(provider: .miniMaxCN, allowsConnections: true,
                    factory: { WebsiteQuotaBrowser(provider: $0, allowsConnections: false) }),
                "muse": WebsiteQuotaStore(provider: .muse, allowsConnections: true,
                    factory: { WebsiteQuotaBrowser(provider: $0, allowsConnections: false) })])
        let museLogin = try renderText(manager("muse", store: nativeConnectors),
            to: output.appendingPathComponent("owned-muse-login.png"))
        let compactMuse = museLogin.filter { !$0.isWhitespace }
        guard compactMuse.contains("登录Muse"), !compactMuse.contains("中国站"),
              !compactMuse.contains("尚不能自动同步"), !compactMuse.contains("APIKey") else {
            print("FAIL: owned Muse needs its own visible first-login action, not Audio region selection or a dead help screen")
            exit(1)
        }
        let ownedMuse = nativeConnectors.websiteMemberships["muse"]!
        ownedMuse.beginLogin()
        let musePending = try renderText(manager("muse", store: nativeConnectors),
            to: output.appendingPathComponent("owned-muse-waiting.png"))
        guard musePending.filter({ !$0.isWhitespace }).contains("登录完成，读取额度"),
              ownedMuse.candidateBrowser?.provider == .muse else {
            print("FAIL: Muse's embedded official login and explicit verification must use Muse, never a MiniMax account")
            exit(1)
        }
        ownedMuse.cancelLogin()
        for id in ["cursor", "grok"] {
            let text = try renderText(manager(id, store: nativeConnectors), to: output.appendingPathComponent("owned-\(id)-login.png"))
            guard text.contains("Chrome"), text.contains("登录并连接"), text.filter({ !$0.isWhitespace }).contains("30秒") else {
                print("FAIL: Cursor/Grok must expose a visible Chrome login action, not silently start only an embedded page")
                print("Fixture OCR: \(text)")
                exit(1)
            }
        }
        nativeConnectors.cursorAccount!.beginLogin()
        let pendingLogin = try renderText(manager("cursor", store: nativeConnectors),
                                          to: output.appendingPathComponent("owned-cursor-waiting.png"))
        let compactPending = pendingLogin.filter { !$0.isWhitespace }
        guard compactPending.contains("重新打开Chrome"), compactPending.contains("复制登录链接"),
              compactPending.contains("取消连接") else {
            print("FAIL: Chrome retry/copy/cancel must be visible above the fold while waiting; a nested website cannot bury the actions")
            print("Fixture OCR: \(pendingLogin)")
            exit(1)
        }
        nativeConnectors.cursorAccount!.cancelLogin()
        for id in ["doubao", "minimax-audio"] {
            let text = try renderText(manager(id, store: nativeConnectors), to: output.appendingPathComponent("owned-\(id)-login.png"))
            guard text.contains("在这里登录并连接"), text.filter({ !$0.isWhitespace }).contains("30秒"), !text.contains("打开官方入口") else {
                print("FAIL: a website membership needs an in-panel owned-login action, not a link-only unsupported screen")
                exit(1)
            }
        }
        let pendingWebsite = nativeConnectors.websiteMemberships["doubao"]!
        pendingWebsite.beginLogin()
        let pendingWebsiteText = try renderText(manager("doubao", store: nativeConnectors),
            to: output.appendingPathComponent("owned-doubao-waiting.png"))
        let compactWebsite = pendingWebsiteText.filter { !$0.isWhitespace }
        guard compactWebsite.contains("登录后读取并开始同步"), compactWebsite.contains("取消本次登录"),
              compactWebsite.contains("10分钟"), pendingWebsite.isPresentingLogin else {
            print("FAIL: unfinished website login and explicit cancel must remain visible and survive native setup disappearance")
            print("Fixture OCR: \(pendingWebsiteText)")
            exit(1)
        }
        pendingWebsite.cancelLogin()
        guard !CursorQuotaBrowserLauncher.permits(URL(string: "https://cursor.com.evil.invalid/loginDeepControl")!),
              !CursorQuotaBrowserLauncher.permits(URL(string: "file:///private/tmp/fake-login")!),
              WebsiteQuotaProvider.miniMaxCN.permitsCapture(WebsiteQuotaProvider.miniMaxCN.quotaURL),
              !WebsiteQuotaProvider.miniMaxCN.permitsCapture(WebsiteQuotaProvider.miniMaxGlobal.quotaURL) else {
            print("FAIL: owned official login surfaces must retain exact origins and separate China/international accounts")
            exit(1)
        }
        let blockedVault = IsolatedConnectionVault()
        blockedVault.rejectsRead = true
        defaults.set(true, forKey: "quota.minimax-cn-wallet.enabled.v1")
        let blockedMini = MiniMaxWalletStore(defaults: defaults, vault: blockedVault, allowsConnections: true,
                                            transport: { _ in throw QuotaConnectionError.preview })
        let blocked = QuotaConnectionsStore(defaults: defaults, vault: blockedVault, allowsConnections: true,
                                           transport: { _ in throw QuotaConnectionError.preview }, miniMax: blockedMini)
        blocked.refreshDeepSeek(); blockedMini.refresh()
        for _ in 0..<100 {
            if !blocked.isDeepSeekRefreshing && !blockedMini.isRefreshing { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let pausedReadCount = blockedVault.readCount
        for _ in 0..<3 { blocked.refreshDeepSeek(force: true); blockedMini.refresh(force: true) }
        guard blockedVault.readCount == pausedReadCount else {
            print("FAIL: a paused connector must not repeatedly read the saved credential in the background")
            exit(1)
        }
        for id in ["deepseek", "minimax-api"] {
            let text = try renderText(manager(id, store: blocked), to: output.appendingPathComponent("self-service-\(id)-blocked.png"))
            let isPaused = id == "deepseek" ? blocked.deepSeekKeychainBlocked && blocked.deepSeekNeedsAuthorization
                : blockedMini.keychainBlocked && blockedMini.needsAuthorization
            guard isPaused, text.contains("授权读取已保存的"), !text.contains("粘贴 Key") else {
                print("FAIL: \(id) permission recovery must offer saved-key authorization instead of forcing key re-entry")
                exit(1)
            }
        }
        for provider in [QuotaSetupProvider.deepSeek, .miniMax] {
            let browser = QuotaSetupBrowser(provider: provider)
            browser.openOfficialPage()
            guard !browser.webView.configuration.websiteDataStore.isPersistent,
                  browser.webView.configuration.userContentController.userScripts.isEmpty,
                  browser.webView.url == nil, browser.error != nil else {
                print("FAIL: setup preview must not navigate, persist login or inject website scripts")
                exit(1)
            }
            guard browser.responds(to: NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")),
                  browser.responds(to: NSSelectorFromString("webView:decidePolicyForNavigationResponse:decisionHandler:")),
                  browser.responds(to: NSSelectorFromString("webView:runOpenPanelWithParameters:initiatedByFrame:completionHandler:")) else {
                print("FAIL: production WebKit security delegates must actually be registered")
                exit(1)
            }
            let content: AnyView = provider == .deepSeek
                ? AnyView(DeepSeekConnectionView(connections: connections, startsEditingKey: true, showsKeyHelp: false))
                : AnyView(MiniMaxWalletConnectionView(store: connections.miniMax!, startsEditingKey: true, showsKeyHelp: false))
            let guide = QuotaGuidedConnectionView(browser: browser, connectionContent: content, onDone: {})
            let text = try renderText(guide, to: output.appendingPathComponent("guided-\(provider.name).png"),
                                      size: NSSize(width: 1080, height: 660))
            guard text.contains("粘贴 Key"), text.contains("查询余额"), text.contains("登录"), text.contains("关闭连接窗口") else {
                print("FAIL: official page and actionable credential form must remain in one visible connection window")
                exit(1)
            }
            let compact = try renderText(guide, to: output.appendingPathComponent("guided-compact-\(provider.name).png"),
                                         size: NSSize(width: 880, height: 540))
            guard compact.contains("粘贴 Key"), compact.contains("查询余额"), compact.contains("关闭连接窗口") else {
                print("FAIL: setup actions must fit the minimum supported window size")
                exit(1)
            }
            // Inline help can disappear/reappear in a retained notch route. Its
            // real navigation policy must still reject external origins after reopen.
            browser.stop()
            browser.openOfficialPage()
            // Reserved .invalid domain: no user data or real account, even if the gate regresses.
            browser.webView.load(URLRequest(url: URL(string: "https://outside-paul-setup.invalid/")!))
            for _ in 0..<100 {
                if browser.error?.contains("不属于当前平台") == true { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard browser.error?.contains("不属于当前平台") == true else {
                print("FAIL: real WebKit navigation must invoke the provider-origin gate")
                exit(1)
            }
            browser.stop()
        }
        print("PASS: guided in-app setup, connector grouping, explicit paste, bounded forms, authorization recovery and ephemeral preview boundaries")
    }

    @MainActor private static func renderText<V: View>(_ view: V, to url: URL, size: NSSize = NSSize(width: 600, height: 438)) throws -> String {
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.alphaValue = 0
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw Failure.render }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]),
              let cgImage = bitmap.cgImage else { throw Failure.render }
        try png.write(to: url)
        window.orderOut(nil)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        try VNImageRequestHandler(cgImage: cgImage).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }
    enum Failure: Error { case render }
}
