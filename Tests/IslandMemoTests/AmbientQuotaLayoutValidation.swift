import AppKit
import SwiftUI

@main
struct AmbientQuotaLayoutValidation {
    @MainActor static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        var providerOverflow = 0
        for fullScreen in [false, true] {
            for period in ["7D", "6D", "<1D", "5H", "4H", "<1H", "—", "Q"] {
                var widths: [CGFloat] = []
                for value in [0, 9, 99, 100] {
                    let renderer = ImageRenderer(content: label(period, value, fullScreen))
                    guard let image = renderer.nsImage else { fatalError("Cannot render quota") }
                    // Existing physical wings supply 43pt normal / 38pt full screen.
                    precondition(image.size.width <= 40, "Quota \(period) \(value)% full-screen=\(fullScreen) plus stale dot exceeds existing wing: \(image.size.width)")
                    precondition(image.size.height * 2 <= (fullScreen ? 24 : 32), "Dual quotas exceed shelf height")
                    widths.append(image.size.width)
                }
                precondition((widths.max()! - widths.min()!) < 0.1, "Changing digits moves the quota slot")
            }
        }
        for fullScreen in [false, true] {
            for period in ["28D", "366D", "60M", "<1M", "待用", "—"] {
                for comparison in ["", ">"] {
                    let content = AmbientQuotaLabel(period: period, remaining: 99, isFullScreen: fullScreen,
                        color: .green, secondaryColor: .gray, comparison: comparison)
                    let renderer = ImageRenderer(content: content)
                    guard let image = renderer.nsImage else { fatalError("Cannot render foreground quota") }
                    if image.size.width > (fullScreen ? 38 : 40) {
                        providerOverflow += 1
                        print("FAIL: \(period) \(comparison)99% full-screen=\(fullScreen) is \(image.size.width)pt")
                        fflush(stdout)
                    }
                    precondition(image.size.height * 2 <= (fullScreen ? 24 : 32), "Provider line exceeds shelf height")
                }
            }
        }
        precondition(providerOverflow == 0, "Bounded provider countdown/value exceeds the existing wing")
        let sheet = VStack(alignment: .leading, spacing: 12) {
            Text("Synthetic quota layout • unchanged 45pt wing").font(.system(size: 12))
            HStack(alignment: .top, spacing: 32) {
                ForEach([false, true], id: \.self) { fullScreen in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(fullScreen ? "Full screen" : "Normal").font(.system(size: 11))
                        ForEach([0, 9, 99, 100], id: \.self) { value in
                            HStack(spacing: 2) {
                                label(value == 0 ? "<1D" : "7D", value, fullScreen)
                                Circle().stroke(.white.opacity(0.42), lineWidth: 1).frame(width: 3, height: 3)
                            }.frame(width: 45, height: fullScreen ? 24 : 32)
                        }
                        VStack(spacing: 0) {
                            label("7D", 100, fullScreen)
                            label("5H", 100, fullScreen)
                        }.frame(width: 45, height: fullScreen ? 24 : 32)
                    }
                }
            }
        }
        .padding(16).foregroundStyle(.white).background(.black)
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 3
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Cannot encode layout sheet")
        }
        try png.write(to: output.appendingPathComponent("quota-layout.png"))
        print("PASS: 64 legacy and 24 foreground quota layouts fit existing wings; digit slots remain stable; normal/full-screen percent units")
        print(output.appendingPathComponent("quota-layout.png").path)
    }

    static func label(_ period: String, _ value: Int, _ fullScreen: Bool) -> AmbientQuotaLabel {
        AmbientQuotaLabel(period: period, remaining: value, isFullScreen: fullScreen, color: .green,
                          secondaryColor: Color(red: 161 / 255, green: 161 / 255, blue: 161 / 255))
    }
}
