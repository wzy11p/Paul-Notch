import SwiftUI

/// Bounded presentation reused by the notch Home and synthetic layout harness.
struct QuotaOverviewView: View {
    let accounts: [QuotaOverviewAccount]
    let onClose: () -> Void
    var mode: QuotaOverviewMode = .preview
    var tools: [QuotaOverviewTool] = []
    var onSelectTool: (String) -> Void = { _ in }
    var onRefresh: (() -> Void)? = nil
    var isRefreshing = false
    var connectionContent: (String) -> AnyView = { _ in AnyView(EmptyView()) }
    var noticeContent: AnyView? = nil
    var noticeLabel: String? = nil
    var onAddService: (() -> Void)? = nil
    var onConnectService: ((String) -> Void)? = nil
    var savedOrder: [String] = []
    var onReorder: (([String]) -> Void)? = nil
    var onRemove: ((String) -> Void)? = nil
    var onRestore: ((String) -> Void)? = nil
    var onLayoutChange: (QuotaHomeLayout) -> Void = { _ in }
    var isActive = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedControl: FocusTarget?
    private enum FocusTarget: Hashable { case search, back }
    @State private var sessionOrder: [String] = []
    @State private var search = ""
    @State private var filter: QuotaOverviewFilter = .all
    @State private var selectedID: String?
    @State private var pinnedID: String?
    @State private var showsNoticeExplanation = false
    @State private var showsSearch = false
    @State private var isEditingCards = false
    @State private var lastRemoved: (id: String, name: String)?

    private var results: [QuotaOverviewAccount] {
        let order = QuotaCardOrder.resolved(saved: onReorder == nil ? sessionOrder : savedOrder,
                                            available: accounts.map(\.id))
        let byID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        return QuotaOverviewQuery.matches(order.compactMap { byID[$0] }, search: search, filter: filter)
    }
    private var selected: QuotaOverviewAccount? { accounts.first { $0.id == selectedID } }
    private var pinned: QuotaOverviewAccount? { accounts.first { $0.id == pinnedID } }
    private var layoutRequest: QuotaHomeLayout {
        QuotaHomeLayout(accountCount: results.count,
            supplementaryHeight: (showsSearch ? 46 : 0) + (lastRemoved != nil ? 26 : isEditingCards ? 16 : 0),
            minimumBodyHeight: selected != nil || showsNoticeExplanation ? 360 : 0)
    }
    private var removalAction: ((String) -> Void)? {
        guard onRemove != nil else { return nil }
        return { id in removeAccount(id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if mode == .preview {
                Text("交互预览 · 示例数值，尚未连接真实账户")
                    .font(.system(size: 12)).foregroundStyle(QuotaOverviewPalette.secondary)
            }
            ZStack {
                // Keep scroll views alive behind details so returning doesn't jump to the top.
                VStack(spacing: 14) {
                    if showsSearch { controls }
                    overview
                }
                .opacity(selected == nil && !showsNoticeExplanation ? 1 : 0)
                .allowsHitTesting(selected == nil && !showsNoticeExplanation)
                .accessibilityHidden(selected != nil || showsNoticeExplanation)
                if showsNoticeExplanation {
                    VStack(alignment: .leading, spacing: 8) {
                        Button { showsNoticeExplanation = false } label: {
                        QuotaBackButtonLabel()
                        }
                        .buttonStyle(QuotaOverviewButtonStyle())
                        .accessibilityIdentifier("quota-notice-back")
                        if let noticeContent { noticeContent }
                        else {
                            Text("公告接入后会在这里显示来源、时间与确认状态，不会改写个人额度。")
                                .font(.system(size: 12)).foregroundStyle(QuotaOverviewPalette.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else if let selected {
                    details(selected)
                        .transition(QuotaInteractionMotion.entrance)
                        .onAppear { focusedControl = .back }
                }
            }
            .frame(maxHeight: .infinity)
            .animation(QuotaInteractionMotion.content(reduceMotion: reduceMotion), value: selectedID)
            footer
        }
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(QuotaOverviewPalette.primary)
        .background(Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .preferredColorScheme(.dark)
        .disabled(!isActive)
        .onAppear { onLayoutChange(layoutRequest) }
        .onChange(of: layoutRequest) { onLayoutChange($0) }
        .background {
            Button("搜索账户") { showsSearch = true; focusedControl = .search }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(!isActive || selectedID != nil || showsNoticeExplanation)
                .hidden().accessibilityHidden(true)
            if let onRefresh {
                Button("刷新额度", action: onRefresh)
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(isRefreshing || !isActive || showsNoticeExplanation)
                    .hidden().accessibilityHidden(true)
            }
        }
        .onExitCommand {
            guard isActive else { return }
            if showsNoticeExplanation { showsNoticeExplanation = false }
            else if selectedID != nil { selectedID = nil }
            else if !search.isEmpty { search = ""; focusedControl = .search }
            else if showsSearch { showsSearch = false; filter = .all; focusedControl = nil }
            else if isEditingCards { isEditingCards = false }
            else { onClose() }
        }
        .onChange(of: isActive) { if !$0 { focusedControl = nil; isEditingCards = false } }
        .onChange(of: accounts.map(\.id)) { ids in
            if let selectedID, !ids.contains(selectedID) { self.selectedID = nil }
            if let pinnedID, !ids.contains(pinnedID) { self.pinnedID = nil }
            if let lastRemoved, ids.contains(lastRemoved.id) { self.lastRemoved = nil }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: PaulBrand.menuBarImage()).resizable().frame(width: 18, height: 18)
                .accessibilityHidden(true)
            Text("我的 AI").font(.system(size: 17, weight: .semibold))
            Spacer(minLength: 0)
            if let onAddService {
                Button(action: onAddService) {
                    Label("连接", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10).frame(height: 30)
                }
                .buttonStyle(QuotaOverviewButtonStyle())
                .accessibilityIdentifier("quota-add-service")
                .help("添加服务或管理已有连接")
            }
            if onRemove != nil {
                Button {
                    selectedID = nil; showsNoticeExplanation = false; focusedControl = nil
                    isEditingCards.toggle()
                } label: {
                    Text(isEditingCards ? "完成" : "编辑").font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10).frame(height: 30)
                }
                .buttonStyle(QuotaOverviewButtonStyle(isSelected: isEditingCards))
                .help("点减号从首页移除卡片，不会断开连接")
                .accessibilityIdentifier("quota-edit-cards")
            }
            Menu {
                Button("搜索与筛选") { showsSearch = true; focusedControl = .search }
                    .disabled(selectedID != nil || showsNoticeExplanation || !isActive)
                if let onRefresh {
                    Button(isRefreshing ? "正在刷新…" : "刷新额度", action: onRefresh)
                        .disabled(isRefreshing || !isActive || showsNoticeExplanation)
                }
                if !tools.isEmpty {
                    Divider()
                    ForEach(tools) { tool in
                        Button { onSelectTool(tool.id) } label: {
                            Label(tool.title, systemImage: tool.systemImage)
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 14, weight: .medium))
                    .frame(width: 30, height: 30)
            }
            .menuStyle(.button).menuIndicator(.hidden)
            .buttonStyle(QuotaOverviewButtonStyle()).fixedSize()
            .accessibilityLabel("更多功能、搜索与刷新")
            Button(action: onClose) {
                Image(systemName: mode == .notch ? "chevron.up" : "xmark")
                    .font(.system(size: 12, weight: .medium)).frame(width: 30, height: 30)
            }
            .buttonStyle(QuotaOverviewButtonStyle())
            .help(mode == .notch ? "收起面板，保留当前额度" : "关闭交互预览，不影响正式版")
            .accessibilityLabel(mode == .notch ? "收起面板" : "关闭预览")
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(QuotaOverviewPalette.secondary)
                TextField("搜索服务或账户", text: $search)
                    .textFieldStyle(.plain).accessibilityLabel("搜索账户")
                    .accessibilityIdentifier("quota-search")
                    .focused($focusedControl, equals: .search)
                    .onAppear { focusedControl = .search }
                if !search.isEmpty {
                    Button { search = ""; focusedControl = .search } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(QuotaOverviewPalette.secondary)
                    }
                    .buttonStyle(.plain).help("清除搜索")
                    .accessibilityLabel("清除搜索")
                }
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(QuotaOverviewPalette.surface, in: Capsule())
            Picker("类型", selection: $filter) {
                ForEach(QuotaOverviewFilter.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .labelsHidden().pickerStyle(.menu).frame(width: 116)
            .accessibilityLabel("筛选账户类型")
        }
    }

    private var overview: some View {
        GeometryReader { geometry in
            if results.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(accounts.isEmpty ? "还没有账户" : "没有找到匹配的账户")
                        .font(.system(size: 16, weight: .semibold))
                    Text(accounts.isEmpty ? "点「连接」添加服务，或加回已移除的卡片。" : "换个名称试试，或把类型切回全部。")
                        .font(.system(size: 13)).foregroundStyle(QuotaOverviewPalette.secondary)
                    if !accounts.isEmpty {
                        Button("清除搜索与筛选") {
                            search = ""; filter = .all; focusedControl = .search
                        }
                        .buttonStyle(.bordered).controlSize(.large)
                        .accessibilityIdentifier("quota-reset-search")
                    } else if let onAddService {
                        Button("添加或加回服务", action: onAddService)
                            .buttonStyle(.bordered).controlSize(.large)
                            .accessibilityIdentifier("quota-empty-add-service")
                    }
                }
                .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                QuotaReorderableGrid(accounts: results, pinnedID: mode == .preview ? pinnedID : nil,
                    enabled: isActive && selectedID == nil && !showsNoticeExplanation,
                    isEditing: isEditingCards,
                    onRemove: removalAction,
                    onOpen: { id in
                        if let account = accounts.first(where: { $0.id == id }), account.value == .unknown,
                           let onConnectService { onConnectService(id) }
                        else { selectedID = id }
                    },
                    onReorder: { moved in
                        if let onReorder { onReorder(moved) }
                        else {
                            let current = QuotaCardOrder.resolved(saved: sessionOrder, available: accounts.map(\.id))
                            sessionOrder = QuotaCardOrder.merging(visible: moved, into: current)
                        }
                    })
            }
        }
        .frame(minHeight: 0, maxHeight: .infinity)
    }

    private func details(_ item: QuotaOverviewAccount) -> some View {
        let needsConnection = mode == .notch && ["deepseek", "minimax-api"].contains(item.id) && item.value == .unknown
        return VStack(alignment: .leading, spacing: 16) {
            Button { selectedID = nil } label: {
                    QuotaBackButtonLabel()
            }
            .buttonStyle(QuotaOverviewButtonStyle()).accessibilityIdentifier("quota-back")
            .keyboardShortcut(.cancelAction)
            .focused($focusedControl, equals: .back)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.name).font(.system(size: 22, weight: .semibold))
                        Spacer()
                        Text(item.displayValue).font(.system(size: 24, weight: .semibold)).monospacedDigit()
                    }
                    Text(item.account).foregroundStyle(QuotaOverviewPalette.secondary)
                    if onRemove != nil {
                        Button { removeAccount(item.id) } label: {
                            Label("从首页移除", systemImage: "minus.circle")
                        }
                        .buttonStyle(.bordered)
                        .help("只隐藏这张卡片，不会断开连接；可在「连接」中加回")
                        .accessibilityIdentifier("quota-detail-remove-\(item.id)")
                    }
                    if let reason = item.displayReason {
                        Text(reason).font(.system(size: 13)).foregroundStyle(QuotaOverviewPalette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if item.status == .stale && item.value != .unknown {
                            LabeledContent("上次读取（非当前额度）", value: item.value.text)
                        }
                    }
                    if !needsConnection {
                    Divider()
                    LabeledContent("时间", value: item.timing)
                    LabeledContent("状态", value: item.status.rawValue)
                    ForEach(Array(item.details.enumerated()), id: \.offset) { _, detail in
                        LabeledContent(detail.label, value: detail.value)
                    }
                    if mode == .preview { LabeledContent("数据来源", value: "本地示例，不是实时账户数据") }
                    Text(mode == .preview
                         ? "这里只验证点击、查找和固定操作。会员额度、API 钱包和配音积分保持独立；公共公告不会改写账户数值。"
                         : item.explanation)
                        .font(.system(size: 12)).foregroundStyle(QuotaOverviewPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    if mode == .notch { connectionContent(item.id).id(item.id) }
                    if mode == .preview {
                        Button {
                            pinnedID = pinnedID == item.id ? nil : item.id
                        } label: {
                            Label(pinnedID == item.id ? "取消固定（预览）" : "固定到刘海（预览）", systemImage: "pin")
                                .frame(minHeight: 28)
                        }
                        .buttonStyle(.bordered).controlSize(.large)
                        .disabled(item.status == .notConnected || item.value == .unknown)
                        .help("只影响本次预览，不修改正在使用的正式版")
                        .accessibilityIdentifier("quota-pin")
                    }
                }.font(.system(size: 13)).padding(16)
            }
            .background(QuotaOverviewPalette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }.frame(maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(spacing: 4) {
            if let lastRemoved, let onRestore {
                HStack(spacing: 8) {
                    Text("已移除 \(lastRemoved.name)，登录保留").font(.system(size: 10))
                        .foregroundStyle(QuotaOverviewPalette.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    Button("撤销") { onRestore(lastRemoved.id); self.lastRemoved = nil }
                        .buttonStyle(.bordered).controlSize(.small)
                        .accessibilityIdentifier("quota-undo-remove")
                }
            } else if isEditingCards {
                Text("点减号移除卡片，登录和后台同步保留")
                    .font(.system(size: 10)).foregroundStyle(QuotaOverviewPalette.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 12) {
                Button { showsNoticeExplanation.toggle() } label: {
                    Label(noticeLabel ?? (mode == .notch ? "重置公告 · 待接入" : "重置公告单独展示"), systemImage: "bell")
                        .font(.system(size: 11)).lineLimit(1).padding(.horizontal, 6).frame(height: 24)
                }
                .buttonStyle(QuotaOverviewButtonStyle(isSelected: showsNoticeExplanation, quiet: true))
                .accessibilityIdentifier("quota-reset-notice")
                Spacer(minLength: 0)
                Text(mode == .notch ? "\(accounts.count) 项服务" : pinned.map { "预览固定：\($0.name)" } ?? "\(accounts.count) 个账户")
                    .font(.system(size: 10)).foregroundStyle(QuotaOverviewPalette.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func removeAccount(_ id: String) {
        guard isActive, let account = accounts.first(where: { $0.id == id }), let onRemove else { return }
        lastRemoved = (id, account.name)
        if selectedID == id { selectedID = nil }
        onRemove(id)
    }
}

struct QuotaOverviewAccountCard: View {
    let account: QuotaOverviewAccount
    let isPinned: Bool
    let onOpen: () -> Void
    var interaction: QuotaCardInteraction? = nil

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    if let logo = ProviderBrandAssets.image(for: account.id) {
                        Image(nsImage: logo).renderingMode(.original).resizable().scaledToFit()
                            .frame(width: 23, height: 23).accessibilityHidden(true)
                    } else {
                        // The adjacent service name identifies an unverified brand. Never fabricate a mark.
                        Color.clear.frame(width: 23, height: 23).accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 2) {
                            Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.85)
                            if isPinned { Image(systemName: "pin.fill").font(.system(size: 8)).accessibilityHidden(true) }
                        }
                        Text(caption).font(.system(size: 9)).foregroundStyle(secondaryColor)
                            .lineLimit(1).minimumScaleFactor(0.85)
                    }
                }
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(readingPools.enumerated()), id: \.offset) { _, pool in
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(alignment: .firstTextBaseline, spacing: 3) {
                                    Text(QuotaGlanceText.poolLabel(provider: account.id, label: pool.label, sourceID: pool.sourceID))
                                        .font(.system(size: 8)).foregroundStyle(secondaryColor)
                                        .lineLimit(1).minimumScaleFactor(0.8)
                                    Spacer(minLength: 0)
                                    Text(account.displayReason == nil ? pool.value.text : "—")
                                        .font(.system(size: 16, weight: .medium)).monospacedDigit()
                                        .foregroundStyle(amountColor(pool.value)).lineLimit(1).minimumScaleFactor(0.8)
                                }
                                Text(account.displayReason == nil ? compactTiming(pool.timing) : briefStatus)
                                    .font(.system(size: 8.5)).foregroundStyle(secondaryColor)
                                    .lineLimit(1).minimumScaleFactor(0.8)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.frame(height: 60, alignment: readingPools.count > 1 ? .top : .center)
                Spacer(minLength: 0)
            }
            .padding(8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(QuotaBubbleButtonStyle(interaction: interaction))
        .foregroundStyle(QuotaOverviewPalette.primary)
        .help(account.accessibilitySummary)
        .accessibilityLabel(account.accessibilitySummary)
        .accessibilityHint("打开额度详情")
        .accessibilityIdentifier("quota-account-\(account.id)")
    }

    private var title: String {
        ["minimax-api", "minimax-audio"].contains(account.id) ? "MiniMax" : account.id == "deepseek" ? "DeepSeek" : account.name
    }
    private var readingPools: [QuotaOverviewPool] {
        if !account.visiblePools.isEmpty { return account.visiblePools }
        return [.init(label: account.kind == .api ? "余额" : "剩余", value: account.value, timing: account.timing)]
    }
    private var caption: String {
        switch account.id {
        case "codex": "OpenAI"
        case "cursor": "Anysphere"
        case "grok": "Cursor 计费"
        case "doubao": "ByteDance"
        case "muse": "Meta"
        case "deepseek", "minimax-api": "API · 钱包"
        case "minimax-audio": "Audio · 配音"
        default: account.kind.rawValue
        }
    }
    private var briefStatus: String {
        if account.displayReason?.contains("适配") == true { return "待适配" }
        switch account.status {
        case .notConnected: return "未连接"
        case .stale: return "待更新"
        default: return "读取失败"
        }
    }
    private func compactTiming(_ timing: String) -> String {
        QuotaGlanceText.timing(timing)
    }
    private var secondaryColor: Color {
        Color(.sRGB, red: 0.72, green: 0.73, blue: 0.75)
    }
    private func amountColor(_ value: QuotaOverviewValue) -> Color {
        guard account.displayReason == nil, let fraction = value.fraction else { return QuotaOverviewPalette.primary }
        if fraction > 0.5 { return QuotaOverviewPalette.primary }
        if fraction > 0.2 { return Color(red: 0.94, green: 0.74, blue: 0.35) }
        return Color(red: 1, green: 0.49, blue: 0.45)
    }
}

/// One smoky graphite surface for every service. Brand artwork and captions
/// identify the provider; color remains reserved for quota warnings.
private struct QuotaBubbleButtonStyle: ButtonStyle {
    var interaction: QuotaCardInteraction? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed = interaction?.pressed ?? configuration.isPressed
        let hovered = interaction?.hovered ?? isHovered
        let lift = interaction?.lifted == true ? 0.048 : pressed ? -0.025 : hovered ? 0.035 : 0
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(LinearGradient(colors: [surface(lift: lift + 0.012), surface(lift: lift - 0.006)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(LinearGradient(colors: [.white.opacity(pressed ? 0.08 : 0.12),
                                .white.opacity(0.025)], startPoint: .top, endPoint: .bottom), lineWidth: 0.7)
                    }
                    .shadow(color: .black.opacity(pressed ? 0.05 : 0.12), radius: pressed ? 1 : 2.5, x: 0, y: pressed ? 0 : 1.5)
            }
            .scaleEffect(!reduceMotion && pressed && interaction?.lifted != true ? 0.985 : 1)
            .animation(reduceMotion || pressed ? nil : QuotaInteractionMotion.feedback, value: pressed)
            .animation(reduceMotion ? nil : QuotaInteractionMotion.feedback, value: hovered)
            .onHover { isHovered = $0 }
    }

    private func surface(lift: Double) -> Color {
        Color(.sRGB, red: 32.0 / 255 + lift, green: 33.0 / 255 + lift, blue: 36.0 / 255 + lift)
    }
}

/// Styling only. SwiftUI Button retains native press/release, cancellation,
/// focus and accessibility semantics; no tap/drag recognizer replaces them.
struct QuotaBackButtonLabel: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
            Text("全部账户").font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 12).frame(minWidth: 98, minHeight: 32)
        .fixedSize(horizontal: true, vertical: true)
    }
}

struct QuotaOverviewButtonStyle: ButtonStyle {
    var isSelected = false
    var quiet = false
    var cornerRadius: CGFloat = 10
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed && isEnabled
        let lift = pressed ? -0.035 : isHovered && isEnabled ? 0.045 : 0
        configuration.label
            .foregroundStyle(isSelected ? Color(red: 0.74, green: 0.86, blue: 1) : QuotaOverviewPalette.primary)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.29 + lift), Color(white: 0.23 + lift)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(LinearGradient(colors: [.white.opacity(pressed ? 0.05 : 0.16), .white.opacity(0.03)],
                                startPoint: .top, endPoint: .bottom), lineWidth: 0.6)
                    }
                    .opacity(quiet && !isHovered && !pressed && !isSelected ? 0 : 1)
            }
            .scaleEffect(!reduceMotion && pressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(reduceMotion || pressed ? nil : QuotaInteractionMotion.feedback, value: pressed)
            .animation(reduceMotion ? nil : QuotaInteractionMotion.feedback, value: isHovered)
            .onHover { isHovered = $0 }
    }
}

enum QuotaOverviewPalette {
    static let primary = Color(white: 0.96)
    static let secondary = Color(white: 0.66)
    static let surface = Color(white: 0.19)
}

/// One native frosted surface under a black tint. Keep the bezel transition
/// near-black even over a bright desktop; do not paint an opaque graphite slab.
struct QuotaPanelBackdrop: View {
    var isDocked = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        WorkspaceSurfaceShape(isDocked: isDocked)
            .fill(.regularMaterial)
            .overlay {
                WorkspaceSurfaceShape(isDocked: isDocked)
                    .fill(reduceTransparency ? Color(white: 0.015) : Color.black.opacity(0.92))
            }
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// The hardware band stays black; its lower edge fades into the actual material
/// instead of guessing an opaque gray that changes with the desktop behind it.
struct QuotaDockedTopBlend: View {
    let topInset: CGFloat
    var body: some View {
        let start = max(0, topInset - 4)
        let height = start + 60
        // Smootherstep has zero slope at both ends: no abrupt start or gray lip.
        let stops = (0...12).map { index -> Gradient.Stop in
            let t = Double(index) / 12
            let fade = t * t * t * (t * (t * 6 - 15) + 10)
            return .init(color: .black.opacity(1 - fade),
                         location: (start + CGFloat(t) * 60) / height)
        }
        LinearGradient(stops: [.init(color: .black, location: 0)] + stops,
                       startPoint: .top, endPoint: .bottom)
            .frame(height: height)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Timing adapted from TO-DO Panel v1.1.2 renderer/styles.css (MIT).
/// Copyright (c) 2026 TO-DO Panel contributors. See THIRD_PARTY_NOTICES.md.
/// Presses stay immediate. Exits remove controls immediately, including secure forms.
@MainActor enum QuotaInteractionMotion {
    static let feedback = Animation.timingCurve(0.25, 0.46, 0.45, 0.94, duration: 0.14)
    static let entrance = AnyTransition.asymmetric(insertion: .opacity, removal: .identity)
    static func content(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .timingCurve(0.16, 1, 0.3, 1, duration: 0.18)
    }
}
