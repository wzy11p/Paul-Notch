import AppKit
import SwiftUI
@testable import PaulNotchCore

/// Account-free raster checks of the real card, including its injected native
/// hover/press/drag state. Never read a provider or the personal workspace.
@main struct QuotaCardPaletteValidation {
    struct Failure: Error { let message: String }
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.finishLaunching()
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        var failures: [String] = []
        func check(_ value: Bool, _ message: String) {
            if !value { failures.append(message); print("FAIL: \(message)") }
        }
        let kinds: [QuotaOverviewKind] = [.membership, .api, .audio]
        let states: [(String, QuotaCardInteraction)] = [
            ("idle", .init()), ("hover", .init(hovered: true)),
            ("press", .init(pressed: true)), ("drag", .init(lifted: true))
        ]
        var idleLuma: CGFloat = 0
        for (stateName, state) in states {
            var reference: NSColor?
            for kind in kinds {
                let content = QuotaOverviewAccountCard(account: account(kind), isPinned: false,
                    onOpen: {}, interaction: state)
                    .frame(width: 110, height: 110).padding(8).background(Color.black)
                    .preferredColorScheme(.dark)
                let image = try render(content)
                try save(image, output.appendingPathComponent("\(kind.rawValue)-\(stateName).png"))
                // Empty top and bottom padding, away from glyphs and the rim.
                let upper = pixel(image, 63, 11), lower = pixel(image, 63, 112)
                let brightness = luminance(lower)
                print("\(kind.rawValue)/\(stateName) surface=\(lower) upper=\(upper)")
                check(spread(lower) < 0.045, "\(kind.rawValue)/\(stateName): no blue/purple category slab")
                check(lower.redComponent > 0.07 && lower.redComponent < 0.23,
                      "\(kind.rawValue)/\(stateName): card must separate from black without a bright gray slab")
                check(abs(luminance(upper) - brightness) < 0.02,
                      "\(kind.rawValue)/\(stateName): sheen must be subtle, not a bright stripe")
                if let reference {
                    check(distance(reference, lower) < 0.012,
                          "\(stateName): all service kinds must share the same card surface")
                } else { reference = lower }
                if kind == .membership {
                    if stateName == "idle" { idleLuma = brightness }
                    if stateName == "hover" || stateName == "drag" {
                        check(brightness > idleLuma + 0.002, "\(stateName): interaction feedback must remain visible")
                    }
                    if stateName == "press" { check(brightness < idleLuma, "Press must retain its quiet indentation") }
                }
                // Caption glyph interiors in the actual card's header. The
                // three fixtures use equally short names; artwork is outside.
                let caption = brightest(image, x: 46..<107, y: 31..<43)
                let contrast = (luminance(caption) + 0.05) / (max(luminance(upper), brightness) + 0.05)
                print("\(kind.rawValue)/\(stateName) caption contrast=\(contrast)")
                check(contrast >= 4.5, "\(kind.rawValue)/\(stateName): small caption must remain readable")
                check(spread(caption) < 0.07, "\(kind.rawValue)/\(stateName): captions must not retain the old category tint")
            }
        }
        // Sample content only, for visual inspection of actual shared cards.
        let overview = VStack(alignment: .leading, spacing: 18) {
            Text("Paul Notch · 配色验证 · 示例数据").font(.system(size: 13)).foregroundStyle(.white)
            ForEach(Array(states.enumerated()), id: \.offset) { _, entry in
                HStack(spacing: 16) {
                    Text(entry.0).font(.system(size: 11)).foregroundStyle(.gray).frame(width: 40)
                    ForEach(Array(kinds.enumerated()), id: \.offset) { _, kind in
                        QuotaOverviewAccountCard(account: account(kind), isPinned: false,
                            onOpen: {}, interaction: entry.1).frame(width: 110, height: 110)
                    }
                }
            }
        }.padding(24).background(Color.black).preferredColorScheme(.dark)
        try save(try render(overview), output.appendingPathComponent("card-states.png"))
        check(ProviderBrandAssets.image(for: "codex") != nil && ProviderBrandAssets.image(for: "minimax-api") != nil,
              "Visual fixture must include genuine bundled brand artwork")
        if !failures.isEmpty { print("FAIL: \(failures.count) card palette checks failed"); exit(1) }
        print("PASS: 12 real card states, uniform neutral surfaces, quiet sheen, caption contrast and preserved interaction feedback")
    }
    @MainActor static func account(_ kind: QuotaOverviewKind) -> QuotaOverviewAccount {
        switch kind {
        case .membership:
            .init(id: "codex", name: "Codex", account: "示例", group: .membership,
                  value: .percent(68), timing: "7 天后重置", status: .sample)
        case .api:
            .init(id: "minimax-api", name: "MiniMax", account: "示例", group: .usage,
                  value: .money(21.47, currency: "CNY"), timing: "按量扣费", status: .sample)
        case .audio:
            .init(id: "minimax-audio", name: "MiniMax", account: "示例", group: .usage,
                  value: .unknown, timing: "未知", status: .notConnected, usageKind: .audio)
        }
    }
    @MainActor static func render(_ content: some View) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: content)
        renderer.scale = 3
        guard let cg = renderer.cgImage else { throw Failure(message: "Native render unavailable") }
        return NSBitmapImageRep(cgImage: cg)
    }
    static func save(_ image: NSBitmapImageRep, _ url: URL) throws {
        guard let png = image.representation(using: .png, properties: [:]) else { throw Failure(message: "PNG unavailable") }
        try png.write(to: url)
    }
    static func pixel(_ image: NSBitmapImageRep, _ x: Int, _ y: Int) -> NSColor {
        image.colorAt(x: x * 3, y: y * 3)!.usingColorSpace(.sRGB)!
    }
    static func brightest(_ image: NSBitmapImageRep, x: Range<Int>, y: Range<Int>) -> NSColor {
        var result = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        for row in (y.lowerBound * 3)..<(y.upperBound * 3) {
            for column in (x.lowerBound * 3)..<(x.upperBound * 3) {
                let color = image.colorAt(x: column, y: row)!.usingColorSpace(.sRGB)!
                if luminance(color) > luminance(result) { result = color }
            }
        }
        return result
    }
    static func luminance(_ color: NSColor) -> CGFloat {
        func linear(_ x: CGFloat) -> CGFloat { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
    }
    static func spread(_ color: NSColor) -> CGFloat {
        max(color.redComponent, color.greenComponent, color.blueComponent) - min(color.redComponent, color.greenComponent, color.blueComponent)
    }
    static func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
        max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent), abs(a.blueComponent - b.blueComponent))
    }
}
