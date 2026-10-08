import Combine
import Foundation

enum WorkspacePanelLayout {
    static func size(isQuotaHome: Bool, isQuotaConnection: Bool = false,
                     topInset: CGFloat, screenWidth: CGFloat) -> CGSize {
        CGSize(width: min(isQuotaConnection ? 760 : isQuotaHome ? 600 : 868, screenWidth - 24),
               height: topInset + (isQuotaConnection ? 620 : isQuotaHome ? 438 : 417))
    }
}

/// Shared by the existing notch click route and its workspace; creates no windows.
@MainActor
final class WorkspaceNavigation: ObservableObject {
    @Published private(set) var selectedTab: AppTab = .home
    @Published private(set) var showsToolsHome = false
    @Published private(set) var showsQuotaConnections = false
    @Published var quotaConnectionSelection: String?
    var onLayoutChange: (() -> Void)?

    var isQuotaHome: Bool { selectedTab == .home && !showsToolsHome }
    var layoutKey: String { showsQuotaConnections && isQuotaHome ? "connections" : isQuotaHome ? "quota" : "tools" }

    func select(_ tab: AppTab) {
        let oldLayout = layoutKey
        showsQuotaConnections = false
        quotaConnectionSelection = nil
        showsToolsHome = false
        selectedTab = tab
        if oldLayout != layoutKey { onLayoutChange?() }
    }
    func openFromNotch() { select(.home) }
    func showToolsHome() {
        let oldLayout = layoutKey
        showsQuotaConnections = false
        quotaConnectionSelection = nil
        selectedTab = .home
        showsToolsHome = true
        if oldLayout != layoutKey { onLayoutChange?() }
    }
    func showQuotaConnections(selectedProvider: String? = nil) {
        let oldLayout = layoutKey
        quotaConnectionSelection = selectedProvider
        showsQuotaConnections = true
        if oldLayout != layoutKey { onLayoutChange?() }
    }
    func closeQuotaConnections() {
        let oldLayout = layoutKey
        showsQuotaConnections = false
        quotaConnectionSelection = nil
        if oldLayout != layoutKey { onLayoutChange?() }
    }
}
