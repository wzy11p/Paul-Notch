import SwiftUI

/// Selection, connection forms, errors and Key acquisition stay in the notch.
struct QuotaServiceConnectionsView: View {
    @ObservedObject var connections: QuotaConnectionsStore
    let accounts: [QuotaOverviewAccount]
    @Binding var selectedProvider: String?
    let codexReadsEnabled: Bool
    let isCodexRefreshing: Bool
    let onCheckCodex: () -> Void
    let onClose: () -> Void
    var onCollapse: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selected: QuotaOverviewAccount? { accounts.first { $0.id == selectedProvider } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    if selectedProvider != nil { selectedProvider = nil } else { onClose() }
                } label: {
                    Label(selectedProvider == nil ? "返回首页" : "选择服务", systemImage: "chevron.left")
                        .font(.system(size: 12)).padding(.horizontal, 10).frame(height: 36)
                }
                .buttonStyle(QuotaOverviewButtonStyle())
                // Keep Escape available after the focused key field is removed.
                .keyboardShortcut(.cancelAction)
                Text(selected?.name ?? "添加服务").font(.system(size: 20, weight: .semibold))
                Spacer(minLength: 0)
                Button(action: onCollapse) {
                    Label("收起", systemImage: "chevron.up")
                        .font(.system(size: 12, weight: .medium)).padding(.horizontal, 10).frame(height: 36)
                }
                .buttonStyle(QuotaOverviewButtonStyle())
                .help("收起面板，保留登录和后台同步")
                .accessibilityIdentifier("quota-connection-collapse")
            }
            if let selected {
                if let website = connections.websiteMemberships[selected.id] {
                    WebsiteQuotaConnectionView(store: website)
                        .padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(QuotaOverviewPalette.surface, in: RoundedRectangle(cornerRadius: 16))
                        .id(selected.id)
                } else {
                    ScrollView {
                        setup(selected).frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }
                    .background(QuotaOverviewPalette.surface, in: RoundedRectangle(cornerRadius: 16))
                    .id(selected.id)
                    .transition(QuotaInteractionMotion.entrance)
                }
            } else {
                Text("选一个服务，按提示连接。无需填写接口地址或其他技术参数。")
                    .font(.system(size: 12)).foregroundStyle(QuotaOverviewPalette.secondary)
                ScrollView {
                    serviceGrid(accounts)
                }
            }
        }
        .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(QuotaOverviewPalette.primary).background(Color.black)
        .preferredColorScheme(.dark)
        .animation(QuotaInteractionMotion.content(reduceMotion: reduceMotion), value: selectedProvider)
    }

    private func serviceGrid(_ items: [QuotaOverviewAccount]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(items) { account in
                Button { selectedProvider = account.id } label: {
                    HStack(spacing: 12) {
                        if let image = ProviderBrandAssets.image(for: account.id) {
                            Image(nsImage: image).renderingMode(.original).resizable().scaledToFit()
                                .frame(width: 26, height: 26).accessibilityHidden(true)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text(account.name).font(.system(size: 13, weight: .semibold))
                            Text(methodLabel(account.id)).font(.system(size: 11))
                                .foregroundStyle(QuotaOverviewPalette.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: 10))
                    }
                    .padding(12).frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
                    .contentShape(RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(QuotaOverviewButtonStyle())
                .background(QuotaOverviewPalette.surface, in: RoundedRectangle(cornerRadius: 16))
                .accessibilityIdentifier("quota-connect-\(account.id)")
            }
        }
    }

    @ViewBuilder private func setup(_ account: QuotaOverviewAccount) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if ["cursor", "grok"].contains(account.id), let cursor = connections.cursorAccount {
                CursorQuotaConnectionView(store: cursor)
            } else if let membership = connections.websiteMemberships[account.id] {
                WebsiteQuotaConnectionView(store: membership)
            } else if let provider = DesktopQuotaProvider(rawValue: account.id), let desktop = connections.desktop {
                DesktopQuotaConnectionView(store: desktop, provider: provider)
            } else if account.id == "deepseek" {
                Text("连接充值余额").font(.system(size: 16, weight: .semibold))
                if connections.deepSeekEnabled {
                    Text("已配置一个 DeepSeek 账户。输入新 Key 会替换当前连接，不会新增第二个账户。")
                        .font(.system(size: 12)).foregroundStyle(QuotaOverviewPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                DeepSeekConnectionView(connections: connections, startsEditingKey: true)
                if connections.isDeepSeekRefreshing {
                    Text("正在验证并查询余额…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            } else if account.id == "minimax-api", let miniMax = connections.miniMax {
                MiniMaxWalletConnectionView(store: miniMax, startsEditingKey: true)
            } else if account.id == "codex" {
                Text("连接本机 Codex 账户").font(.system(size: 16, weight: .semibold))
                Text("先在 Codex 桌面端登录，再检查连接。不需要 API Key，共用刘海已有的额度读取。")
                    .font(.system(size: 12)).foregroundStyle(QuotaOverviewPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent("状态", value: account.status.rawValue)
                LabeledContent("剩余额度", value: account.value.text)
                Button(isCodexRefreshing ? "正在检查…" : "连接 / 重新检查", action: onCheckCodex)
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!codexReadsEnabled || isCodexRefreshing)
                    .accessibilityIdentifier("quota-connect-codex-check")
                if !codexReadsEnabled {
                    Text("此隔离预览未启用账户读取，请在正式版连接。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            } else if account.id == "muse" {
                Text("Meta Muse · 桌面会员").font(.system(size: 16, weight: .semibold))
                Text("尚不能自动同步").font(.system(size: 12, weight: .medium))
                Text("Muse 已加入首页，但尚未读到你的个人额度和重置时间。会员额度、额外购买额度与 Meta Model API 是不同产品，不会互相替代。")
                    .font(.system(size: 12)).foregroundStyle(QuotaOverviewPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("暂时不需要填写密钥或登录密码。接入方式核验完成前，不会提供无效的登录按钮或显示连接成功。")
                    .font(.system(size: 12)).foregroundStyle(QuotaOverviewPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                QuotaProviderHelpView(provider: "muse")
            } else {
                Text("尚不支持自动同步").font(.system(size: 16, weight: .semibold))
                Text("这项产品的额度接口尚未适配。现在不会收取或保存它的 Key，也不会把打开官网显示为连接成功。")
                    .font(.system(size: 12)).foregroundStyle(QuotaOverviewPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                QuotaProviderHelpView(provider: account.id)
            }
        }.id(account.id)
    }

    private func methodLabel(_ id: String) -> String {
        switch id {
        case "cursor", "grok": connections.cursorAccount == nil ? "不用密钥 · 读取原应用额度页" : "一次官方登录 · 后台自动同步"
        case "doubao": connections.websiteMemberships[id] == nil ? "不用密钥 · 读取原应用额度页" : "官方登录 · 两套额度分别同步"
        case "minimax-audio": connections.websiteMemberships[id] == nil ? "暂不支持自动同步" : "官方登录 · 配音声贝单独同步"
        case "deepseek": connections.deepSeekEnabled ? "已配置 · 管理连接" : "获取或粘贴 API Key"
        case "minimax-api": connections.miniMax == nil ? "暂未支持 · 查看说明" : "获取或粘贴 API Key"
        case "codex": "可直接连接 · 现有登录"
        case "muse": connections.websiteMemberships[id] == nil ? "Meta 桌面会员 · 同步适配中" : "首次官方登录 · 自动保存连接"
        default: "暂不支持自动同步"
        }
    }
}
