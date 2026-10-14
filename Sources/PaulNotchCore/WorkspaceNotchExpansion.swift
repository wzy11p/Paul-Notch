import AppKit
import QuartzCore

/// A single temporary vector mask grows from the compact notch to the reading
/// surface. The mounted content never moves, scales, snapshots or reflows.
@MainActor final class WorkspaceNotchExpansion {
    private let container: WorkspacePanelContainer
    private let mask = CAShapeLayer()
    private let compact: NSRect
    private let expanded: NSRect
    private var hasAnimated = false

    init(container: WorkspacePanelContainer, notch: NSRect, opening: Bool) {
        self.container = container
        expanded = container.bounds
        compact = notch.intersection(expanded)
        container.isMorphing = true
        CATransaction.begin(); CATransaction.setDisableActions(true)
        mask.frame = expanded
        mask.fillColor = NSColor.black.cgColor
        mask.path = path(opening ? compact : expanded, radius: opening ? 16 : 22)
        container.contentHolder.layer?.mask = mask
        CATransaction.commit()
    }

    func animate(opening: Bool, duration: TimeInterval) {
        let from = hasAnimated ? (mask.presentation()?.path ?? mask.path) : mask.path
        let target = path(opening ? expanded : compact, radius: opening ? 22 : 16)
        hasAnimated = true
        CATransaction.begin(); CATransaction.setDisableActions(true)
        mask.removeAnimation(forKey: "notch-expansion")
        mask.path = target
        CATransaction.commit()
        let animation = CABasicAnimation(keyPath: "path")
        animation.fromValue = from; animation.toValue = target
        animation.duration = duration
        animation.timingFunction = opening
            ? CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            : CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
        mask.add(animation, forKey: "notch-expansion")
    }

    func finish() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        mask.removeAllAnimations()
        if container.contentHolder.layer?.mask === mask { container.contentHolder.layer?.mask = nil }
        container.isMorphing = false
        CATransaction.commit()
    }

    private func path(_ frame: NSRect, radius: CGFloat) -> CGPath {
        // SwiftUI's top-down shape is also the single source for the native
        // bottom-up compositor mask, including the flat attachment edge.
        let rect = NSRect(x: frame.minX, y: expanded.minY + expanded.maxY - frame.maxY,
                          width: frame.width, height: frame.height)
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: expanded.minY + expanded.maxY)
        return WorkspaceSurfaceShape(isDocked: true, radius: radius).path(in: rect).cgPath.copy(using: &flip)!
    }
}
