import SwiftUI

/// Docked and detached are the same surface, with only the top attachment
/// changing. No rounded upper lip separates an expanded notch from the display.
struct WorkspaceSurfaceShape: Shape {
    var isDocked: Bool
    var radius: CGFloat = 22

    func path(in rect: CGRect) -> Path {
        guard isDocked else {
            return RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect)
        }
        let r = min(radius, rect.width / 2, rect.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY),
                          control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r),
                          control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
