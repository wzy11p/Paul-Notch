import AppKit
import SwiftUI
import WebKit
@testable import PaulNotchCore

@MainActor private struct NoCredentials: QuotaCredentialStoring {
    func read() throws -> String? { nil }
    func save(_ value: String) throws { throw QuotaConnectionError.preview }
    func delete() throws {}
}

@main struct QuotaWebsiteLayoutValidation {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.finishLaunching()
        let suite = "test.paul.website-layout.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        // Deliberately disabled browser: no official network, credential or owner content.
        let store = WebsiteQuotaStore(provider: .muse, allowsConnections: true,
            factory: { WebsiteQuotaBrowser(provider: $0, allowsConnections: false) })
        let connections = QuotaConnectionsStore(defaults: defaults, vault: NoCredentials(), allowsConnections: false,
            transport: { _ in throw QuotaConnectionError.preview }, websiteMemberships: ["muse": store])
        store.beginLogin()
        let browser = store.candidateBrowser!
        let accounts = QuotaHomePresentation.accounts(snapshot: nil, error: nil, readsEnabled: false, now: .now)
        let view = QuotaServiceConnectionsView(connections: connections, accounts: accounts,
            selectedProvider: .constant("muse"), codexReadsEnabled: false, isCodexRefreshing: false,
            onCheckCodex: {}, onClose: {})
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 760, height: 620),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host; window.alphaValue = 0; window.orderBack(nil)
        defer { store.stop(); window.orderOut(nil) }
        host.layoutSubtreeIfNeeded(); settle()
        try require(browser.displayedWebView.frame.height >= 350,
                    "login uses the available height instead of a fixed 250pt box")
        var ancestor = browser.displayedWebView.superview
        while let parent = ancestor {
            try require(!(parent is NSScrollView), "the website is not inside a competing form scroll view")
            ancestor = parent.superview
        }
        let before = browser.displayedWebView.frame.size
        window.setContentSize(NSSize(width: 900, height: 740))
        host.layoutSubtreeIfNeeded(); settle()
        try require(browser.displayedWebView.frame.width > before.width + 100 &&
                    browser.displayedWebView.frame.height > before.height + 90,
                    "resizing grows the official page in both dimensions")
        try require(store.candidateBrowser === browser && store.isPresentingLogin,
                    "resizing never replaces the login browser or cancels authentication")
        window.setContentSize(NSSize(width: 600, height: 438))
        host.layoutSubtreeIfNeeded(); settle()
        try require(browser.displayedWebView.frame.height >= 140,
                    "the minimum panel keeps a usable website viewport")
        print("PASS: flexible official-page viewport, one scroll owner and retained login through resize")
    }
    @MainActor static func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
    static func require(_ value: @autoclosure () -> Bool, _ label: String) throws {
        if !value() { throw Failure(label: label) }
    }
    struct Failure: Error { let label: String }
}
