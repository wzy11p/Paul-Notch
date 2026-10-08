import SwiftUI

/// Uses the same store and existing panel as the hardware-attached quota shelf.
struct QuotaHomeView: View {
    @ObservedObject var codexStatus: CodexStatusStore
    @ObservedObject var connections: QuotaConnectionsStore
    let tools: [QuotaOverviewTool]
    let onSelectTool: (String) -> Void
    let onClose: () -> Void
    @ObservedObject var navigation = WorkspaceNavigation()
    private var showsConnections: Bool { navigation.showsQuotaConnections }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var cardOrder = QuotaCardOrderStore(defaults: AppEnvironment.defaults)

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            ZStack {
            QuotaOverviewView(
                accounts: QuotaHomePresentation.accounts(snapshot: codexStatus.quota, error: codexStatus.quotaError,
                                                         readsEnabled: AppEnvironment.codexStatusReadsEnabled,
                                                         now: context.date, connections: connections),
                onClose: onClose, mode: .notch, tools: tools, onSelectTool: onSelectTool,
                onRefresh: AppEnvironment.codexStatusReadsEnabled || connections.allowsConnections ? {
                    if AppEnvironment.codexStatusReadsEnabled { codexStatus.refreshNow() }
                    connections.refreshAll()
                } : nil,
                isRefreshing: codexStatus.isRefreshing || connections.isDeepSeekRefreshing || connections.isFeedRefreshing
                    || connections.miniMax?.isRefreshing == true || connections.desktop?.reading != nil
                    || connections.cursorAccount?.isRefreshing == true
                    || connections.websiteMemberships.values.contains(where: \.isRefreshing),
                connectionContent: { id in
                    if ["cursor", "grok"].contains(id), let cursor = connections.cursorAccount {
                        return AnyView(CursorQuotaConnectionView(store: cursor))
                    }
                    if connections.websiteMemberships[id] != nil {
                        return AnyView(Button("管理连接") { navigation.showQuotaConnections(selectedProvider: id) }
                            .buttonStyle(.bordered).controlSize(.large))
                    }
                    if let provider = DesktopQuotaProvider(rawValue: id), let desktop = connections.desktop {
                        return AnyView(DesktopQuotaConnectionView(store: desktop, provider: provider))
                    }
                    if id == "deepseek" { return AnyView(DeepSeekConnectionView(connections: connections)) }
                    if id == "minimax-api", let miniMax = connections.miniMax { return AnyView(MiniMaxWalletConnectionView(store: miniMax)) }
                    return AnyView(QuotaProviderHelpView(provider: id))
                },
                noticeContent: AnyView(QuotaResetFeedView(connections: connections)), noticeLabel: connections.feedLabel,
                onAddService: { navigation.showQuotaConnections() },
                onConnectService: { navigation.showQuotaConnections(selectedProvider: $0) },
                savedOrder: cardOrder.saved,
                onReorder: { moved in
                    cardOrder.commit(moved, available: QuotaHomePresentation.accounts(snapshot: nil, error: nil,
                        readsEnabled: false, now: context.date).map(\.id))
                }, isActive: !showsConnections)
                .opacity(showsConnections ? 0 : 1)
                .allowsHitTesting(!showsConnections)
                .accessibilityHidden(showsConnections)
            if showsConnections {
                QuotaServiceConnectionsView(
                    connections: connections,
                    accounts: QuotaHomePresentation.accounts(snapshot: codexStatus.quota, error: codexStatus.quotaError,
                        readsEnabled: AppEnvironment.codexStatusReadsEnabled, now: context.date, connections: connections),
                    selectedProvider: $navigation.quotaConnectionSelection,
                    codexReadsEnabled: AppEnvironment.codexStatusReadsEnabled,
                    isCodexRefreshing: codexStatus.isRefreshing,
                    onCheckCodex: { codexStatus.refreshNow() },
                    onClose: { navigation.closeQuotaConnections() }, onCollapse: onClose)
                    .transition(QuotaInteractionMotion.entrance)
            }
            }
            .animation(QuotaInteractionMotion.content(reduceMotion: reduceMotion), value: showsConnections)
        }
    }
}
