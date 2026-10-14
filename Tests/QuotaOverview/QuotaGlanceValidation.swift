import AppKit
import SwiftUI
import Vision
@testable import PaulNotchCore

/// Isolated presentation checks: no personal account, browser or credentials.
@main struct QuotaGlanceValidation {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        let cursor = QuotaOverviewAccount(id: "cursor", name: "Cursor", account: "fixture",
            group: .membership, value: .percent(77), timing: "18 天后重置", status: .current,
            pools: [.init(label: "Cursor", value: .percent(77), timing: "18 天后重置"),
                    .init(label: "其他模型", value: .percent(33), timing: "18 天后重置")])
        for model in ["Auto", "Grok 4.7", "Claude Sonnet 5.5 High"] {
            let state = AmbientQuotaPresentation.make(service: .cursor, account: cursor,
                resetsAt: now.addingTimeInterval(18 * 86400), observedAt: now,
                cursorModel: CursorModelSelection.parse(model) ?? .unavailable, at: now)
            check(state.lines.map(\.value) == [.percent(77), .percent(33)],
                  "Switching \(model) must preserve both quota slots and their order")
            check(state.lines.map(\.poolLabel) == ["Cursor", "其他"],
                  "Compact pools must be named, never cryptic 内/外 prefixes")
            let expected: QuotaOverviewValue? = model == "Auto" ? nil : model == "Grok 4.7" ? .percent(77) : .percent(33)
            check(state.liquidValue == expected, "Water must still represent only the identified current pool")
        }
        var missing = cursor
        missing.pools.removeLast()
        let missingState = AmbientQuotaPresentation.make(service: .cursor, account: missing,
            cursorModel: CursorModelSelection.parse("Claude Sonnet 5.5 High")!, at: now)
        check(missingState.lines.map(\.value) == [.percent(77), .unknown] && missingState.liquidValue == nil,
              "A missing selected pool keeps its labeled empty slot instead of collapsing or borrowing the other balance")
        let doubao = QuotaOverviewAccount(id: "doubao", name: "豆包工作", account: "fixture",
            group: .membership, value: .percent(100), timing: "开始使用后计时", status: .current,
            pools: [.init(label: "当前时段", value: .percent(100), timing: "开始使用后计时"),
                    .init(label: "近 7 天", value: .percent(2), timing: "10月15日 02:02 重置")])
        let pair = AmbientQuotaPresentation.make(service: .doubao, account: doubao, observedAt: now, at: now)
        check(pair.lines.map(\.compactLabel) == ["S", "T"] &&
              pair.lines.map(\.compactResetText) == ["P", "10/15"],
              "Doubao gets stable one-letter identities, pending state and an unchanged calendar date")
        check(pair.summary.contains("S＝5 小时") && pair.summary.contains("P＝尚未计时"),
              "The real hover/accessibility summary must explain shortened labels")
        check(["Cursor", "其他", "剩余"].map(QuotaGlanceText.compactPool) == ["C", "O", "R"],
              "Independent Cursor pools and a single remainder have distinct letters")
        check(["2H", "6D", "<1M", "待用", "待刷新", "—", "bad"].map(QuotaGlanceText.compactCountdown) ==
              ["2H", "6D", "<1M", "P", "…", "—", "—"], "Only valid countdowns get compact durations")
        check(QuotaGlanceText.modelMark("Sonnet") == "S" && QuotaGlanceText.modelMark("GPT 5.6") == "GPT" &&
              QuotaGlanceText.modelMark("Gemini") == "Ge" && QuotaGlanceText.modelMark("unknown") == nil,
              "Short model labels stay distinct and cannot invent unknown models")
        check(pair.lines.map(\.poolLabel) == ["时段", "总额"],
              "Window identity must not look like a reset countdown")
        check(pair.lines.map(\.value) == [.percent(100), .percent(2)] && pair.liquidValue == .percent(2),
              "Clarifying the view must retain both exact values and the total waterline")
        check(pair.lines.last?.resetDescription == "10月15日 02:02 重置" && pair.lines.last?.period == "—",
              "A date-only provider caption must not acquire an invented precise deadline")
        let resetCases = [("2H", "2时后重置"), ("6D", "6天后重置"), ("<1M", "1分内重置"),
                          ("待用", "未计时"), ("待刷新", "待更新"), ("—", "时间待确认")]
        for (input, expected) in resetCases {
            check(QuotaGlanceText.countdown(input) == expected,
                  "Reset wording must keep duration distinct from wall-clock time and missing states: \(input)")
        }
        let renderer = ImageRenderer(content: DoubaoAmbientQuotaView(lines: pair.lines, placement: .notchResets)
            .padding(5).background(Color.black))
        renderer.scale = 6
        if let image = renderer.cgImage {
            let request = VNRecognizeTextRequest()
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: image).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined()
            check(text.contains("10/15") && !text.contains("重置") && !text.contains("计时"),
                  "The owner-requested compact reset must omit prose and keep the reported date: \(text)")
        } else { check(false, "The actual reset view must render") }
        let cursorLabels = ImageRenderer(content: QuotaGlanceRows(lines: QuotaGlanceFixtures.state(.cursor).lines,
            placement: .notchValues).padding(5).background(Color.black))
        cursorLabels.scale = 8
        if let image = cursorLabels.cgImage {
            let request = VNRecognizeTextRequest()
            request.recognitionLanguages = ["en-US", "zh-Hans"]
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: image).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined()
            check(!text.contains("Cursor") && !text.contains("其他") && text.contains("77") && text.contains("33"),
                  "Compact quota pools must use letters without dropping either value: \(text)")
        } else { check(false, "The actual compact pool names must render") }
        let input = FloatingQuotaInputView(frame: NSRect(origin: .zero, size: QuotaFloatingPlacement.bubbleSize))
        check(QuotaFloatingPlacement.orbDiameter == 78 && QuotaFloatingPlacement.bubbleSize == NSSize(width: 92, height: 92),
              "Approved A restores the 78pt orb and its original 7pt transparent margin")
        check(input.hitTest(NSPoint(x: input.bounds.midX + 38, y: input.bounds.midY)) === input,
              "The compact visible rim must remain clickable/draggable")
        check(input.hitTest(NSPoint(x: input.bounds.midX + 41, y: input.bounds.midY)) == nil,
              "Shrinking the orb must also shrink its invisible mouse interception area")
        check(input.hitTest(NSPoint(x: 1, y: 1)) == nil, "Transparent corners must still pass through")
        func reading(_ service: AmbientQuotaService, lines: [AmbientQuotaLine]) throws -> [VNRecognizedTextObservation] {
            let render = ImageRenderer(content: QuotaOrbReadout(service: service, lines: lines)
                .frame(width: 78, height: 78).background(Color.white))
            render.scale = 8
            guard let image = render.cgImage else { check(false, "A readout must render"); return [] }
            let request = VNRecognizeTextRequest()
            request.recognitionLanguages = ["en-US"]
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: image).perform([request])
            return request.results ?? []
        }
        let singleReading = try reading(.codex, lines: QuotaGlanceFixtures.state(.codex).lines)
        let singleNumber = singleReading.first { $0.topCandidates(1).first?.string.contains("32") == true }
        check(singleNumber != nil && singleNumber!.boundingBox.height * 78 >= 16,
              "A makes the single quota number visibly primary at the compact size")
        let cursorReading = try reading(.cursor, lines: QuotaGlanceFixtures.state(.cursor).lines)
            .compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        check(cursorReading.contains("77") && cursorReading.contains("33") &&
              cursorReading.components(separatedBy: "18D").count - 1 == 1,
              "A preserves both Cursor balances but shows their shared cycle once: \(cursorReading)")
        let separate = try reading(.cursor, lines: [
            .init(id: "Cursor Models", period: "18D", value: .percent(77), poolLabel: "Cursor"),
            .init(id: "Other Models", period: "19D", value: .percent(33), poolLabel: "其他")])
            .compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        check(separate.contains("18D") && separate.contains("19D"),
              "Different deadlines must never be merged to save space: \(separate)")
        let doubaoReading = try reading(.doubao, lines: pair.lines)
            .compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        check(doubaoReading.contains("100") && doubaoReading.contains("2") &&
              doubaoReading.contains("10/15") && doubaoReading.contains("P"),
              "A keeps both Doubao balances and their independent reset states: \(doubaoReading)")
        let unclipped = ImageRenderer(content: QuotaOrbReadout(service: .doubao, lines: pair.lines)
            .frame(width: 78, height: 78))
        unclipped.scale = 4
        if let cg = unclipped.cgImage {
            let pixels = NSBitmapImageRep(cgImage: cg)
            var escapingInk = 0
            for y in 0..<pixels.pixelsHigh { for x in 0..<pixels.pixelsWide {
                guard hypot(CGFloat(x) / 4 - 39, CGFloat(y) / 4 - 39) > 38,
                      let pixel = pixels.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if pixel.alphaComponent > 0.9 && max(pixel.redComponent, pixel.greenComponent, pixel.blueComponent) < 0.25 {
                    escapingInk += 1
                }
            } }
            check(escapingInk < 5, "No Doubao label/date may be cut by the actual circular clip: \(escapingInk) dark pixels outside the safe rim")
        } else { check(false, "The independent-cycle readout must rasterize") }
        // The owner accepts the light glass, not a dark reading disc. Check
        // dark ink against the actual local frost on both background extremes.
        for background in [0.0, 1.0] {
            let contrast = ImageRenderer(content: QuotaOrbReadingBackdrop().frame(width: 78, height: 78)
                .background(Color(white: background)))
            contrast.scale = 2
            guard let cg = contrast.cgImage else { check(false, "The reading frost must render"); continue }
            let bitmap = NSBitmapImageRep(cgImage: cg)
            func linear(_ n: CGFloat) -> CGFloat { n <= 0.04045 ? n / 12.92 : pow((n + 0.055) / 1.055, 2.4) }
            let ink = NSColor(QuotaOrbInk.secondary).usingColorSpace(.deviceRGB)!
            let inkLuminance = 0.2126 * linear(ink.redComponent) + 0.7152 * linear(ink.greenComponent) + 0.0722 * linear(ink.blueComponent)
            check(NSColor(QuotaOrbInk.primary).usingColorSpace(.deviceRGB)!.redComponent <= ink.redComponent,
                  "Primary numbers must be at least as dark and opaque as secondary captions")
            func luminance(_ x: Int, _ y: Int) -> CGFloat {
                let color = bitmap.colorAt(x: x * 2, y: y * 2)!.usingColorSpace(.deviceRGB)!
                return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
            }
            for (x, y) in [(15,34), (63,34), (15,50), (63,50), (39,67)] {
                check((luminance(x,y) + 0.05) / (inkLuminance + 0.05) >= 4.5,
                      "Primary and secondary dark ink need 4.5:1 contrast on light frost at \(x),\(y), backdrop \(background)")
            }
            print("READING_RIM backdrop=\(background), luminance=\(luminance(39,2))")
            check(background == 0 ? luminance(39,2) < 0.06 : luminance(39,2) > 0.8,
                  "The outer rim must remain transmitting, not become a solid disc")
        }
        let glass = QuotaLiquidOrbView(frame: NSRect(x: 0, y: 0, width: 78, height: 78))
        let materials = glass.subviews.compactMap { $0 as? NSVisualEffectView }
        check(materials.count == 1 && (0.28...0.38).contains(materials[0].alphaValue) &&
              materials[0].appearance?.name == .aqua && materials[0].blendingMode == .behindWindow,
              "Softer background reuses one modest light native frost, not a new blur engine or a dark HUD")
        glass.stop()
        // Measure the assembled water + reading support, not only the bare
        // pigment or a white plate that hides it. This catches a milky cover
        // washing out the liquid even when the separate layers look adequate.
        for background in [0.0, 1.0] {
            let full = AmbientQuotaPresentation(service: .codex,
                lines: [.init(id: "clarity", period: "6D", value: .percent(100), poolLabel: "剩余")],
                activity: .notAvailable, summary: "Synthetic material check", cursorModel: nil)
            for state in [full, QuotaGlanceFixtures.state(.doubao), QuotaGlanceFixtures.state(.cursor),
                          QuotaGlanceFixtures.state(.cursor, model: "Grok 4.7"),
                          QuotaGlanceFixtures.state(.cursor, model: "Claude Sonnet 5.5 High")] {
            let sample = NSHostingView(rootView: QuotaGlancePreviewOrb(state: state, showsReading: false)
                .background(Color(white: background)))
            sample.sizingOptions = []
            sample.frame = NSRect(x: 0, y: 0, width: 78, height: 78)
            let window = NSWindow(contentRect: sample.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = sample
            window.setFrameOrigin(NSPoint(x: -20000, y: -20000)); window.orderBack(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1)); sample.layoutSubtreeIfNeeded()
            if let image = sample.bitmapImageRepForCachingDisplay(in: sample.bounds) {
                sample.cacheDisplay(in: sample.bounds, to: image)
                var colorSeparations: [CGFloat] = []
                var textContrasts: [CGFloat] = []
                func linear(_ n: CGFloat) -> CGFloat { n <= 0.04045 ? n / 12.92 : pow((n + 0.055) / 1.055, 2.4) }
                let ink = NSColor(QuotaOrbInk.secondary).usingColorSpace(.deviceRGB)!
                let inkLuminance = 0.2126 * linear(ink.redComponent) + 0.7152 * linear(ink.greenComponent) + 0.0722 * linear(ink.blueComponent)
                for (x, y) in [(15,34), (63,34), (15,50), (63,50), (39,67)] {
                    let color = image.colorAt(x: x * image.pixelsWide / 78, y: y * image.pixelsHigh / 78)!.usingColorSpace(.deviceRGB)!
                    colorSeparations.append(color.blueComponent - color.redComponent)
                    let luminance = 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
                    textContrasts.append((luminance + 0.05) / (inkLuminance + 0.05))
                }
                colorSeparations.sort()
                print("ASSEMBLED_WATER service=\(state.service), backdrop=\(background), blue-red median=\(colorSeparations[2]), minimum text contrast=\(textContrasts.min()!)")
                if state.service == .codex {
                    check(colorSeparations[2] >= 0.16,
                          "Water must remain visibly blue on both backgrounds after the reading coat, not milky gray: \(background)")
                }
                check(textContrasts.allSatisfy { $0 >= 4.5 },
                      "The actual water-backed small captions need 4.5:1 contrast on backdrop \(background)")
                let glyphs = ImageRenderer(content: QuotaOrbReadout(service: state.service, lines: state.lines)
                    .frame(width: 78, height: 78))
                glyphs.scale = 2
                if let cg = glyphs.cgImage {
                    let mask = NSBitmapImageRep(cgImage: cg)
                    var worst: CGFloat = .greatestFiniteMagnitude
                    var worstPoint = NSPoint.zero
                    var checked = 0
                    // Exclude the actual artwork above the text, not tiny edge
                    // labels: test every opaque glyph pixel in both rows.
                    for y in 50..<mask.pixelsHigh { for x in 0..<mask.pixelsWide {
                        guard let ink = mask.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                              ink.alphaComponent > 0.95,
                              max(ink.redComponent, ink.greenComponent, ink.blueComponent) < 0.25 else { continue }
                        let under = image.colorAt(x: x * image.pixelsWide / mask.pixelsWide,
                                                  y: y * image.pixelsHigh / mask.pixelsHigh)!.usingColorSpace(.deviceRGB)!
                        func luminance(_ c: NSColor) -> CGFloat {
                            0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
                        }
                        let ratio = (luminance(under) + 0.05) / (luminance(ink) + 0.05)
                        if ratio < worst { worst = ratio; worstPoint = NSPoint(x: Double(x) / 2, y: Double(y) / 2) }
                        checked += 1
                    } }
                    print("GLYPH_CONTRAST service=\(state.service), backdrop=\(background), min=\(worst), point=\(worstPoint), samples=\(checked)")
                    check(checked > 10 && worst >= 4.5,
                          "Every compact value/label/date must remain readable near the dark rim: \(state.service), backdrop \(background)")
                } else { check(false, "The real text mask must render") }
            } else { check(false, "The assembled clarity fixture must rasterize") }
            window.orderOut(nil)
            }
        }
        if let root = ProcessInfo.processInfo.environment["PAUL_GLANCE_EVIDENCE"] {
            let host = NSHostingView(rootView: QuotaGlancePreviewSheet())
            host.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 650, height: 575),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
            defer { window.orderOut(nil) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            host.layoutSubtreeIfNeeded()
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to:
                    URL(fileURLWithPath: root).appendingPathComponent("unified-quota-preview.png"))
            } else { check(false, "The complete native fixture must render") }
        }
        if !failures.isEmpty { failures.forEach { print("FAIL: \($0)") }; exit(1) }
        print("PASS: stable dual-pool switching, meaningful labels, exact quota semantics, circular input and light-glass contrast")
    }
}
