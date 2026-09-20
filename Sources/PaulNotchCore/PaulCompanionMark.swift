import AppKit
import SwiftUI

enum PaulCompanionPointer {
    static func normalized(_ point: CGPoint, in size: CGSize) -> CGPoint {
        guard size.width > 0, size.height > 0, point.x.isFinite, point.y.isFinite else { return .zero }
        return CGPoint(x: min(1, max(-1, point.x / size.width * 2 - 1)),
                       y: min(1, max(-1, point.y / size.height * 2 - 1)))
    }
}

/// The approved P silhouette, normalized without changing the app/menu icon assets.
struct PaulCompanionShape: Shape {
    func path(in rect: CGRect) -> Path {
        let source = PaulBrand.mark()
        var result = Path()
        let points = UnsafeMutablePointer<NSPoint>.allocate(capacity: 3)
        defer { points.deallocate() }
        func mapped(_ point: NSPoint) -> CGPoint {
            CGPoint(x: rect.minX + (point.x - 23) / 62 * rect.width,
                    y: rect.minY + (85 - point.y) / 70 * rect.height)
        }
        for index in 0..<source.elementCount {
            switch source.element(at: index, associatedPoints: points) {
            case .moveTo: result.move(to: mapped(points[0]))
            case .lineTo: result.addLine(to: mapped(points[0]))
            case .curveTo:
                result.addCurve(to: mapped(points[2]), control1: mapped(points[0]), control2: mapped(points[1]))
            case .closePath: result.closeSubpath()
            default: break // PaulBrand.mark uses only the four legacy path elements above.
            }
        }
        return result
    }
}

/// Input-driven poses only: no idle timer, random blink, global pointer read or task inference.
struct PaulCompanionMark: View {
    let size: CGFloat
    let attentive: Bool
    let pressed: Bool
    let quiet: Bool
    var working = false
    var pointer: CGPoint = .zero

    private var direction: CGPoint {
        quiet || !attentive ? .zero : CGPoint(x: min(1, max(-1, pointer.x)), y: min(1, max(-1, pointer.y)))
    }

    var body: some View {
        ZStack {
            PaulCompanionShape().fill(Color(white: working && !quiet ? 0.52 : 0.9))
            if working && !quiet {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                    let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
                    LinearGradient(colors: [.clear, .white.opacity(0.95), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: size * 0.65)
                        .position(x: size / 2, y: size * (-0.35 + phase * 1.7))
                }
                .mask(PaulCompanionShape())
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(x: !quiet && pressed ? 1.05 : 1,
                     y: !quiet && pressed ? 0.90 : 1, anchor: .bottom)
        .rotation3DEffect(.degrees(-direction.y * 12), axis: (x: 1, y: 0, z: 0), perspective: 0.35)
        .rotation3DEffect(.degrees(direction.x * 15), axis: (x: 0, y: 1, z: 0), perspective: 0.35)
        .rotationEffect(.degrees(direction.x * 8), anchor: .bottom)
        .offset(x: direction.x * size * 0.055, y: direction.y * size * 0.045)
        .animation(quiet ? nil : .spring(response: 0.24, dampingFraction: 0.88), value: direction)
        .accessibilityHidden(true)
    }
}
