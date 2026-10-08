import AppKit
import SwiftUI
@testable import PaulNotchCore

@MainActor private final class PreviewConnectionVault: QuotaCredentialStoring {
    private var value: String?
    func read() throws -> String? { value }
    func save(_ key: String) throws { value = key }
    func delete() throws { value = nil }
}

@main struct QuotaSelfServicePreview {
    @MainActor static func main() {
        _ = NSApplication.shared
        guard AppEnvironment.isPreview else { fatalError("Refusing a non-isolated preview") }
        NSApp.setActivationPolicy(.regular)
        let connections = QuotaConnectionsStore(defaults: AppEnvironment.defaults,
            vault: PreviewConnectionVault(), allowsConnections: true, transport: { request in
                // All credentials/data here are synthetic. No URLSession or real Keychain.
                let rejected = request.value(forHTTPHeaderField: "Authorization")?.contains("invalid") == true
                let body = Data(#"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"12.34","granted_balance":"0","topped_up_balance":"12.34"}]}"#.utf8)
                return QuotaHTTPResponse(status: rejected ? 401 : 200, data: body, etag: nil)
            }, miniMax: MiniMaxWalletStore(defaults: AppEnvironment.defaults,
                vault: PreviewConnectionVault(), allowsConnections: true, transport: { request in
                    let rejected = request.value(forHTTPHeaderField: "Authorization")?.contains("invalid") == true
                    let body = rejected
                        ? #"{"base_resp":{"status_code":1004,"status_msg":"synthetic error"}}"#
                        : #"{"available_amount":"17.31","cash_balance":"17.31","voucher_balance":"0.00","credit_balance":"0.00","owed_amount":"0.00","base_resp":{"status_code":0,"status_msg":"success"}}"#
                    return QuotaHTTPResponse(status: rejected ? 400 : 200, data: Data(body.utf8), etag: nil)
                }))
        let codex = CodexStatusStore()
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 460),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Paul Notch · 接入验证（不联网、不写钥匙串）"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: VStack(spacing: 0) {
            QuotaHomeView(codexStatus: codex, connections: connections, tools: [], onSelectTool: { _ in },
                          onClose: { NSApp.terminate(nil) })
            Text("隔离验证 · 仅输入测试字符串 · 余额为固定样例")
                .font(.system(size: 11)).foregroundStyle(.orange).frame(height: 22)
        }.background(Color.black).preferredColorScheme(.dark))
        let menu = NSMenu()
        let application = NSMenuItem()
        let submenu = NSMenu()
        submenu.addItem(withTitle: "退出接入验证", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        application.submenu = submenu
        menu.addItem(application)
        NSApp.mainMenu = menu
        NSApp.finishLaunching()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.run()
    }
}
