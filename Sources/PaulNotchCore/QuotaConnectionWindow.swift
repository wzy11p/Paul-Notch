import AppKit
import SwiftUI

/// A single, focused setup window within Paul Notch, not another app/workspace.
@MainActor final class QuotaConnectionWindow: NSObject, NSWindowDelegate {
    private static var current: QuotaConnectionWindow?
    let window: NSWindow
    private let browser: QuotaSetupBrowser

    static func showDeepSeek(_ connections: QuotaConnectionsStore, draft: String) {
        show(provider: .deepSeek, content: AnyView(DeepSeekConnectionView(
            connections: connections, startsEditingKey: true, showsKeyHelp: false, initialKey: draft)))
    }
    static func showMiniMax(_ store: MiniMaxWalletStore, draft: String) {
        show(provider: .miniMax, content: AnyView(MiniMaxWalletConnectionView(
            store: store, startsEditingKey: true, showsKeyHelp: false, initialKey: draft)))
    }
    private static func show(provider: QuotaSetupProvider, content: AnyView) {
        if let current, current.browser.provider == provider {
            current.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        current?.window.close()
        let controller = QuotaConnectionWindow(provider: provider, content: content)
        current = controller
        controller.window.center()
        controller.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.browser.openOfficialPage()
    }
    private init(provider: QuotaSetupProvider, content: AnyView) {
        browser = QuotaSetupBrowser(provider: provider)
        let available = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1200, height: 800)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: min(1080, available.width - 40),
                                            height: min(660, available.height - 50)),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Paul Notch · 连接 \(provider.name)"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: min(880, available.width - 40), height: min(540, available.height - 50))
        window.delegate = self
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: QuotaGuidedConnectionView(browser: browser,
            connectionContent: content, onDone: { [weak self] in self?.window.close() }))
        host.sizingOptions = []
        window.contentView = host
    }
    func windowWillClose(_ notification: Notification) {
        browser.stop()
        window.contentView = nil
        if Self.current === self { Self.current = nil }
    }
}

struct QuotaGuidedConnectionView: View {
    @ObservedObject var browser: QuotaSetupBrowser
    let connectionContent: AnyView
    let onDone: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Label(browser.host, systemImage: "lock.fill").font(.system(size: 12))
                    Spacer()
                    Button("重新加载") { browser.openOfficialPage() }
                        .accessibilityIdentifier("quota-website-reload")
                }.padding(12).background(Color(nsColor: .windowBackgroundColor))
                if browser.isLoading { ProgressView().controlSize(.small).padding(8) }
                if let error = browser.error {
                    Text(error).font(.system(size: 13)).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
                QuotaOfficialWebView(browser: browser)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                Text("连接 \(browser.provider.name)").font(.system(size: 22, weight: .semibold))
                Text(browser.provider.instruction).font(.system(size: 14))
                    .fixedSize(horizontal: false, vertical: true)
                connectionContent.frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                DisclosureGroup("登录遇到问题？") {
                    Text("左侧是平台官网。软件不读取网页里的密码或 Cookie；关闭此窗口后不保留网页登录状态。官网若限制内嵌登录，可用系统浏览器完成，再回来粘贴密钥。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Link("改用系统浏览器", destination: browser.provider.website).font(.system(size: 12))
                }.font(.system(size: 12))
                Button("关闭连接窗口", action: onDone).buttonStyle(.bordered).controlSize(.large)
                    .keyboardShortcut(.cancelAction)
                }.padding(24)
            }.frame(width: 360)
        }.background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.dark)
    }
}
