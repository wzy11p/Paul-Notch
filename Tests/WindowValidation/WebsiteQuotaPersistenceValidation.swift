import AppKit
import WebKit
@testable import PaulNotchCore

@MainActor private final class RestorableWebsiteFixture: WebsiteQuotaSession {
    var reads = 0
    var stops = 0
    var amount = 82
    var failure: QuotaConnectionError?
    func read(reloading: Bool) async throws -> WebsiteQuotaSnapshot {
        reads += 1
        if let failure { throw failure }
        return .init(value: .percent(amount), timing: "fixture reset", details: [], observedAt: .now)
    }
    func stop() { stops += 1 }
}
@MainActor private final class RestorableWebsiteFactory {
    var ids: [UUID] = []
    var sessions: [RestorableWebsiteFixture] = []
    var deleted: [UUID] = []
    func make(_ provider: WebsiteQuotaProvider, _ id: UUID) -> any WebsiteQuotaSession {
        ids.append(id)
        let session = RestorableWebsiteFixture(); sessions.append(session); return session
    }
    func delete(_ id: UUID) async -> Bool { deleted.append(id); return true }
}

@main struct WebsiteQuotaPersistenceValidation {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited); NSApp.finishLaunching()
        if [3,4].contains(CommandLine.arguments.count) {
            let provider = CommandLine.arguments.count == 4 ? WebsiteQuotaProvider(rawValue: CommandLine.arguments[3]) : .doubao
            guard let provider, let id = UUID(uuidString: CommandLine.arguments[2]) else { exit(64) }
            try await webKitRoundtrip(mode: CommandLine.arguments[1], id: id, provider: provider)
            return
        }
        let suite = "local.paul.persistence-fixture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let factory = RestorableWebsiteFactory()
        func make(_ provider: WebsiteQuotaProvider = .doubao, allowed: Bool = true) -> WebsiteQuotaStore {
            .init(provider: provider, allowsConnections: allowed,
                  factory: { _ in RestorableWebsiteFixture() }, defaults: defaults,
                  persistentFactory: factory.make, removeProfile: factory.delete)
        }
        let first = make()
        first.beginLogin(); first.finishLogin()
        await settle(first)
        guard first.enabled else { print("FAIL: test never established the connection"); exit(2) }
        let firstID = factory.ids[0]
        first.stop() // Normal app quit, NOT the owner's Disconnect action.
        let reopened = make()
        try check(reopened.enabled && reopened.snapshot == nil && factory.ids.count == 1,
                  "Saved opt-in survives shutdown, but no browser or yesterday's value is published during construction")
        reopened.refreshDue()
        await settle(reopened)
        try check(reopened.enabled && reopened.snapshot?.value == .percent(82) && !reopened.isPresentingLogin && factory.ids.last == firstID,
                  "Verified website login restores its same profile and queries without opening setup")
        reopened.beginLogin()
        let failedID = factory.ids.last!
        factory.sessions.last!.failure = .unavailable
        reopened.finishLogin(); await settle(reopened)
        try check(reopened.snapshot?.value == .percent(82), "Failed candidate keeps the old account")
        reopened.stop()
        let afterCrash = make()
        afterCrash.refreshDue(); await settle(afterCrash)
        try check(factory.ids.last == firstID && factory.deleted.contains(failedID) && !factory.deleted.contains(firstID),
                  "Restart cleans only a journaled unfinished profile, never the confirmed account")
        factory.sessions.last!.failure = .unavailable
        afterCrash.refreshDue(force: true); await settle(afterCrash)
        afterCrash.stop()
        let afterOffline = make()
        afterOffline.refreshDue(); await settle(afterOffline)
        try check(afterOffline.snapshot?.value == .percent(82) && factory.ids.last == firstID,
                  "Network failure does not erase the saved connection")
        afterOffline.beginLogin(); factory.sessions.last!.amount = 41
        let replacementID = factory.ids.last!
        afterOffline.finishLogin(); await settle(afterOffline)
        try await Task.sleep(for: .milliseconds(30))
        try check(afterOffline.snapshot?.value == .percent(41) && factory.deleted.contains(firstID),
                  "Only a verified replacement commits the new profile and retires the previous one")
        factory.sessions.last!.failure = .authentication
        afterOffline.refreshDue(force: true); await settle(afterOffline)
        try check(afterOffline.needsLogin && afterOffline.enabled && !afterOffline.isPresentingLogin,
                  "A genuinely expired login asks for deliberate reauthentication, not a background popup")
        let beforePreview = factory.ids.count
        let preview = make(allowed: false)
        preview.beginLogin(); preview.refreshDue(force: true); preview.disconnect()
        try check(factory.ids.count == beforePreview && make().enabled,
                  "Isolated preview cannot restore or forget an established owned login")
        afterOffline.disconnect()
        try await Task.sleep(for: .milliseconds(30))
        let afterDisconnect = make()
        afterDisconnect.refreshDue()
        try check(!afterDisconnect.enabled && afterDisconnect.snapshot == nil && factory.deleted.contains(replacementID),
                  "Only explicit Disconnect forgets the connection across restart and clears its own profile")
        let audio = make(.miniMaxCN)
        audio.beginLogin(provider: .miniMaxGlobal); audio.finishLogin(); await settle(audio); audio.stop()
        let restoredAudio = make(.miniMaxCN)
        try check(restoredAudio.enabled && restoredAudio.provider == .miniMaxGlobal,
                  "Restore remembers Audio's chosen region instead of silently connecting the other account site")
        defaults.set(Data("{\"schemaVersion\":99,\"discarded\":[]}".utf8), forKey: "quota.website.doubao.login.v1")
        let corrupt = make()
        try check(!corrupt.enabled && corrupt.error != nil, "Unknown/corrupt schema fails closed without opening a website")
        restoredAudio.disconnect()
        print("PASS: restart restore, real-query-only freshness, offline retention, candidate rollback, region, expiry, disconnect, cleanup and preview boundaries")
    }
    @MainActor static func settle(_ store: WebsiteQuotaStore) async {
        for _ in 0..<200 where store.isRefreshing { try? await Task.sleep(for: .milliseconds(10)) }
    }
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { print("FAIL: \(message)"); fflush(nil); throw QuotaConnectionError.invalidData }
    }
    @MainActor static func webKitRoundtrip(mode: String, id: UUID, provider: WebsiteQuotaProvider) async throws {
        guard #available(macOS 14, *) else { print("SKIP: independent persistent profiles require macOS 14+"); return }
        if mode == "delete" {
            try check(await WebsiteQuotaBrowser.removeOwnedProfile(id), "Delete only the synthetic test profile")
            return
        }
        let browser = WebsiteQuotaBrowser(provider: provider, allowsConnections: true, loadImmediately: false, profileIdentifier: id)
        let store = browser.webView.configuration.websiteDataStore
        try check(store.isPersistent && store.identifier == id, "Production browser must use its supplied persistent profile")
        browser.webView.loadSimulatedRequest(URLRequest(url: provider.quotaURL),
                                             responseHTML: "<html><body>Anonymous persistence fixture; no account or network.</body></html>")
        for _ in 0..<200 where browser.webView.isLoading || browser.webView.url == nil { try await Task.sleep(for: .milliseconds(10)) }
        if mode == "write" {
            _ = try await browser.webView.evaluateJavaScript("localStorage.setItem('paulSyntheticLogin','retained-fixture'); null;")
            let cookie = HTTPCookie(properties: [.name: "paulSyntheticLogin", .value: "fixture-only", .domain: provider.host,
                .path: "/", .secure: "TRUE", .expires: Date().addingTimeInterval(3600)])!
            await store.httpCookieStore.setCookie(cookie)
            let written = try await browser.webView.evaluateJavaScript("localStorage.getItem('paulSyntheticLogin')") as? String
            try check(written == "retained-fixture", "The synthetic writer must establish its own local-storage fixture")
            var registered = false
            for _ in 0..<30 {
                let records = await store.dataRecords(ofTypes: [WKWebsiteDataTypeLocalStorage])
                // displayName may group www.* into its registrable domain; it
                // is presentation metadata, not the document's exact origin.
                registered = records.count == 1 && records[0].dataTypes.contains(WKWebsiteDataTypeLocalStorage)
                if registered { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            try check(registered, "WebKit must register the synthetic profile's local-storage origin before the writer exits")
            // Metadata is not a disk-flush contract. WebKit batches SQLite
            // storage commits (currently 500ms); the former 300ms process
            // lifetime raced that batch. Keep the synthetic writer alive for
            // a full commit interval; a separate process still proves recovery.
            try await Task.sleep(for: .seconds(1))
        } else {
            let local = try await browser.webView.evaluateJavaScript("localStorage.getItem('paulSyntheticLogin')") as? String
            let cookies = await store.httpCookieStore.allCookies()
            if local != "retained-fixture" || !cookies.contains(where: { $0.name == "paulSyntheticLogin" && $0.value == "fixture-only" }) {
                let ready = try await browser.webView.evaluateJavaScript("JSON.stringify({ready:document.readyState,origin:location.origin})") as? String
                print("Synthetic persistence diagnosis: local=\(local == "retained-fixture"), cookie=\(cookies.contains { $0.name == "paulSyntheticLogin" && $0.value == "fixture-only" }), document=\(ready ?? "none")")
                fflush(nil)
            }
            try check(local == "retained-fixture" && cookies.contains { $0.name == "paulSyntheticLogin" && $0.value == "fixture-only" },
                      "A separate process must recover both WebKit login storage and persistent cookies")
            let other = WebsiteQuotaBrowser(provider: provider, allowsConnections: true, loadImmediately: false, profileIdentifier: UUID())
            try check(await other.webView.configuration.websiteDataStore.httpCookieStore.allCookies().isEmpty,
                      "A new candidate must not reuse another account's login")
            other.stop()
            _ = await WebsiteQuotaBrowser.removeOwnedProfile(other.webView.configuration.websiteDataStore.identifier!)
            let isolated = WebsiteQuotaBrowser(provider: provider, allowsConnections: false, loadImmediately: false, profileIdentifier: id)
            try check(!isolated.webView.configuration.websiteDataStore.isPersistent, "Disallowed browser cannot open an owned persistent profile")
            isolated.stop()
        }
        browser.stop()
        print("PASS: actual \(provider.name) WebKit cross-process profile \(mode); only synthetic state used")
    }
}
