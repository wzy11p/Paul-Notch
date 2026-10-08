import AppKit
import SwiftUI
import Vision

@main
struct QuotaOverviewUIValidation {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.finishLaunching()
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        var failures: [String] = []
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            if !value() { failures.append(message); print("FAIL: \(message)") }
        }
        for id in ["codex", "cursor", "kimi", "grok", "doubao", "deepseek", "minimax-api", "minimax-audio", "muse"] {
            check(ProviderBrandAssets.image(for: id) != nil, "\(id) needs its verified vendor artwork")
            if let logo = ProviderBrandAssets.image(for: id),
               let cgImage = logo.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let bitmap = NSBitmapImageRep(cgImage: cgImage)
                let bounds = opaqueBounds(bitmap)
                let coverage = max(bounds.width, bounds.height) / CGFloat(max(bitmap.pixelsWide, bitmap.pixelsHigh))
                // A common frame alone is not enough: built-in icon padding used to
                // make Codex/Kimi/Doubao visibly smaller than the full-bleed favicons.
                print("Logo \(id): visible \(bounds), canvas \(bitmap.pixelsWide)×\(bitmap.pixelsHigh)")
                check(coverage >= 0.95, "\(id): artwork must fill the shared logo footprint, not retain source padding")
                check(min(bounds.width / CGFloat(bitmap.pixelsWide), bounds.height / CGFloat(bitmap.pixelsHigh)) >= 0.95,
                      "\(id): use equally sized official app-icon silhouettes, not a short transparent favicon beside square icons")
                check(abs(bounds.midX / CGFloat(bitmap.pixelsWide) - 0.5) < 0.03 &&
                      abs(bounds.midY / CGFloat(bitmap.pixelsHigh) - 0.5) < 0.03,
                      "\(id): visible artwork must be centered in its fitted image")
            }
        }
        check(ProviderBrandAssets.image(for: "unverified-provider") == nil,
              "Unknown services must not receive an invented logo")
        let dual = QuotaOverviewAccount(id: "doubao", name: "豆包工作", account: "ByteDance", group: .membership,
            value: .percent(55), timing: "3 小时后重置", status: .current,
            pools: [.init(label: "当前时段", value: .percent(55), timing: "3 小时后重置"),
                    .init(label: "近 7 天", value: .percent(81), timing: "6 天后重置")])
        let dualRenderer = ImageRenderer(content: QuotaOverviewAccountCard(account: dual, isPinned: false, onOpen: {})
            .frame(width: 118, height: 118))
        dualRenderer.scale = 3
        if let cg = dualRenderer.cgImage {
            let bitmap = NSBitmapImageRep(cgImage: cg)
            try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("dual-pool.png"))
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            try VNImageRequestHandler(cgImage: cg).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined().filter { !$0.isWhitespace }
            check(text.contains("55%") && text.contains("81%"),
                  "The small card must actually render BOTH independent pool percentages, not just carry them in its model")
        } else { check(false, "The dual-pool native card must render") }
        for count in [0, 4, 7, 12, 30] {
            for width in [600.0, 820.0] {
                let host = NSHostingView(rootView: QuotaOverviewView(accounts: QuotaOverviewFixtures.accounts(count: count), onClose: {}, mode: .notch))
                host.sizingOptions = []
                let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: 510),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                window.alphaValue = 0
                window.orderBack(nil)
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.12))
                check(window.frame.height == 510 && host.frame.width == width,
                      "\(count) accounts: contents must not enlarge the native window")
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                    throw Failure.cannotRender
                }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure.cannotRender }
                try png.write(to: directory.appendingPathComponent("quota-\(count)-\(Int(width)).png"))
                window.orderOut(nil)
            }
        }
        // This is geometry/render verification. Mouse/keyboard and AX acceptance use the
        // real preview app: SwiftUI does not publish its full AX tree to this off-screen host.
        for account in QuotaOverviewFixtures.accounts(count: 30) {
            for width in [118.0, 160.0] {
                let row = QuotaOverviewAccountCard(account: account, isPinned: false, onOpen: {})
                    .frame(width: width, height: width)
                let renderer = ImageRenderer(content: row)
                guard let image = renderer.nsImage else { throw Failure.cannotRender }
                check(image.size.height == width && image.size.width == width,
                      "\(account.id): small text or amount must not collapse bubble bounds at \(width)pt")
            }
        }
        guard failures.isEmpty else { exit(1) }
        print("PASS: 10 native bento renders at 600/820pt with 0/4/7/12/30 accounts; 60 bubble geometry checks")
        print("Mouse, keyboard and AX interactions require the visible native preview; these are layout checks only")
    }
    private static func opaqueBounds(_ bitmap: NSBitmapImageRep) -> CGRect {
        var minX = bitmap.pixelsWide, minY = bitmap.pixelsHigh, maxX = -1, maxY = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) >= 0.5 {
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
    enum Failure: Error { case cannotRender }
}
