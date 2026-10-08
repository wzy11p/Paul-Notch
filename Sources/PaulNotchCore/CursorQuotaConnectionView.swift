import AppKit
import SwiftUI

struct CursorQuotaConnectionView: View {
    @ObservedObject var store: CursorQuotaAccountStore
    @StateObject private var launcher: CursorQuotaBrowserLauncher
    @State private var copiedLink = false

    init(store: CursorQuotaAccountStore, launcher: CursorQuotaBrowserLauncher? = nil) {
        self.store = store
        _launcher = StateObject(wrappedValue: launcher ?? CursorQuotaBrowserLauncher())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("连接 Cursor 与 Grok Bot").font(.system(size: 16, weight: .semibold))
            Text("共用一次官方登录，分别查询 Cursor 月额度和 Grok Bot 周额度。连接后每 30 秒自动更新，不用保持原应用额度页打开。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = store.loginError {
                Text(error).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if store.keychainBlocked {
                Text("旧版登录还在，无需重新输入账号。点下方恢复并保存到新版；Mac 若询问，请点「允许」。保存验证后，退出、开机和普通更新会自动恢复。取消不会删除旧连接。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("授权读取已保存的登录") { store.authorizeSavedSession() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
            if store.isLoggingIn, let url = store.loginURL {
                Label(loginMessage, systemImage: "lock.shield")
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button { copiedLink = false; launcher.open(url) } label: {
                        Text(launcher.phase == .opening ? "正在打开 Chrome…" : "重新打开 Chrome")
                            .frame(minHeight: 36).padding(.horizontal, 4).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(launcher.phase == .opening || !store.allowsConnections)
                    .accessibilityIdentifier("quota-cursor-chrome-retry")
                    Button { copiedLink = launcher.copyLink(url) } label: {
                        Text("复制登录链接").frame(minHeight: 36).padding(.horizontal, 4).contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered).controlSize(.large).disabled(!store.allowsConnections)
                    Button { launcher.cancel(); store.cancelLogin() } label: {
                        Text("取消连接").frame(minHeight: 36).padding(.horizontal, 4).contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered).controlSize(.large)
                }
                if case .failed(let message) = launcher.phase {
                    Text(message).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if copiedLink { Text("已复制；粘贴到浏览器地址栏即可打开本次登录。") }
                Text("在 Chrome 完成登录和官方授权后，Paul 会自动查询额度。切换到浏览器或收起刘海不会取消；本次连接等待最多 10 分钟。无需复制 Cookie 或令牌。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                if store.enabled {
                    ForEach([DesktopQuotaProvider.cursor, .grok], id: \.rawValue) { provider in
                        let account = store.account(provider, now: .now)
                        LabeledContent(provider.name, value: account.status == .current ? account.value.text : "尚未获取当前额度")
                    }
                }
                Button {
                    store.beginLogin()
                    if let url = store.loginURL { copiedLink = false; launcher.open(url) }
                } label: {
                    Text(store.enabled ? "在 Chrome 更换登录账号" : "在 Chrome 登录并连接")
                        .frame(minHeight: 36).padding(.horizontal, 8).contentShape(Rectangle())
                }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(!store.allowsConnections)
                    .accessibilityIdentifier("quota-cursor-account-login")
                if store.enabled {
                    HStack {
                        Button("刷新额度") { store.refreshDue(force: true) }
                            .buttonStyle(.bordered).controlSize(.large).disabled(store.isRefreshing || store.needsAuthorization)
                        Button("断开这两个服务", role: .destructive) { store.disconnect() }
                            .buttonStyle(.bordered).controlSize(.large)
                    }
                }
                Text("登录凭证只保存在本机专用钥匙串；不读取其他应用的密码、Cookie 或聊天。此凭证本身可能具备更广权限，但 Paul 只请求额度，不调用模型、不消费重置卡、不更改账单。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 12))
        .onChange(of: store.loginURL) { if $0 == nil { launcher.cancel(); copiedLink = false } }
        // Hiding the notch never cancels the owned login poll or reopens Chrome.
    }
    private var loginMessage: String {
        switch launcher.phase {
        case .idle: "等待登录，可重新打开 Chrome"
        case .opening: "正在打开 Chrome 官方登录页…"
        case .opened: "Chrome 已打开，等待你完成登录和授权"
        case .failed: "浏览器尚未打开，本次连接仍在等待"
        }
    }
}
