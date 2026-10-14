import AppKit
import SwiftUI
@testable import PaulNotchCore

/// Test fixtures only. This file is outside the product target and never
/// opens real accounts, owns a timer, or starts any integration/store.
enum QuotaGlanceFixtures {
    static let now = Date(timeIntervalSince1970: 1_791_000_000)
    static let cursor = QuotaOverviewAccount(id: "cursor", name: "Cursor", account: "Anysphere",
        group: .membership, value: .percent(77), timing: "18 天后重置", status: .sample,
        pools: [.init(label: "Cursor", value: .percent(77), timing: "18 天后重置"),
                .init(label: "其他模型", value: .percent(33), timing: "18 天后重置")])
    static let grok = QuotaOverviewAccount(id: "grok", name: "Grok Bot", account: "Cursor 计费",
        group: .membership, value: .percent(68), timing: "2 天后重置", status: .sample)
    static let doubao = QuotaOverviewAccount(id: "doubao", name: "豆包工作", account: "ByteDance",
        group: .membership, value: .percent(100), timing: "开始使用后计时", status: .sample,
        pools: [.init(label: "当前时段", value: .percent(100), timing: "开始使用后计时"),
                .init(label: "近 7 天", value: .percent(2), timing: "10月15日 02:02 重置")])
    static let codex = QuotaOverviewAccount(id: "codex", name: "Codex", account: "OpenAI",
        group: .membership, value: .percent(32), timing: "6 天后重置", status: .sample,
        pools: [.init(label: "每周", value: .percent(32), timing: "6 天后重置")])
    static let wallet = QuotaOverviewAccount(id: "deepseek", name: "DeepSeek API", account: "API · 钱包",
        group: .usage, value: .money(Decimal(string: "21.61")!, currency: "CNY"), timing: "按量扣费", status: .sample)

    static func state(_ service: AmbientQuotaService, model: String = "Auto") -> AmbientQuotaPresentation {
        let lines: [AmbientQuotaLine]
        switch service {
        case .cursor:
            lines = [.init(id: "Cursor Models", period: "18D", value: .percent(77), poolLabel: "Cursor"),
                     .init(id: "Other Models", period: "18D", value: .percent(33), poolLabel: "其他")]
        case .doubao:
            lines = [.init(id: "doubao.short", period: "待用", value: .percent(100), poolLabel: "时段"),
                     .init(id: "doubao.weekly", period: "—", value: .percent(2), poolLabel: "总额", resetDescription: "10月15日 02:02 重置")]
        case .grok: lines = [.init(id: "grok", period: "2D", value: .percent(68), poolLabel: "剩余")]
        case .codex: lines = [.init(id: "week", period: "6D", value: .percent(32), poolLabel: "总额")]
        case .muse: lines = []
        }
        return .init(service: service, lines: lines, activity: .notAvailable, summary: "布局测试 · 示例数据",
                     cursorModel: service == .cursor ? CursorModelSelection.parse(model) : nil)
    }
}

struct QuotaGlancePreviewOrb: View {
    let state: AmbientQuotaPresentation
    var showsReading = true
    var body: some View {
        ZStack {
            QuotaOrbReadingBackdrop()
            QuotaLiquidOrb(value: state.liquidValue, reduceMotion: true)
            if showsReading {
                QuotaOrbReadout(service: state.service, lines: state.lines, highlightedID: state.cursorModel?.pool?.rawValue,
                               modelLabel: state.cursorModel?.pool == nil ? nil : state.cursorModel?.shortLabel)
            }
        }.frame(width: QuotaFloatingPlacement.orbDiameter, height: QuotaFloatingPlacement.orbDiameter).clipShape(Circle())
    }
}

struct QuotaGlancePreviewSheet: View {
    @State private var model = "Auto"
    private let services: [AmbientQuotaService] = [.codex, .grok, .cursor, .doubao, .muse]
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("A · 数字优先 · 78pt").font(.system(size: 17, weight: .semibold))
                Spacer()
                Picker("Cursor 模型", selection: $model) {
                    Text("Auto").tag("Auto")
                    Text("Grok").tag("Grok 4.7")
                    Text("Sonnet").tag("Claude Sonnet 5.5 High")
                }.labelsHidden().pickerStyle(.segmented).frame(width: 190)
            }
            Text("全部为布局测试数据 · 不读取账号、不修改正式版。切换模型只改变强调与水位，双额度不消失。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 20) {
                ForEach(services, id: \.rawValue) { service in
                    QuotaGlancePreviewOrb(state: QuotaGlanceFixtures.state(service, model: model))
                }
            }.padding(18).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 16))
            HStack(spacing: 20) {
                ForEach(services, id: \.rawValue) { service in
                    QuotaGlancePreviewOrb(state: QuotaGlanceFixtures.state(service, model: model))
                }
            }.padding(18).background(Color(white: 0.10)).clipShape(RoundedRectangle(cornerRadius: 16))
            HStack(spacing: 12) {
                ForEach([QuotaGlanceFixtures.codex, QuotaGlanceFixtures.grok, QuotaGlanceFixtures.cursor,
                         QuotaGlanceFixtures.doubao, QuotaGlanceFixtures.wallet]) { account in
                    QuotaOverviewAccountCard(account: account, isPinned: false, onOpen: {})
                        .frame(width: 110, height: 110)
                }
            }
            HStack(spacing: 30) {
                ForEach([AmbientQuotaService.cursor, .doubao], id: \.rawValue) { service in
                    let state = QuotaGlanceFixtures.state(service, model: model)
                    HStack(spacing: 0) {
                        QuotaGlanceRows(lines: state.lines, placement: .notchValues,
                                       highlightedID: state.cursorModel?.pool?.rawValue).frame(width: 43)
                        Color.clear.frame(width: 60)
                        AmbientProviderMark(service: service, size: 10, attentive: false, pressed: false,
                            quiet: true, working: false, pointer: .zero).frame(width: 10)
                        QuotaGlanceRows(lines: state.lines, placement: .notchResets).padding(.leading, 1)
                    }.padding(.horizontal, 5).frame(height: 32).background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }.padding(22).background(Color(white: 0.17)).preferredColorScheme(.dark)
    }
}

#if QUOTA_GLANCE_PREVIEW
@MainActor private final class QuotaGlancePreviewDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    private var refraction: AnyObject?
    func applicationDidFinishLaunching(_ notification: Notification) {
        if #available(macOS 26.0, *), !CommandLine.arguments.contains("--layout-sheet"),
           ProcessInfo.processInfo.environment["PAUL_NATIVE_REFRACTION_PREVIEW"] != "0" {
            let preview = NativeGlassRefractionPreview()
            refraction = preview; window = preview.window
            preview.show()
            return
        }
        let host = NSHostingView(rootView: QuotaGlancePreviewSheet())
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 575),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Paul Notch · 统一额度预览（示例数据）"
        window.isReleasedWhenClosed = false; window.contentView = host; window.center()
        window.makeKeyAndOrderFront(nil); self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
@main struct QuotaGlancePreview {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--check-water-performance") {
            QuotaWaterPerformanceValidation.main()
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = QuotaGlancePreviewDelegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
#endif
