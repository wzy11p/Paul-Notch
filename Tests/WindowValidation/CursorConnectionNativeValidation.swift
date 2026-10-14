import AppKit
import SwiftUI
@testable import PaulNotchCore

@MainActor private final class SyntheticCursorVault: QuotaCredentialStoring {
    var key: String? = #"{"accessToken":"synthetic-access","refreshToken":"synthetic-refresh"}"#
    var deletions = 0
    func read() throws -> String? { key }
    func readForAuthorization() throws -> String? { key }
    func save(_ value: String) throws { key = value }
    func saveForRefresh(_ value: String) throws { key = value }
    func delete() throws { deletions += 1; key = nil }
}

/// Actual SwiftUI button wiring, with synthetic owned credentials and no network.
@main struct CursorConnectionNativeValidation {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await validate(); exit(0) }
            catch { print("FAIL: \(error)"); exit(1) }
        }
        NSApp.run()
    }
    @MainActor static func validate() async throws {
        let suite = "local.paul.test.cursor-connection.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "quota.cursor-account.enabled.v1")
        let vault = SyntheticCursorVault()
        let store = CursorQuotaAccountStore(defaults: defaults, vault: vault, allowsConnections: true,
            transport: { request in
                guard CursorQuotaRequest.permits(request) else { throw QuotaConnectionError.invalidData }
                return .init(status: 503, data: Data(), etag: nil, retryAfter: 120)
            })
        let launcher = CursorQuotaBrowserLauncher(allowsOpening: false)
        let host = NSHostingView(rootView: CursorQuotaConnectionView(store: store, launcher: launcher)
            .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.sizingOptions = []
        let window = NSWindow(contentRect: .init(x: 110, y: 120, width: 620, height: 660),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Paul · synthetic connection safety validation"
        window.contentView = host
        window.orderFrontRegardless()
        defer { store.stop(); window.orderOut(nil); window.close() }
        store.refreshDue()
        await settle()
        try require(store.enabled && vault.key != nil, "503 must retain the saved account")
        do {
            print("READY: synthetic Cursor/Grok only. Press Disconnect, Keep Connection, Disconnect, Confirm."); fflush(nil)
            try await waitFor("first click") { store.isDisconnectConfirmationPresented }
            try require(store.enabled && vault.deletions == 0, "first click deleted the synthetic login")
            print("PASS: first native click retained login"); fflush(nil)
            try await waitFor("cancel") { !store.isDisconnectConfirmationPresented }
            try require(store.enabled && vault.deletions == 0, "cancel did not retain login")
            print("PASS: native cancel retained login"); fflush(nil)
            try await waitFor("second request") { store.isDisconnectConfirmationPresented }
            try await waitFor("explicit confirm") { !store.enabled }
            try require(vault.deletions == 1 && vault.key == nil, "confirmed synthetic deletion not applied once")
            print("PASS: actual native saved-login outage, first-click safety, cancel preservation and explicit confirmation; no real credentials or network")
            return
        }
    }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure.assertion(message) }
    }
    @MainActor static func settle() async { try? await Task.sleep(for: .milliseconds(120)) }
    @MainActor static func waitFor(_ step: String, condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(150)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try require(condition(), "no native input observed for \(step)")
    }
    enum Failure: Error { case assertion(String) }
}
