import AppKit
import SwiftUI
@testable import PaulNotchCore

@main
struct QuotaHomeIntegrationValidation {
    @MainActor static func main() {
        var failures: [String] = []
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            if !value() { failures.append(message); print("FAIL: \(message)") }
        }
        let navigation = WorkspaceNavigation()
        let quotaSize = WorkspacePanelLayout.size(isQuotaHome: true, topInset: 38, screenWidth: 1440)
        check(quotaSize.width <= 530 && quotaSize.height < 400, "Quota Home fits a compact two-row panel")
        let toolSize = WorkspacePanelLayout.size(isQuotaHome: false, topInset: 38, screenWidth: 1440)
        check(toolSize.width == 868, "Legacy tools must keep their existing working width")
        check(navigation.selectedTab == .home, "The existing workspace must start at quota Home, not Memo")
        navigation.select(.clipboard)
        navigation.openFromNotch()
        check(navigation.selectedTab == .home && !navigation.showsToolsHome,
              "Opening the notch after another module must return to quota Home")
        navigation.showToolsHome()
        check(navigation.selectedTab == .home && navigation.showsToolsHome,
              "The original tool home must remain reachable without replacing quota Home")
        navigation.select(.memo)
        check(navigation.selectedTab == .memo && !navigation.showsToolsHome,
              "Selecting a feature must clear the legacy home subroute")

        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let weekly = CodexQuotaWindow(id: "codex:secondary", limitID: "codex", limitName: nil,
                                      windowName: "次窗口", usedPercent: 3, windowDurationMinutes: 10080,
                                      resetsAt: now.addingTimeInterval(6 * 86400))
        let short = CodexQuotaWindow(id: "codex:primary", limitID: "codex", limitName: nil,
                                     windowName: "主窗口", usedPercent: 22, windowDurationMinutes: 300,
                                     resetsAt: now.addingTimeInterval(3 * 3600))
        let snapshot = CodexQuotaSnapshot(planType: "pro", windows: [weekly, short], resetCreditCount: nil,
                                          observedAt: now, freshness: .fresh)
        let accounts = QuotaHomePresentation.accounts(snapshot: snapshot, error: nil, readsEnabled: true, now: now)
        check(accounts.contains { $0.id == "cursor" }, "Quota Home must include the owner's Cursor membership")
        let muse = accounts.first { $0.id == "muse" }
        check(muse?.name == "Muse" && muse?.group == .membership,
              "The owner's Meta Muse must appear in the actual Home as a desktop membership, not a Meta API wallet")
        check(muse?.value == .unknown && muse?.status == .notConnected,
              "Adding Muse without a verified personal source must not fabricate an amount or claim synchronization")
        check(QuotaOverviewQuery.matches(accounts, search: "Meta", filter: .membership).map(\.id) == ["muse"],
              "The Muse account must be identifiable by its actual company in the self-service catalog")
        check(QuotaCardOrder.resolved(saved: ["cursor", "codex"], available: accounts.map(\.id)).contains("muse"),
              "Existing saved ordering must not hide the newly added Muse account")
        check(!accounts.contains { $0.id == "kimi" }, "The postponed Kimi integration must not appear in the active service catalog")
        check(accounts.first { $0.id == "grok" }?.name == "Grok Bot", "The owner's Cursor-billed Grok Bot must not be labeled SuperGrok")
        check(accounts.first?.value == .percent(78), "Home's primary Codex value must come from the same preferred window as the notch")
        check(accounts.first?.visiblePools.map(\.value) == [.percent(97), .percent(78)],
              "Both actual Codex windows must remain visible as independent values on the compact card")
        check(accounts.first?.visiblePools.map(\.timing) == ["6 天后重置", "3 小时后重置"],
              "Each Codex window needs its own provider-reported reset countdown")
        check(accounts.dropFirst().allSatisfy { $0.value == .unknown && $0.status == .notConnected },
              "Unconnected services must never inherit the preview's sample balances")
        let disabled = QuotaHomePresentation.accounts(snapshot: snapshot, error: nil, readsEnabled: false, now: now)
        check(disabled.first?.value == .unknown, "A no-opt-in preview must not present cached data as a live connection")
        let missing = QuotaHomePresentation.accounts(snapshot: nil, error: "offline", readsEnabled: true, now: now)
        check(missing.first?.value == .unknown, "A failed read without a snapshot must remain unknown, not 0 or 100 percent")
        var stale = snapshot
        stale.freshness = .stale
        check(QuotaHomePresentation.accounts(snapshot: stale, error: nil, readsEnabled: true, now: now).first?.status == .stale,
              "Persisted stale snapshots must be visibly stale")
        check(QuotaHomePresentation.accounts(snapshot: snapshot, error: nil, readsEnabled: true,
                                             now: now.addingTimeInterval(180)).first?.status == .stale,
              "A stalled source must age out instead of staying fresh forever")
        // Exercise the actual Home binding, not only the preference helper.
        guard AppEnvironment.isPreview else { exit(2) }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.finishLaunching()
        let defaults = AppEnvironment.defaults
        let vault = UnusedVault()
        let connections = QuotaConnectionsStore(defaults: defaults, vault: vault, allowsConnections: false,
            transport: { _ in throw QuotaConnectionError.preview })
        let status = CodexStatusStore()
        let host = NSHostingView(rootView: AnyView(QuotaHomeView(codexStatus: status, connections: connections,
            tools: [], onSelectTool: { _ in }, onClose: {})))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 520, height: 336),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = host
        window.orderBack(nil)
        func settle() { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        settle()
        for id in ["codex", "cursor", "grok", "doubao", "muse", "deepseek", "minimax-api", "minimax-audio"] {
            let grid = descendants(host).compactMap { $0 as? QuotaGridDocumentView }.first
            if let card = grid?.buttons.first(where: { $0.account.id == id }),
               let item = card.menu?.items.first(where: { $0.identifier?.rawValue == "quota-remove-account" }),
               let action = item.action {
                NSApp.sendAction(action, to: item.target, from: item)
                settle()
                let visible = descendants(host).compactMap { $0 as? QuotaGridDocumentView }.first?.accounts ?? []
                check(!visible.contains { $0.id == id }, "Actual Home removes \(id) after the card intent")
            } else { check(false, "Actual Home offers the removal action for \(id)") }
        }
        check(!descendants(host).contains { $0 is QuotaGridDocumentView }, "Removing the last card reaches the empty-state recovery")
        check(window.frame.size == NSSize(width: 520, height: 336), "Removal never expands the bounded panel")
        check(vault.calls == 0, "Removing Home cards must never touch saved credentials")
        let restored = QuotaCardVisibilityStore(defaults: defaults)
        restored.show("muse")
        host.rootView = AnyView(QuotaHomeView(codexStatus: status, connections: connections,
            tools: [], onSelectTool: { _ in }, onClose: {}).id("cold-restoration"))
        settle()
        check(descendants(host).compactMap { $0 as? QuotaGridDocumentView }.first?.accounts.map(\.id) == ["muse"],
              "A recreated actual Home restores the user's saved visible selection")
        window.orderOut(nil)
        guard failures.isEmpty else { exit(1) }
        print("PASS: existing-notch Home navigation, source-backed Codex values, pending services, opt-in and stale boundaries")
    }
    @MainActor final class UnusedVault: QuotaCredentialStoring {
        var calls = 0
        func read() throws -> String? { calls += 1; return nil }
        func save(_ value: String) throws { calls += 1 }
        func delete() throws { calls += 1 }
    }
}
