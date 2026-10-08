import SwiftUI

struct MiniMaxWalletConnectionView: View {
    @ObservedObject var store: MiniMaxWalletStore
    @State private var key = ""
    @State private var pasteError: String?
    @State private var showsWebsite = false
    @State private var editingKey: Bool
    @FocusState private var keyIsFocused: Bool
    private let showsKeyHelp: Bool

    init(store: MiniMaxWalletStore, startsEditingKey: Bool = false,
         showsKeyHelp: Bool = true, initialKey: String = "") {
        self.store = store
        self.showsKeyHelp = showsKeyHelp
        _key = State(initialValue: initialKey)
        _editingKey = State(initialValue: startsEditingKey && !store.keychainBlocked)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("中国站 · 人民币 API 钱包").font(.system(size: 16, weight: .semibold))
            if let error = store.error {
                Text(verbatim: error).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if store.keychainBlocked && !editingKey {
                Text("旧版 Key 还在，无需重新填写。点下方恢复并保存到新版；Mac 若询问，请点「允许」。保存验证后，退出、开机和普通更新会自动恢复。取消不会删除旧连接。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("授权读取已保存的 Key") { store.authorizeSavedKey() }
                        .disabled(store.isRefreshing)
                        .accessibilityIdentifier("quota-minimax-authorize")
                    Button("更换 Key") { editingKey = true }
                }.buttonStyle(.bordered).controlSize(.large)
            } else if !store.enabled || store.needsAuthorization || editingKey {
                Text("连接你充值的人民币余额，不是 Audio 配音会员或 Token Plan。只需复制一次普通 API Key。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if store.enabled {
                    Text("新 Key 验证成功后才替换当前账户；失败会保留原来的连接。")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if showsKeyHelp {
                        Button(showsWebsite ? "收起官网，填写 Key" : "在这里获取 Key") { showsWebsite.toggle() }
                            .accessibilityIdentifier("quota-minimax-get-key")
                    }
                    Button("粘贴 Key") { pasteKey() }
                        .accessibilityIdentifier("quota-minimax-paste")
                }.buttonStyle(.bordered).controlSize(.large)
                if showsWebsite { QuotaInlineKeyWebsite(provider: .miniMax) }
                SecureField("粘贴中国站 MiniMax API Key", text: $key)
                    .textFieldStyle(.roundedBorder).frame(minHeight: 36)
                    .accessibilityLabel("MiniMax API Key").accessibilityIdentifier("quota-minimax-key")
                    .focused($keyIsFocused).onAppear { keyIsFocused = true }
                    .onSubmit { connect() }
                if let pasteError { Text(pasteError).foregroundStyle(.orange) }
                Button(store.isRefreshing ? "正在验证…" : "连接并查询余额") { connect() }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(key.isEmpty || store.isRefreshing || !store.allowsConnections)
                        .accessibilityIdentifier("quota-minimax-connect")
                DisclosureGroup("密钥如何保存？") {
                    Text("只发给 api.minimaxi.com 查询余额，验证后存入本机钥匙串。不调用模型；密钥本身仍可能有消费权限。")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack {
                    Button(store.isRefreshing ? "正在查询…" : "刷新余额") { store.refresh(force: true) }
                        .disabled(store.isRefreshing)
                    Button("更换 Key") { editingKey = true }
                }.buttonStyle(.bordered).controlSize(.large)
            }
            if store.snapshot != nil && store.error == nil {
                let account = store.account(now: .now)
                Label("\(account.status.rawValue) · \(account.value.text)", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            }
            if store.enabled {
                Button("断开并移除已保存的 Key", role: .destructive) {
                    store.disconnect(); key = ""; editingKey = false
                }.buttonStyle(.bordered).controlSize(.large)
            }
        }
        .font(.system(size: 12))
        .onDisappear { key = ""; keyIsFocused = false }
    }

    private func connect() {
        do {
            key = try QuotaSetupProvider.miniMax.preparedKey(key)
            pasteError = nil
            if store.connect(key) { key = ""; editingKey = false }
        } catch { pasteError = "请填写官网复制的完整普通 API Key（sk-api-），不是登录密码或 Token Plan 密钥。" }
    }
    private func pasteKey() {
        do {
            key = try QuotaSetupProvider.miniMax.preparedKey(NSPasteboard.general.string(forType: .string) ?? "")
            pasteError = nil; keyIsFocused = true
        } catch { pasteError = "剪贴板里没有普通 API Key。请在官网复制 sk-api- 开头的完整密钥。" }
    }
}
