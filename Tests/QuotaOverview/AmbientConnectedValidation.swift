import AppKit
import SwiftUI
@testable import PaulNotchCore

@MainActor private final class AmbientFixtureClock { var now = Date(timeIntervalSince1970: 1_791_000_000) }
@MainActor private final class AmbientFixtureVault: QuotaCredentialStoring {
    var reads = 0
    var authorizations = 0
    func read() throws -> String? {
        reads += 1
        return try CursorQuotaTokenPair(accessToken: "synthetic-access-only", refreshToken: "synthetic-refresh-only").serialized
    }
    func readForAuthorization() throws -> String? { authorizations += 1; return try read() }
    func save(_ value: String) throws { throw QuotaConnectionError.preview }
    func delete() throws { throw QuotaConnectionError.preview }
}
private actor AmbientFixtureTransport {
    let now: Date
    var calls = 0
    var cursorUsed = 19
    var grokUsed = 36
    var rejectsGrok = false
    init(now: Date) { self.now = now }
    func update() { cursorUsed = 42; grokUsed = 77 }
    func rejectGrok() { rejectsGrok = true }
    func fetch(_ request: URLRequest) throws -> QuotaHTTPResponse {
        calls += 1
        let payload: String, status: Int
        switch request.url?.path {
        case CursorQuotaRequest.monthlyPath:
            let end = Int(now.addingTimeInterval(28 * 86400).timeIntervalSince1970 * 1000)
            payload = "{\"enabled\":true,\"billingCycleEnd\":\"\(end)\",\"planUsage\":{\"autoPercentUsed\":\(cursorUsed),\"apiPercentUsed\":50}}"
            status = 200
        case CursorQuotaRequest.weeklyPath:
            let end = ISO8601DateFormatter().string(from: now.addingTimeInterval(3 * 86400))
            payload = "{\"usagePercent\":\(grokUsed),\"nextResetTimestampUtc\":\"\(end)\",\"hasNonZeroIncludedLimit\":true}"
            status = rejectsGrok ? 500 : 200
        default: throw QuotaConnectionError.preview
        }
        return .init(status: status, data: Data(payload.utf8), etag: nil)
    }
}
@MainActor private final class AmbientFixtureWebsite: WebsiteQuotaSession {
    let clock: AmbientFixtureClock
    var reads = 0
    var used = 13
    init(clock: AmbientFixtureClock) { self.clock = clock }
    func read(reloading: Bool) throws -> WebsiteQuotaSnapshot {
        reads += 1
        return try WebsiteQuotaParser.doubao(rows: [
            .init(name: "当前时段", usage: "已用 \(used)%", timing: "2 小时后重置"),
            .init(name: "近 7 天", usage: "未消耗", timing: "开始使用后计时")], at: clock.now)
    }
    func stop() {}
}

@main struct AmbientConnectedValidation {
    struct Failure: Error { let message: String }
    @MainActor static func main() async throws {
        func check(_ value: Bool, _ message: String) throws {
            if !value { print("FAIL: \(message)"); throw Failure(message: message) }
        }
        guard AppEnvironment.isPreview, !AppEnvironment.codexStatusReadsEnabled else {
            throw Failure(message: "A disposable no-account process is required")
        }
        let suite = "local.paul.test.ambient-connected.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = AmbientFixtureClock(), vault = AmbientFixtureVault()
        let transport = AmbientFixtureTransport(now: clock.now)
        defaults.set(true, forKey: "quota.cursor-account.enabled.v1")
        let cursor = CursorQuotaAccountStore(defaults: defaults, vault: vault, allowsConnections: true,
            transport: { try await transport.fetch($0) }, clock: { clock.now })
        let website = AmbientFixtureWebsite(clock: clock)
        let doubao = WebsiteQuotaStore(provider: .doubao, allowsConnections: true,
            factory: { _ in website }, clock: { clock.now })
        let connections = QuotaConnectionsStore(defaults: defaults, vault: vault, allowsConnections: true,
            transport: { _ in throw QuotaConnectionError.preview }, cursorAccount: cursor, websiteMemberships: ["doubao": doubao])
        defer { connections.stop() }
        let presentation = AmbientNotchPresentation()
        let view = AmbientNotchView(codexStatus: CodexStatusStore(), connections: connections,
            presentation: presentation, onOpen: {})
        presentation.observeForeground(bundleIdentifier: "com.todesktop.230313mzl4w4u92")
        try check(view.quotaPresentation(at: clock.now).lines.isEmpty && vault.reads == 0 && website.reads == 0,
                  "Showing a provider cannot authorize/read/start a connection")
        cursor.refreshDue(); doubao.beginLogin(); doubao.finishLogin()
        await settle(cursor, doubao)
        for (bundle, expected, period) in [
            ("com.todesktop.230313mzl4w4u92", 81, "28D"),
            ("com.anysphere.sand", 64, "3D"), ("com.work.pc.doubao", 87, "2H")
        ] {
            presentation.observeForeground(bundleIdentifier: bundle)
            let selected = view.quotaPresentation(at: clock.now)
            let home = QuotaHomePresentation.accounts(snapshot: nil, error: nil, readsEnabled: false,
                now: clock.now, connections: connections).first { $0.id == selected.service.rawValue }
            try check(selected.lines.first?.value == .percent(expected) && selected.lines.first?.value == home?.value &&
                      selected.lines.first?.period == period && selected.activity == .notAvailable,
                      "The shelf and Home must share verified independent sources, not frozen fixtures or Codex tasks")
        }
        let calls = await transport.calls, websiteReads = website.reads, keyReads = vault.reads
        for _ in 0..<30 {
            presentation.observeForeground(bundleIdentifier: "com.anysphere.sand")
            _ = view.quotaPresentation(at: clock.now)
            presentation.observeForeground(bundleIdentifier: "com.work.pc.doubao")
            _ = view.quotaPresentation(at: clock.now)
        }
        let afterCalls = await transport.calls
        try check(afterCalls == calls && website.reads == websiteReads && vault.reads == keyReads && vault.authorizations == 0,
                  "Rapid foreground changes cannot create quota/login/password request storms")
        await transport.update(); website.used = 35; clock.now = clock.now.addingTimeInterval(31)
        cursor.refreshDue(); doubao.refreshDue(); await settle(cursor, doubao)
        for (bundle, remaining) in [("com.todesktop.230313mzl4w4u92", 58), ("com.anysphere.sand", 23), ("com.work.pc.doubao", 65)] {
            presentation.observeForeground(bundleIdentifier: bundle)
            try check(view.quotaPresentation(at: clock.now).lines.first?.value == .percent(remaining),
                      "The shelf follows changed canonical responses without any reconnect or focused-page read")
        }
        await transport.rejectGrok(); cursor.refreshDue(force: true); await settle(cursor, doubao)
        presentation.observeForeground(bundleIdentifier: "com.anysphere.sand")
        try check(view.quotaPresentation(at: clock.now).lines.isEmpty, "Failed Grok read cannot show old data or borrow Cursor")
        presentation.observeForeground(bundleIdentifier: "com.todesktop.230313mzl4w4u92")
        try check(view.quotaPresentation(at: clock.now).lines.first?.value == .percent(58), "One provider failure cannot erase a healthy provider")
        try check(view.quotaPresentation(at: clock.now.addingTimeInterval(91)).lines.isEmpty, "A stopped source must age out")
        try render(to: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
        print("PASS: canonical shelf/Home source equality, independent live-response changes, no focus-triggered requests, per-provider failures and ageing; synthetic isolated boundaries only")
    }
    @MainActor static func settle(_ cursor: CursorQuotaAccountStore, _ website: WebsiteQuotaStore) async {
        for _ in 0..<100 where cursor.isRefreshing || website.isRefreshing { try? await Task.sleep(for: .milliseconds(10)) }
    }
    @MainActor static func render(to output: URL) throws {
        let sheet = VStack(alignment: .leading, spacing: 10) {
            Text("SYNTHETIC LAYOUT CHECK • existing notch sizes").font(.system(size: 11))
            HStack(alignment: .top, spacing: 30) {
                ForEach([false, true], id: \.self) { full in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(full ? "Full screen / quiet" : "Normal").font(.system(size: 11))
                        ForEach(AmbientQuotaService.allCases, id: \.rawValue) { service in
                            HStack(spacing: 5) {
                                Text(service.name).font(.system(size: 11)).frame(width: 64, alignment: .leading)
                                AmbientQuotaLabel(period: service == .cursor ? "28D" : "2D", remaining: 100,
                                    isFullScreen: full, color: .green, secondaryColor: .gray).frame(width: 45)
                                AmbientProviderMark(service: service, size: full ? 10 : 13, attentive: false, pressed: false,
                                    quiet: true, working: false, pointer: .zero).frame(width: 16)
                                Text(service == .codex ? "9+" : "").font(.system(size: full ? 10 : 11))
                            }.frame(height: full ? 24 : 32)
                        }
                        AmbientQuotaLabel(period: "366D", remaining: 99, isFullScreen: full,
                            color: .green, secondaryColor: .gray, comparison: ">").frame(width: 45)
                    }
                }
            }
        }.padding(16).foregroundStyle(.white).background(.black)
        let renderer = ImageRenderer(content: sheet); renderer.scale = 3
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure(message: "Native layout render failed") }
        try png.write(to: output.appendingPathComponent("foreground-layout.png"))
        print(output.appendingPathComponent("foreground-layout.png").path)
    }
}
