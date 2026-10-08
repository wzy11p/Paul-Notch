import SwiftUI
import WebKit

struct WebsiteQuotaConnectionView: View {
    @ObservedObject var store: WebsiteQuotaStore
    @State private var region: WebsiteQuotaProvider = .miniMaxCN
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !store.isPresentingLogin {
                Text("连接\(store.provider.name)会员额度").font(.system(size: 16, weight: .semibold))
            }
            Text(store.provider == .muse && store.connectedBrowser != nil
                 ? "登录已保留。下方是同一连接的官方额度页，可直接刷新，无需更换账号。"
                 : "官方登录后读取额度，之后每 30 秒自动更新。未完成的登录保留 10 分钟。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = store.loginError ?? store.error {
                QuotaConnectionIssue(message: error)
            }
            if store.isPresentingLogin {
                HStack {
                    Button(store.isRefreshing ? "正在读取…" : (store.provider == .muse ? "登录完成，读取额度" : "登录后读取并开始同步")) { store.finishLogin() }
                        .buttonStyle(.borderedProminent).disabled(store.isRefreshing)
                        .accessibilityIdentifier("quota-website-confirm-\(store.provider.accountID)")
                    Button("取消本次登录") { store.cancelLogin() }.buttonStyle(.bordered)
                        .help("取消这次登录；已保存的旧连接不会移除")
                }
                if let browser = store.candidateBrowser {
                    WebsiteQuotaLoginContent(browser: browser)
                        .frame(minHeight: 140, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            } else if store.provider == .muse, let browser = store.connectedBrowser {
                HStack {
                    Button(store.isRefreshing ? "正在读取…" : "刷新额度") { store.refreshDue(force: true) }
                        .buttonStyle(.borderedProminent).disabled(store.isRefreshing)
                        .accessibilityIdentifier("quota-website-refresh-muse")
                    Menu("管理连接") {
                        Button("更换账号") { store.beginLogin() }
                        Button("断开连接", role: .destructive) { store.disconnect() }
                    }.disabled(store.isRefreshing)
                }
                WebsiteQuotaLoginContent(browser: browser)
                    .frame(minHeight: 140, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                if store.provider.isAudio && !store.enabled {
                    Picker("配音账户所在站点", selection: $region) {
                        Text("中国站").tag(WebsiteQuotaProvider.miniMaxCN)
                        Text("国际站").tag(WebsiteQuotaProvider.miniMaxGlobal)
                    }.pickerStyle(.segmented)
                }
                Button(store.enabled ? "重新登录 / 更换账号" : (store.provider == .muse ? "登录 Muse" : "在这里登录并连接")) {
                    store.beginLogin(provider: store.provider.isAudio && !store.enabled ? region : store.provider)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(!store.allowsConnections)
                .accessibilityIdentifier("quota-website-login-\(store.provider.accountID)")
                if store.enabled {
                    LabeledContent("当前额度", value: store.account(now: .now).displayValue)
                    HStack {
                        Button("刷新额度") { store.refreshDue(force: true) }.buttonStyle(.bordered).controlSize(.large)
                            .disabled(store.isRefreshing || store.needsLogin)
                        Button("断开连接", role: .destructive) { store.disconnect() }.buttonStyle(.bordered).controlSize(.large)
                    }
                }
            }
            if !store.isPresentingLogin && !(store.provider == .muse && store.connectedBrowser != nil) { Spacer(minLength: 0) }
            DisclosureGroup("登录保存与隐私") {
                Text("\(store.remembersLogin ? "首次连接后自动保存本机登录，重启后自动恢复；断开连接会移除保存的登录。" : "独立登录保存需要 macOS 14 或更新版本。")\(store.provider == .muse ? "只读取 Muse 个人使用情况，不读取聊天或复制原应用的登录。" : "只读取本平台个人额度 / 声贝，不复制其他应用的登录、不保存密码、不调用配音模型。")官方登录真正失效时才需重新登录。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.font(.system(size: 11))
        }
        .font(.system(size: 12))
    }
}

private struct WebsiteQuotaLoginContent: View {
    @ObservedObject var browser: WebsiteQuotaBrowser
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = browser.error {
                QuotaConnectionIssue(message: error)
            }
            if browser.loginPopup != nil {
                HStack {
                    Text("官方登录页面").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("返回额度页") { browser.closeLoginPopup() }
                        .buttonStyle(.bordered).controlSize(.large)
                        .accessibilityIdentifier("quota-website-return-\(browser.provider.accountID)")
                }
            }
            WebsiteQuotaWebContainer(webView: browser.displayedWebView)
                .id(ObjectIdentifier(browser.displayedWebView))
                .frame(minHeight: 100, maxHeight: .infinity)
        }
    }
}

/// Errors must not consume the official page; the full reason remains available.
private struct QuotaConnectionIssue: View {
    let message: String
    @State private var showsDetails = false
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle")
            Text(message).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            Button("详情") { showsDetails.toggle() }.buttonStyle(.plain)
                .popover(isPresented: $showsDetails) {
                    Text(message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                        .padding(16).frame(width: 300)
                }
        }.font(.system(size: 11)).foregroundStyle(.orange)
        .accessibilityElement(children: .combine).accessibilityLabel(message)
    }
}
private struct WebsiteQuotaWebContainer: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
