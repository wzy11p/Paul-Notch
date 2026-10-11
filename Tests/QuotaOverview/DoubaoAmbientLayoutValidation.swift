import AppKit
import SwiftUI
import Vision
@testable import PaulNotchCore

@MainActor private struct UnusedGlanceVault: QuotaCredentialStoring {
    func read() throws -> String? { throw QuotaConnectionError.preview }
    func save(_ value: String) throws { throw QuotaConnectionError.preview }
    func delete() throws { throw QuotaConnectionError.preview }
}

@MainActor private final class DoubaoGlanceFixture: WebsiteQuotaSession {
    var used = 2, weeklyUsed = 47
    func read(reloading: Bool) throws -> WebsiteQuotaSnapshot {
        try WebsiteQuotaParser.doubao(rows: [
            .init(name: "当前时段", usage: "已用 \(used)%", timing: "2 小时后重置"),
            .init(name: "近 7 天", usage: "已用 \(weeklyUsed)%", timing: "10月15日 02:02 重置")], at: .now)
    }
    func stop() {}
}

@main struct DoubaoAmbientLayoutValidation {
    struct Failure: Error { let message: String }
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        guard AppEnvironment.isPreview, !AppEnvironment.codexStatusReadsEnabled else {
            throw Failure(message: "Disposable no-account environment required")
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let values: [QuotaOverviewValue] = [.percent(0), .percent(9), .percent(98), .percent(100),
            .percentBound(lowerExclusive: 99, upperInclusive: 100), .unlimited, .unknown]
        var layouts = 0
        for full in [false, true] {
            for value in values {
                for reset in ["2H", "6D", "366D", "<1M", "待用", "待刷新", "—", "12月31日 02:02 重置"] {
                    let lines = DoubaoQuotaWindow.allCases.map { window in
                        AmbientQuotaLine(id: window.rawValue, period: reset.contains("月") ? "—" : reset,
                                         value: value, poolLabel: window.marker, resetDescription: reset)
                    }
                    let quota = ImageRenderer(content: DoubaoAmbientQuotaView(lines: lines, placement: .notchValues,
                        isFullScreen: full).fixedSize())
                    let timing = ImageRenderer(content: DoubaoAmbientQuotaView(lines: lines, placement: .notchResets,
                        isFullScreen: full).fixedSize())
                    guard let quotaSize = quota.nsImage?.size, let timingSize = timing.nsImage?.size else {
                        throw Failure(message: "Cannot render real compact views")
                    }
                    try require(quotaSize.width <= (full ? 38 : 43) && quotaSize.height <= (full ? 24 : 32),
                                "Doubao labels/values overflow existing notch wing: \(quotaSize)")
                    try require(timingSize.width + (full ? 12 : 14) <= (full ? 38 : 43) &&
                                timingSize.height <= (full ? 24 : 32),
                                "Provider mark and per-pool resets overflow existing notch wing: \(timingSize), \(reset), fullscreen \(full)")
                    layouts += 1
                }
            }
        }
        let session = DoubaoGlanceFixture()
        let store = WebsiteQuotaStore(provider: .doubao, allowsConnections: true, factory: { _ in session })
        let connections = QuotaConnectionsStore(defaults: AppEnvironment.defaults, vault: UnusedGlanceVault(),
                                                allowsConnections: true, transport: { _ in throw QuotaConnectionError.preview },
                                                websiteMemberships: ["doubao": store])
        defer { connections.stop() }
        store.beginLogin(); store.finishLogin()
        for _ in 0..<100 where store.isRefreshing { try? await Task.sleep(for: .milliseconds(10)) }
        let presentation = AmbientNotchPresentation()
        presentation.observeForeground(bundleIdentifier: "com.work.pc.doubao")
        let ambient = AmbientNotchView(codexStatus: CodexStatusStore(), connections: connections,
                                      presentation: presentation, onOpen: {})
        try require(ambient.quotaPresentation(at: .now).lines.map(\.value) == [.percent(98), .percent(53)],
                    "Render must consume both source responses through the actual ambient adapter")
        let host = NSHostingView(rootView: ambient)
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 192, height: 32),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.isOpaque = false
        window.backgroundColor = .clear; window.hasShadow = false; window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        try render(host, to: output.appendingPathComponent("doubao-notch-normal.png"))
        presentation.isFrontmostAppFullScreen = true
        window.setContentSize(NSSize(width: 180, height: 24))
        try render(host, to: output.appendingPathComponent("doubao-notch-fullscreen.png"))
        presentation.isFloating = true
        window.setContentSize(NSSize(width: 92, height: 92))
        try render(host, to: output.appendingPathComponent("doubao-orb.png"))
        let pair = ambient.quotaPresentation(at: .now).lines
        try require(pair.count == 2, "Extreme-value renders require the actual two source slots")
        store.stop()
        let sheet = HStack(alignment: .top, spacing: 20) {
            ForEach(Array(values.enumerated()), id: \.offset) { item in
                let lines = pair.map { AmbientQuotaLine(id: $0.id, period: item.offset == 6 ? "待刷新" : $0.period,
                                                       value: item.element, poolLabel: $0.poolLabel,
                                                       resetDescription: $0.resetDescription) }
                VStack(spacing: 6) {
                    Text("合成数据 \(item.offset + 1)").font(.system(size: 9))
                    DoubaoAmbientQuotaView(lines: lines, placement: .orb)
                        .frame(width: 78, height: 78).background(Color(white: 0.12), in: Circle()).clipShape(Circle())
                }
            }
        }.padding(16).foregroundStyle(.white).background(Color.black)
        let renderer = ImageRenderer(content: sheet); renderer.scale = 3
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.representation(using: .png, properties: [:]) else {
            throw Failure(message: "Cannot render extreme-value matrix")
        }
        try data.write(to: output.appendingPathComponent("doubao-orb-extremes.png"))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        do { try VNImageRequestHandler(data: data).perform([request]) }
        catch {
            FileHandle.standardError.write(Data("OCR execution failed after \(layouts) layout checks and native renders: \(error)\n".utf8))
            throw error
        }
        let visibleText = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        try require(visibleText.contains("100%") && visibleText.contains("99%") && visibleText.contains("10/15"),
                    "Native pixels truncate a complete amount or date: \(visibleText)")
        print("PASS: \(layouts) dual-quota layouts fit existing normal/fullscreen wings, real ambient orb/notch renders and seven extreme-value states")
    }
    @MainActor static func render(_ host: NSView, to url: URL) throws {
        // Drive this owned test hierarchy, never synthesize events in another app.
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw Failure(message: "No bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw Failure(message: "No PNG") }
        try data.write(to: url)
    }
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }
}
