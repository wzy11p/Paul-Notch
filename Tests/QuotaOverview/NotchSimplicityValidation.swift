import AppKit
import SwiftUI
import Vision
@testable import PaulNotchCore

/// Real rendered labels, with synthetic readings only; no account/store startup.
@main struct NotchSimplicityValidation {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }
        func read(_ lines: [AmbientQuotaLine], _ placement: QuotaGlanceRows.Placement,
                  fullScreen: Bool = false, name: String) throws -> (String, CGSize) {
            let renderer = ImageRenderer(content: QuotaGlanceRows(lines: lines, placement: placement,
                isFullScreen: fullScreen).padding(6).background(Color.black))
            renderer.scale = 8
            guard let image = renderer.cgImage else { fatalError("The actual readout must render") }
            let bitmap = NSBitmapImageRep(cgImage: image)
            if placement == .notchValues && lines.count == 1,
               case .percent(let amount) = lines[0].value, amount > 0 {
                var clockRight = -1
                var amountLeft = image.width
                for y in 0..<image.height {
                    for x in 0..<image.width {
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                        let high = max(color.redComponent, color.greenComponent, color.blueComponent)
                        let low = min(color.redComponent, color.greenComponent, color.blueComponent)
                        if high > 0.45 && high - low < 0.08 { clockRight = max(clockRight, x) }
                        if high > 0.45 && high - low > 0.25 { amountLeft = min(amountLeft, x) }
                    }
                }
                let gap = Double(amountLeft - clockRight - 1) / 8
                check(clockRight >= 0 && amountLeft < image.width && gap >= 3,
                      "Real clock/amount glyphs need at least 3pt clear space: \(name), gap=\(gap)")
            }
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
            let request = VNRecognizeTextRequest()
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: image).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            return (text, CGSize(width: CGFloat(image.width) / 8 - 12, height: CGFloat(image.height) / 8 - 12))
        }
        let single = [AmbientQuotaLine(id: "week", period: "5D", value: .percent(10), poolLabel: "总额")]
        check(QuotaGlanceRows.notchResetText(single[0]) == "5D", "The user prefers the original D/H/M clocks")
        for fullScreen in [false, true] {
            let result = try read(single, .notchValues, fullScreen: fullScreen, name: "single-\(fullScreen)")
            check(result.0.contains("5") && result.0.contains("10") && !result.0.contains("T"),
                  "A single reading must show its compact reset beside the amount, without T: \(result.0)")
            check(result.1.width <= 72 && result.1.height <= 14, "A single row must fit the unchanged compact shelf")
            for value in [0, 9, 10, 99, 100] {
                let edge = AmbientQuotaLine(id: "week", period: "7D", value: .percent(value), poolLabel: "总额")
                let reading = try read([edge], .notchValues, fullScreen: fullScreen, name: "edge-\(fullScreen)-\(value)")
                print("Measured 7D \(value)% fullScreen=\(fullScreen): \(reading.1.width)pt")
                check(reading.1.width <= (fullScreen ? 40 : 45), "Boundary reading must fit outside the real camera gap")
            }
        }
        let pair = [AmbientQuotaLine(id: "short", period: "2H", value: .percent(100), poolLabel: "时段"),
                    AmbientQuotaLine(id: "week", period: "5D", value: .percent(2), poolLabel: "总额")]
        let amounts = try read(pair, .notchValues, name: "dual-values")
        let resets = try read(pair, .notchResets, name: "dual-resets")
        check(amounts.0.contains("100") && amounts.0.contains("2"), "Both independent quotas must remain visible")
        check(resets.0.contains("2H") && resets.0.contains("5D"),
              "Both reset rows must retain the original Latin units: \(resets.0)")
        let pending = [AmbientQuotaLine(id: "doubao.short", period: "待用", value: .unknown, poolLabel: "时段"),
                       AmbientQuotaLine(id: "doubao.weekly", period: "—", value: .percent(2), poolLabel: "总额",
                                        resetDescription: "10月15日 02:02 重置")]
        let uncertain = try read(pending, .notchResets, name: "pending-date")
        check(uncertain.0.contains("待用") && uncertain.0.contains("10/15"),
              "Pending state and reported calendar date must not become a guessed countdown: \(uncertain.0)")
        for token in ["366D", "23H", "59M", "<1M", "—", "待刷新"] {
            let line = AmbientQuotaLine(id: token, period: token, value: .percent(100), poolLabel: "总额")
            let result = try read([line], .notchValues, name: "width-\(token.replacingOccurrences(of: "<", with: "under"))")
            check(result.1.width <= 72, "Long reset/unknown state must fit without squeezing the amount: \(token), \(result.1.width)")
        }
        if !failures.isEmpty { failures.forEach { print("FAIL: \($0)") }; exit(1) }
        print("PASS: native single/dual D/H/M resets, real glyph spacing, no redundant single label, literal calendar/pending states and bounded widths")
    }
}
