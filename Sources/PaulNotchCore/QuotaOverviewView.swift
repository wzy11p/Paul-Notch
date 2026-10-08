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

    private var results: [QuotaOverviewAccount] {
        let order = QuotaCardOrder.resolved(saved: onReorder == nil ? sessionOrder : savedOrder,
                                            available: accounts.map(\.id))
        let byID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        return QuotaOverviewQuery.matches(order.compactMap { byID[$0] }, search: search, filter: filter)
    }
    private var selected: QuotaOverviewAccount? { accounts.first { $0.id == selectedID } }
    private var pinned: QuotaOverviewAccount? { accounts.first { $0.id == pinnedID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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
                .opacity(selected == nil ? 1 : 0)
                .allowsHitTesting(selected == nil)
                .accessibilityHidden(selected != nil)
                if let selected {
                    details(selected)
                        .transition(QuotaInteractionMotion.entrance)
                        .onAppear { focusedControl = .back }
                }
            }
            .frame(maxHeight: .infinity)
            .animation(QuotaInteractionMotion.content(reduceMotion: reduceMotion), value: selectedID)
            footer
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(QuotaOverviewPalette.primary)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .preferredColorScheme(.dark)
        .disabled(!isActive)
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
            else { onClose() }
        }
        .onChange(of: isActive) { if !$0 { focusedControl = nil } }
        .onChange(of: accounts.map(\.id)) { ids in
            if let selectedID, !ids.contains(selectedID) { self.selectedID = nil }
            if let pinnedID, !ids.contains(pinnedID) { self.pinnedID = nil }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: PaulBrand.menuBarImage()).resizable().frame(width: 18, height: 18)
                .accessibilityHidden(true)
            Text("我的 AI").font(.system(size: 17, weight: .semibold))
            Spacer(minLength: 0)
            if let onAddService {
                Button(action: onAddService) {
                    Label("连接", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10).frame(height: 32)
                }
                .buttonStyle(QuotaOverviewButtonStyle())
                .background(QuotaOverviewPalette.surface, in: Capsule())
                .accessibilityIdentifier("quota-add-service")
                .help("添加服务或管理已有连接")
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
            } label: { Image(systemName: "ellipsis").frame(width: 32, height: 32) }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel("更多功能、搜索与刷新")
            Button(action: onClose) {
                Image(systemName: mode == .notch ? "chevron.up" : "xmark").frame(width: 32, height: 32)
            }
            .buttonStyle(QuotaOverviewButtonStyle())
            .help(mode == .notch ? "收起面板，保留刘海额度" : "关闭交互预览，不影响正式版")
            .accessibilityLabel(mode == .notch ? "收起刘海" : "关闭预览")
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
                    Text(accounts.isEmpty ? "接入后的账户会显示在这里。" : "换个名称试试，或把类型切回全部。")
                        .font(.system(size: 13)).foregroundStyle(QuotaOverviewPalette.secondary)
                    if !accounts.isEmpty {
                        Button("清除搜索与筛选") {
                            search = ""; filter = .all; focusedControl = .search
                        }
                        .buttonStyle(.bordered).controlSize(.large)
                        .accessibilityIdentifier("quota-reset-search")
                    }
                }
                .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                QuotaReorderableGrid(accounts: results, pinnedID: mode == .preview ? pinnedID : nil,
                    enabled: isActive && selectedID == nil,
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
                Label("全部账户", systemImage: "chevron.left").font(.system(size: 13))
                    .padding(.horizontal, 12).frame(height: 36)
            }
            .buttonStyle(QuotaOverviewButtonStyle()).accessibilityIdentifier("quota-back")
            .keyboardShortcut(.cancelAction)
            .focused($focusedControl, equals: .back)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.name).font(.system(size: 22, weight: .semibold))
                        Spacer()
                        Text(item.displayValue).font(.system(size: 24, weight: .semibold)).monospacedDigit()
                    }
                    Text(item.account).foregroundStyle(QuotaOverviewPalette.secondary)
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
            HStack(spacing: 12) {
                Button { showsNoticeExplanation.toggle() } label: {
                    Label(noticeLabel ?? (mode == .notch ? "重置公告 · 待接入" : "重置公告单独展示"), systemImage: "bell")
                        .font(.system(size: 11)).padding(.horizontal, 8).frame(height: 32)
                }
                .buttonStyle(QuotaOverviewButtonStyle())
                .popover(isPresented: $showsNoticeExplanation) {
                    if let noticeContent { noticeContent } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("公告 ≠ 个人额度重置").font(.headline)
                        Text("公告功能尚未接入，不会发送通知。接入后保留消息来源、时间和确认状态；只有重新查询账户成功后，才更新个人额度。")
                            .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    }.padding(20).frame(width: 300).background(QuotaOverviewPalette.surface)
                    }
                }
                Spacer(minLength: 0)
                Text(mode == .notch ? "\(accounts.count) 项服务" : pinned.map { "预览固定：\($0.name)" } ?? "\(accounts.count) 个账户")
                    .font(.system(size: 10)).foregroundStyle(QuotaOverviewPalette.secondary)
                    .lineLimit(1)
            }
        }
    }
}

struct QuotaOverviewAccountCard: View {
    let account: QuotaOverviewAccount
    let isPinned: Bool
    let onOpen: () -> Void
    var interaction: QuotaCardInteraction? = nil

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 9) {
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
                if account.visiblePools.count == 2 {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(Array(account.visiblePools.enumerated()), id: \.offset) { _, pool in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(pool.label).font(.system(size: 9)).foregroundStyle(secondaryColor)
                                    .lineLimit(1).minimumScaleFactor(0.8)
                                Text(pool.value.text).font(.system(size: 17, weight: .medium)).monospacedDigit()
                                    .foregroundStyle(amountColor(pool.value)).lineLimit(1).minimumScaleFactor(0.65)
                                Text(compactTiming(pool.timing)).font(.system(size: 9)).foregroundStyle(secondaryColor)
                                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } else {
                    Text(account.displayValue).font(.system(size: 23, weight: .medium)).monospacedDigit()
                        .foregroundStyle(account.displayReason == nil ? amountColor(account.value) : secondaryColor)
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(account.displayReason == nil ? compactTiming(account.timing) : briefStatus)
                        .font(.system(size: 10)).foregroundStyle(secondaryColor)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(QuotaBubbleButtonStyle(kind: account.kind, interaction: interaction))
        .foregroundStyle(QuotaOverviewPalette.primary)
        .help(account.accessibilitySummary)
        .accessibilityLabel(account.accessibilitySummary)
        .accessibilityHint("打开额度详情")
        .accessibilityIdentifier("quota-account-\(account.id)")
    }

    private var title: String {
        ["minimax-api", "minimax-audio"].contains(account.id) ? "MiniMax" : account.id == "deepseek" ? "DeepSeek" : account.name
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
        timing.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "小时", with: "时")
            .replacingOccurrences(of: "分钟", with: "分")
    }
    private var secondaryColor: Color {
        switch account.kind {
        case .membership: Color(white: 0.72)
        case .api: Color(red: 0.65, green: 0.76, blue: 0.85)
        case .audio: Color(red: 0.78, green: 0.72, blue: 0.85)
        }
    }
    private func amountColor(_ value: QuotaOverviewValue) -> Color {
        guard account.displayReason == nil, let fraction = value.fraction else { return QuotaOverviewPalette.primary }
        if fraction > 0.5 { return QuotaOverviewPalette.primary }
        if fraction > 0.2 { return Color(red: 0.94, green: 0.74, blue: 0.35) }
        return Color(red: 1, green: 0.49, blue: 0.45)
    }
}

/// Opaque, softly raised bubbles: no wallpaper/text bleed, no layout-moving scale effect.
private struct QuotaBubbleButtonStyle: ButtonStyle {
    let kind: QuotaOverviewKind
    var interaction: QuotaCardInteraction? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed = interaction?.pressed ?? configuration.isPressed
        let hovered = interaction?.hovered ?? isHovered
        let lift = interaction?.lifted == true ? 0.08 : pressed ? 0.09 : hovered ? 0.05 : 0
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(surface(lift: lift))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(Color.white.opacity(pressed ? 0.04 : 0.08), lineWidth: 0.5)
                    }
                    .animation(reduceMotion || pressed ? nil : QuotaInteractionMotion.feedback, value: pressed)
                    .animation(reduceMotion ? nil : QuotaInteractionMotion.feedback, value: hovered)
            }
            .onHover { isHovered = $0 }
    }

    private func surface(lift: Double) -> Color {
        switch kind {
        case .membership: Color(white: 0.13 + lift)
        case .api: Color(red: 0.085 + lift, green: 0.125 + lift, blue: 0.17 + lift)
        case .audio: Color(red: 0.135 + lift, green: 0.105 + lift, blue: 0.17 + lift)
        }
    }
}

/// Styling only. SwiftUI Button retains native press/release, cancellation,
/// focus and accessibility semantics; no tap/drag recognizer replaces them.
struct QuotaOverviewButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(!isEnabled ? 0 : configuration.isPressed ? 0.13 : isHovered ? 0.06 : 0))
                    .animation(reduceMotion || configuration.isPressed ? nil : QuotaInteractionMotion.feedback,
                               value: configuration.isPressed)
                    .animation(reduceMotion ? nil : QuotaInteractionMotion.feedback, value: isHovered)
            }
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { isHovered = $0 }
    }
}

enum QuotaOverviewPalette {
    static let primary = Color(white: 0.96)
    static let secondary = Color(white: 0.66)
    static let surface = Color(white: 0.095)
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
