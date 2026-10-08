import Foundation

/// Canonical accounts for Home and the shelf. Display adaptation only: no
/// network, credentials, authentication side effects or fixture values.
enum QuotaHomePresentation {
    @MainActor
    static func accounts(snapshot: CodexQuotaSnapshot?, error: String?, readsEnabled: Bool,
                         now: Date, connections: QuotaConnectionsStore? = nil) -> [QuotaOverviewAccount] {
        let accounts = [codex(snapshot: readsEnabled ? snapshot : nil, error: error, readsEnabled: readsEnabled, now: now)] + [
            pending("cursor", "Cursor", "桌面会员", .membership),
            pending("grok", "Grok Bot", "桌面会员 · 通过 Cursor 计费", .membership),
            pending("doubao", "豆包工作", "桌面会员", .membership),
            pending("muse", "Muse", "Meta · 桌面会员", .membership),
            pending("deepseek", "DeepSeek API", "独立充值余额", .usage),
            pending("minimax-api", "MiniMax API", "独立充值余额", .usage),
            pending("minimax-audio", "MiniMax Audio", "配音会员 · 积分", .usage, kind: .audio)
        ]
        guard let connections else { return accounts }
        return accounts.map { account in
            if ["cursor", "grok"].contains(account.id), let provider = DesktopQuotaProvider(rawValue: account.id),
               let cursor = connections.cursorAccount { return cursor.account(provider, now: now) }
            if let membership = connections.websiteMemberships[account.id] { return membership.account(now: now) }
            if let provider = DesktopQuotaProvider(rawValue: account.id), let desktop = connections.desktop {
                return desktop.account(provider, now: now)
            }
            if account.id == "deepseek" { return connections.deepSeekAccount(now: now) }
            if account.id == "minimax-api", let miniMax = connections.miniMax { return miniMax.account(now: now) }
            return account
        }
    }

    @MainActor
    static func ambient(service: AmbientQuotaService, snapshot: CodexQuotaSnapshot?, error: String?,
                        readsEnabled: Bool, connections: QuotaConnectionsStore,
                        tasksAreFresh: Bool, runningTaskCount: Int, now: Date) -> AmbientQuotaPresentation {
        let account = accounts(snapshot: snapshot, error: error, readsEnabled: readsEnabled,
            now: now, connections: connections).first { $0.id == service.rawValue }
            ?? pending(service.rawValue, service.name, "桌面会员", .membership)
        var observedAt: Date?, resetsAt: Date?
        if service == .codex {
            observedAt = snapshot?.observedAt
        } else if let membership = connections.websiteMemberships[service.rawValue] {
            observedAt = membership.snapshot?.observedAt
            resetsAt = membership.snapshot?.resetsAt
        } else if let provider = DesktopQuotaProvider(rawValue: service.rawValue) {
            let captured: DesktopQuotaSnapshot?
            if [.cursor, .grok].contains(provider), let cursor = connections.cursorAccount {
                captured = cursor.states[provider]?.snapshot
            } else {
                captured = connections.desktop?.states[provider]?.snapshot
            }
            observedAt = captured?.observedAt
            resetsAt = captured?.resetsAt
        }
        return .make(service: service, account: account,
            codexWindows: readsEnabled ? (snapshot?.visibleWindows ?? []) : [],
            resetsAt: resetsAt, observedAt: observedAt, tasksAreFresh: tasksAreFresh,
            runningTaskCount: runningTaskCount, at: now)
    }

    private static func pending(_ id: String, _ name: String, _ account: String,
                                _ group: QuotaOverviewGroup, kind: QuotaOverviewKind = .api) -> QuotaOverviewAccount {
        let reason: String
        switch id {
        case "muse": reason = "尚未连接 Muse 个人额度"
        case "minimax-audio": reason = "额度读取尚未适配"
        case "deepseek", "minimax-api": reason = "尚未连接 API Key"
        default: reason = "尚未连接原应用"
        }
        return QuotaOverviewAccount(id: id, name: name, account: account, group: group,
                             value: .unknown, timing: "尚未读取账户", status: .notConnected,
                             details: [.init(label: "数据来源", value: "尚未接入")],
                             explanation: "这是待接入的服务，不代表已连接你的账户。会员、API 钱包和配音积分分别记录；不会用示例数值填充，也不会读取其他应用的 Cookie 或密钥。", usageKind: kind,
                             unavailableReason: reason)
    }

    private static func codex(snapshot: CodexQuotaSnapshot?, error: String?, readsEnabled: Bool,
                              now: Date) -> QuotaOverviewAccount {
        guard let snapshot, let preferred = snapshot.preferredWindow, preferred.remainingPercent.isFinite else {
            return QuotaOverviewAccount(id: "codex", name: "Codex", account: "桌面会员",
                group: .membership, value: .unknown,
                timing: readsEnabled ? "等待有效额度数据" : "当前预览未启用读取",
                status: readsEnabled ? .unavailable : .notConnected,
                details: [.init(label: "数据来源", value: "现有 Codex 连接")],
                explanation: readsEnabled
                    ? (error == nil ? "正在等待现有 Codex 连接返回额度。没有数据不等于额度已用完。" : "本次读取未成功，未获得可显示的额度；请检查 Codex 登录后重试。")
                    : "此隔离预览没有启用真实账户读取。安装到原应用后复用已有连接，不会新增另一套登录。",
                unavailableReason: readsEnabled
                    ? (error == nil ? "尚未返回有效额度" : "Codex 读取失败，请检查登录")
                    : "尚未启用账户读取")
        }
        let age = now.timeIntervalSince(snapshot.observedAt)
        let expired = preferred.resetsAt.map { $0 <= now } ?? false
        let fresh = snapshot.freshness == .fresh && error == nil && age >= -60 && age <= 90 && !expired
        let plan = snapshot.planType.map { " · \($0.uppercased())" } ?? ""
        var details = [QuotaOverviewDetail(label: "数据来源", value: "与刘海共用 Codex 连接"),
                       .init(label: "最近读取", value: timestamp(snapshot.observedAt))]
        // Windows belong to one account; don't count a five-hour and a weekly quota as two accounts.
        for window in snapshot.visibleWindows where window.remainingPercent.isFinite {
            details.append(.init(label: "\(window.shortName)剩余", value: "\(Int(window.remainingPercent.rounded()))%"))
            details.append(.init(label: "\(window.shortName)重置", value: window.resetsAt.map(timestamp) ?? "未提供"))
        }
        return QuotaOverviewAccount(id: "codex", name: "Codex", account: "桌面会员\(plan)",
            group: .membership, value: .percent(Int(preferred.remainingPercent.rounded())),
            timing: resetDescription(preferred, now: now), status: fresh ? .current : .stale,
            details: details,
            explanation: fresh
                ? "显示账户返回的剩余额度，不是原始 token 数。重置时间由账户返回；公共公告不会直接修改这里的数值。"
                : "这是上次成功读取的数值，尚未确认当前额度。到达重置时间也不会自动变成 100%，需要账户再次返回有效数据。",
            unavailableReason: fresh ? nil : (error != nil ? "Codex 读取失败，请检查登录" : "数据已过期，请刷新确认"),
            pools: snapshot.visibleWindows.filter { $0.remainingPercent.isFinite }.map {
                .init(label: $0.shortName, value: .percent(Int($0.remainingPercent.rounded())),
                      timing: resetDescription($0, now: now))
            })
    }

    private static func timestamp(_ date: Date) -> String {
        date.formatted(.dateTime.month().day().hour().minute().locale(Locale(identifier: "zh_CN")))
    }

    private static func resetDescription(_ window: CodexQuotaWindow, now: Date) -> String {
        guard let reset = window.resetsAt else { return "未提供重置时间" }
        guard reset > now else { return "等待确认重置" }
        let label = QuotaResetCountdown.shortLabel(windowDurationMinutes: window.windowDurationMinutes,
                                                    resetsAt: reset, at: now)
        switch label {
        case "—": return "重置时间待确认"
        case "Q": return "\(timestamp(reset)) 重置"
        case "<1D": return "不到 1 天重置"
        case "<1H": return "不到 1 小时重置"
        default:
            return label.replacingOccurrences(of: "D", with: " 天后重置")
                .replacingOccurrences(of: "H", with: " 小时后重置")
        }
    }
}
