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
                    if !store.needsAuthorization {
                        Label("登录已保存", systemImage: "checkmark.shield")
                            .font(.system(size: 12, weight: .medium))
                    }
                    ForEach([DesktopQuotaProvider.cursor, .grok], id: \.rawValue) { provider in
                        let account = store.account(provider, now: .now)
                        LabeledContent(provider.name, value: account.status == .current ? account.value.text : "尚未获取当前额度")
                        if account.status != .current, let reason = account.unavailableReason {
                            Text(reason).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
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
                            .disabled(store.isDisconnectConfirmationPresented)
                            .accessibilityIdentifier("quota-cursor-disconnect-request")
                    }
                    if store.isDisconnectConfirmationPresented {
                        Text("确认断开 Cursor 和 Grok Bot？这会移除 Paul 保存的登录，下次需要重新连接。")
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("保留连接") { store.cancelDisconnect() }
                                .buttonStyle(.bordered).controlSize(.large)
                                .accessibilityIdentifier("quota-cursor-disconnect-cancel")
                            Button("确认断开", role: .destructive) { store.disconnect(confirming: true) }
                                .buttonStyle(.bordered).controlSize(.large)
                                .accessibilityIdentifier("quota-cursor-disconnect-confirm")
                        }
                    }
                }
                Text("登录凭证只保存在本机专用钥匙串；不读取其他应用的密码、Cookie 或聊天。此凭证本身可能具备更广权限，但 Paul 只请求额度，不调用模型、不消费重置卡、不更改账单。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            CursorModelFollowControls(monitor: store.modelMonitor).disabled(!store.enabled)
        }
        .font(.system(size: 12))
        .onChange(of: store.loginURL) { if $0 == nil { launcher.cancel(); copiedLink = false } }
        .onDisappear { store.cancelDisconnect() }
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

private struct CursorModelFollowControls: View {
    @ObservedObject var monitor: CursorModelMonitor
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("刘海跟随 Cursor 所选模型", isOn: Binding(get: { monitor.enabled }, set: { monitor.setEnabled($0) }))
                .toggleStyle(.switch).accessibilityIdentifier("cursor-model-follow-toggle")
            Text("支持前台 Cursor 桌面，以及 Chrome 当前标签页中的 cursor.com/agents。只检查官网地址和输入框旁的模型选择器，不读取聊天、输入内容、浏览历史或 Cookie，不新增网页或额度请求。显示的是 Paul 已连接账号的额度；Auto 或无法识别时保留双额度，内 = Cursor Models，外 = Other Models。所选模型不等于已提交任务的实际运行模型。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if monitor.enabled {
                Text(monitor.selection.explanation).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if monitor.selection == .permissionRequired {
                    Button("打开辅助功能设置") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }.buttonStyle(.bordered)
                    Text("只需为 Paul Notch 开启一次；不会要求重新登录 Cursor。开启后切回 Cursor 即可。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }.padding(.top, 12)
    }
}
