import SwiftUI

struct DeepSeekConnectionView: View {
    @ObservedObject var connections: QuotaConnectionsStore
    @State private var key = ""
    @State private var pasteError: String?
    @State private var showsWebsite = false
    @State private var editingKey: Bool
    @FocusState private var keyIsFocused: Bool
    private let showsKeyHelp: Bool

    init(connections: QuotaConnectionsStore, startsEditingKey: Bool = false,
         showsKeyHelp: Bool = true, initialKey: String = "") {
        self.connections = connections
        self.showsKeyHelp = showsKeyHelp
        _key = State(initialValue: initialKey)
        _editingKey = State(initialValue: startsEditingKey && !connections.deepSeekKeychainBlocked)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = connections.deepSeekError {
                Text(verbatim: error).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if connections.deepSeekKeychainBlocked && !editingKey {
                Text("旧版 Key 还在，无需重新填写。点下方恢复并保存到新版；Mac 若询问，请点「允许」。保存验证后，退出、开机和普通更新会自动恢复。取消不会删除旧连接。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("授权读取已保存的 Key") { connections.authorizeDeepSeek() }
                        .disabled(connections.isDeepSeekRefreshing)
                        .accessibilityIdentifier("quota-deepseek-authorize")
                    Button("更换 Key") { editingKey = true }
                }.buttonStyle(.bordered).controlSize(.large)
            } else if !connections.deepSeekEnabled || connections.deepSeekNeedsAuthorization || editingKey {
                Text("用平台密钥（API Key）连接充值余额，不是登录密码。不需要填写接口地址。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    if showsKeyHelp {
                        Button(showsWebsite ? "收起官网，填写 Key" : "在这里获取 Key") { showsWebsite.toggle() }
                            .accessibilityIdentifier("quota-deepseek-get-key")
                    }
                    Button("粘贴 Key") { pasteKey() }
                        .accessibilityIdentifier("quota-deepseek-paste")
                }.buttonStyle(.bordered).controlSize(.large)
                if showsWebsite { QuotaInlineKeyWebsite(provider: .deepSeek) }
                SecureField("在此粘贴 DeepSeek API Key", text: $key)
                    .textFieldStyle(.roundedBorder).frame(minHeight: 36)
                    .accessibilityLabel("DeepSeek API Key")
                    .accessibilityIdentifier("quota-deepseek-key")
                    .focused($keyIsFocused)
                    .onAppear { keyIsFocused = true }
                    .onSubmit { connect() }
                if let pasteError { Text(pasteError).foregroundStyle(.orange) }
                Button(connections.isDeepSeekRefreshing ? "正在连接…" : "保存并查询余额") { connect() }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(key.isEmpty || !connections.allowsConnections || connections.isDeepSeekRefreshing)
                        .accessibilityIdentifier("quota-deepseek-connect")
                DisclosureGroup("密钥如何保存？") {
                    Text("只存本机钥匙串，只发送给 api.deepseek.com 查询余额，不调用模型。密钥本身可能有消费权限，请不要发到聊天里。")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack {
                    Button(connections.isDeepSeekRefreshing ? "正在查询…" : "刷新余额") { connections.refreshDeepSeek(force: true) }
                        .disabled(connections.isDeepSeekRefreshing)
                    Button("更换 Key") { editingKey = true }
                }.buttonStyle(.bordered).controlSize(.large)
            }
            if connections.deepSeekSnapshot != nil && connections.deepSeekError == nil && !connections.isDeepSeekRefreshing {
                let account = connections.deepSeekAccount(now: .now)
                Label("\(account.status.rawValue) · \(account.value.text)", systemImage: "checkmark.circle")
                    .foregroundStyle(account.status == .current ? .green : .secondary)
            }
            if connections.deepSeekEnabled || connections.deepSeekError != nil {
                Button("断开并移除已保存的 Key", role: .destructive) {
                    connections.disconnectDeepSeek(); key = ""; editingKey = false
                }.buttonStyle(.bordered).controlSize(.large)
            }
            if !connections.allowsConnections {
                Text("隔离预览不保存真实凭证，请在正式版使用。").foregroundStyle(.secondary)
            }
        }.font(.system(size: 12))
            .onDisappear { key = ""; keyIsFocused = false }
    }
    private func connect() {
        do {
            key = try QuotaSetupProvider.deepSeek.preparedKey(key)
            pasteError = nil
            if connections.connectDeepSeek(key) { key = ""; editingKey = false }
        } catch { pasteError = "请填写官网复制的完整 API Key，不是账号密码或网址。" }
    }
    private func pasteKey() {
        do {
            key = try QuotaSetupProvider.deepSeek.preparedKey(NSPasteboard.general.string(forType: .string) ?? "")
            pasteError = nil; keyIsFocused = true
        } catch { pasteError = "剪贴板里没有有效的 DeepSeek Key。请先在官网复制完整密钥。" }
    }
}

struct QuotaProviderHelpView: View {
    let provider: String
    var body: some View {
        if let destination {
            VStack(alignment: .leading, spacing: 10) {
                Text(instructions).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link(provider == "muse" ? "查看官方说明" : "打开官方入口", destination: destination)
                    .buttonStyle(.bordered).controlSize(.large)
            }
        }
    }
    private var destination: URL? {
        let address: String?
        switch provider {
        case "muse": address = "https://ai.meta.com/muse/"
        case "kimi": address = "https://www.kimi.com"
        case "grok": address = nil
        case "doubao": address = "https://www.doubao.com"
        case "minimax-api": address = "https://platform.minimaxi.com"
        case "minimax-audio": address = "https://www.minimax.io/audio"
        default: address = nil
        }
        return address.flatMap(URL.init(string:))
    }
    private var instructions: String {
        switch provider {
        case "muse": "这是 Meta Muse 桌面会员，不是 Muse Code 或开放平台 API。官方说明链接仅供核对产品，不会登录或连接你的账户。"
        case "kimi": "官方入口：我的 → 设置 → 订阅。桌面会员不等于开放平台 API 钱包；尚未验证可自动同步该账户的授权接口。"
        case "grok": "Grok Bot 通过 Cursor 计费，不是 SuperGrok；使用原应用的会员额度读取。"
        case "doubao": "请在豆包工作客户端的会员或用量页面核对。通用豆包与工作版的权益不能自行合并；自动同步方式尚未验证。"
        case "minimax-api": "你的人民币按量钱包与 Token Plan 是不同产品。尚未确认适用于此钱包的官方余额接口，不会拿 Token Plan 数据代替。"
        case "minimax-audio": "请在 Audio 的订阅或积分页面查看。配音会员积分与开放平台充值余额分开，自动同步方式尚未验证。"
        default: ""
        }
    }
}

struct QuotaResetFeedView: View {
    @ObservedObject var connections: QuotaConnectionsStore
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("重置公告").font(.headline)
                Spacer()
                if connections.feedEnabled {
                    Button("刷新") { connections.refreshFeed(force: true) }.disabled(connections.isFeedRefreshing)
                }
            }
            Text("来源 AIHOT · 公共消息，不是你的个人额度。预告不等于已重置；不显示模型推算日期，不自动使用重置卡。")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !connections.feedEnabled {
                Text("开启后每 5 分钟匿名读取 aihot.news，不发送账户或 Key。新消息会在此处标记；本版不发送系统通知。")
                    .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                Button("开启重置公告") { connections.setFeedEnabled(true) }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(!connections.allowsConnections)
            } else {
                if let error = connections.feedError {
                    Text(verbatim: error).font(.system(size: 12)).foregroundStyle(.orange)
                }
                if let snapshot = connections.feedSnapshot {
                    Text("来源核验：\(snapshot.checkedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if snapshot.monitorStatus != "healthy" || Date().timeIntervalSince(snapshot.checkedAt) > 1800 {
                        Text("上游核验可能延迟，以下消息请结合原帖确认。").font(.system(size: 12)).foregroundStyle(.orange)
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            if snapshot.events.isEmpty { Text("暂时没有重置消息") }
                            ForEach(snapshot.events, id: \.id) { event in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("\(event.typeLabel) · \(event.statusLabel)").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                                    Text(verbatim: event.title).font(.system(size: 13, weight: .semibold))
                                    Text(verbatim: event.text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                                    HStack {
                                        Text(event.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                        Spacer()
                                        if let source = event.sourceURL { Link("查看原帖", destination: source) }
                                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                Divider()
                            }
                        }
                    // A popover's intrinsic-size proposal otherwise collapses the lazy scroll viewport.
                    }.frame(height: 260)
                } else if connections.isFeedRefreshing { Text("正在读取公开消息…").font(.system(size: 12)) }
                Button("停止读取公告") { connections.setFeedEnabled(false) }.buttonStyle(.bordered)
            }
        }
        .padding(18).frame(width: 360).background(Color(white: 0.10))
        .onAppear { if connections.feedSnapshot != nil { connections.markFeedRead() } }
    }
}

extension QuotaConnectionsStore {
    func deepSeekAccount(now: Date) -> QuotaOverviewAccount {
        guard let snapshot = deepSeekSnapshot, let first = snapshot.entries.first(where: { $0.currency == "CNY" }) ?? snapshot.entries.first else {
            return QuotaOverviewAccount(id: "deepseek", name: "DeepSeek API", account: "独立充值余额", group: .usage,
                value: .unknown, timing: deepSeekKeychainBlocked ? "需要授权" : (deepSeekEnabled ? "等待有效余额" : "填写 Key 后查询"),
                status: deepSeekEnabled ? .unavailable : .notConnected,
                explanation: "通过 DeepSeek 官方只读余额接口查询，不发送聊天内容，不调用生成接口。",
                unavailableReason: !allowsConnections ? "隔离验证不读取账户" :
                    (deepSeekKeychainBlocked ? "钥匙串授权尚未完成" :
                        (deepSeekError ?? (deepSeekEnabled ? "余额尚未返回" : "尚未连接 API Key"))))
        }
        let age = now.timeIntervalSince(snapshot.observedAt)
        let fresh = deepSeekError == nil && age >= -60 && age <= 90
        var details = [QuotaOverviewDetail(label: "最近读取", value: snapshot.observedAt.formatted(date: .abbreviated, time: .shortened)),
                       .init(label: "数据来源", value: "DeepSeek 官方 /user/balance"),
                       .init(label: "账户可调用", value: snapshot.isAvailable ? "是" : "否")]
        for entry in snapshot.entries {
            details += [.init(label: "\(entry.currency) 总余额", value: QuotaOverviewValue.money(entry.total, currency: entry.currency).text),
                        .init(label: "\(entry.currency) 赠送余额", value: QuotaOverviewValue.money(entry.granted, currency: entry.currency).text),
                        .init(label: "\(entry.currency) 充值余额", value: QuotaOverviewValue.money(entry.toppedUp, currency: entry.currency).text)]
        }
        return QuotaOverviewAccount(id: "deepseek", name: "DeepSeek API", account: "API 钱包 · \(first.currency)", group: .usage,
            value: .money(first.total, currency: first.currency), timing: "按量扣费", status: fresh ? .current : .stale,
            details: details, explanation: "卡片显示 \(first.currency) 余额；不同币种不相加、不换算为百分比。\(fresh ? "每 30 秒自动查询，厂商入账可能延迟。" : "当前显示上次成功读取的旧数值。")按量钱包不周期重置，接口未提供赠送余额的到期时间。",
            unavailableReason: fresh ? nil : (deepSeekKeychainBlocked ? "钥匙串授权尚未完成" :
                (deepSeekError ?? "余额已过期，请刷新确认")))
    }
    var feedLabel: String {
        if !feedEnabled { return "重置公告 · 未开启" }
        if feedError != nil { return "重置公告 · 更新失败" }
        if hasUnreadFeed { return "重置公告 · 有新消息" }
        return feedSnapshot == nil ? "重置公告 · 正在读取" : "重置公告"
    }
}
