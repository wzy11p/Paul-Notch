import AppKit
import QuartzCore

/// Keeps the reading view mounted and its viewport fixed during a compositor
/// transition. Resizing the actual host on every animation frame reflows its grid.
@MainActor final class WorkspacePanelContainer: NSView {
    let workspace: NSView
    let contentHolder = NSView()
    fileprivate var isMorphing = false

    init(workspace: NSView) {
        self.workspace = workspace
        super.init(frame: workspace.frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        contentHolder.wantsLayer = true
        contentHolder.addSubview(workspace)
        addSubview(contentHolder)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        if !isMorphing {
            contentHolder.frame = bounds
            workspace.frame = contentHolder.bounds
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // A fixed union window must not leave invisible controls clickable.
        if isMorphing { return nil }
        return super.hitTest(point)
    }
}

/// Composite the existing, mounted reading layer without taking a large raster.
/// Only transforms and the housing change; no per-frame layout, timer or window.
/// The tiny circle image is transient, released at completion and never saved.
@MainActor final class WorkspaceBubbleMorph {
    private let window: NSWindow
    private let container: WorkspacePanelContainer
    private let expandedFrame: NSRect
    private let bubbleFrame: NSRect
    private let union: NSRect
    private let shell = CALayer()
    private let reading: CALayer
    private let circle = CALayer()
    private let originalShadow: Bool
    private let originalAnchor: CGPoint
    private var hasAnimated = false

    init(window: NSWindow, container: WorkspacePanelContainer, expandedFrame: NSRect,
         bubbleFrame: NSRect, bubbleView: NSView?, opening: Bool) {
        self.window = window
        self.container = container
        reading = container.contentHolder.layer!
        originalAnchor = container.contentHolder.layer!.anchorPoint
        self.expandedFrame = expandedFrame
        self.bubbleFrame = bubbleFrame
        union = expandedFrame.union(bubbleFrame).insetBy(dx: -8, dy: -8)
        originalShadow = window.hasShadow

        container.isMorphing = true
        container.workspace.autoresizingMask = []
        container.contentHolder.frame = NSRect(origin: .zero, size: expandedFrame.size)
        container.workspace.frame = NSRect(origin: .zero, size: expandedFrame.size)
        container.workspace.layoutSubtreeIfNeeded()
        let circleImage = bubbleView.flatMap { Self.image(of: $0) }

        window.hasShadow = false
        window.setFrame(union, display: false)
        container.contentHolder.frame = NSRect(x: expandedFrame.minX - union.minX,
            y: expandedFrame.minY - union.minY, width: expandedFrame.width, height: expandedFrame.height)
        shell.name = "quota-bubble-shell"
        shell.cornerCurve = .continuous
        shell.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
        shell.shadowColor = NSColor.black.cgColor
        shell.shadowOpacity = 0.22
        shell.shadowRadius = 7
        shell.shadowOffset = CGSize(width: 0, height: -3)
        // AppKit's backing layer is anchored at the view origin, unlike a new
        // CALayer. Morph around the same center as the housing, then restore it.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        reading.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        reading.zPosition = 1
        CATransaction.commit()
        circle.contents = circleImage
        circle.contentsGravity = .resize
        circle.bounds = NSRect(origin: .zero, size: bubbleFrame.size)
        circle.zPosition = 2
        container.layer?.addSublayer(shell)
        container.layer?.addSublayer(circle)
        setPose(opening ? local(bubbleFrame.insetBy(dx: 7, dy: 7)) : local(expandedFrame),
                radius: opening ? 39 : 22, readingOpacity: opening ? 0 : 1,
                circleOpacity: opening ? 1 : 0, shadowOpacity: opening ? 0 : 0.22)
    }

    func animate(opening: Bool, duration: TimeInterval) {
        let destination = local(opening ? expandedFrame : bubbleFrame.insetBy(dx: 7, dy: 7))
        let radius: CGFloat = opening ? 22 : 39
        let timing = CAMediaTimingFunction(controlPoints: 0.22, 0.85, 0.24, 1)
        // The first pose was just prepared in a different window/anchor space;
        // its old AppKit presentation is not that pose. Only reversals sample it.
        let visibleShell = hasAnimated ? shell.presentation() ?? shell : shell
        let visibleReading = hasAnimated ? reading.presentation() ?? reading : reading
        let visibleCircle = hasAnimated ? circle.presentation() ?? circle : circle
        hasAnimated = true
        let fromBounds = visibleShell.bounds
        let fromPosition = visibleShell.position
        let fromRadius = visibleShell.cornerRadius
        let fromReadingTransform = visibleReading.transform
        let fromReadingPosition = CGPoint(x: visibleReading.frame.midX, y: visibleReading.frame.midY)
        let fromCirclePosition = visibleCircle.position
        let fromReadingOpacity = visibleReading.opacity
        let fromCircleOpacity = visibleCircle.opacity
        let fromShadowOpacity = visibleShell.shadowOpacity
        shell.removeAllAnimations(); reading.removeAllAnimations(); circle.removeAllAnimations()
        setPose(destination, radius: radius, readingOpacity: opening ? 1 : 0, circleOpacity: opening ? 0 : 1,
                shadowOpacity: opening ? 0.22 : 0)
        for (layer, key, from, to) in [
            (shell, "bounds", NSValue(rect: fromBounds), NSValue(rect: shell.bounds)),
            (shell, "position", NSValue(point: fromPosition), NSValue(point: shell.position)),
            (shell, "cornerRadius", NSNumber(value: Double(fromRadius)), NSNumber(value: Double(radius))),
            (shell, "shadowOpacity", NSNumber(value: fromShadowOpacity), NSNumber(value: shell.shadowOpacity)),
            (reading, "position", NSValue(point: fromReadingPosition), NSValue(point: reading.position)),
            (circle, "position", NSValue(point: fromCirclePosition), NSValue(point: circle.position))
        ] {
            let animation = CABasicAnimation(keyPath: key)
            animation.fromValue = from; animation.toValue = to
            animation.duration = duration; animation.timingFunction = timing
            layer.add(animation, forKey: key)
        }
        let scale = CABasicAnimation(keyPath: "transform")
        scale.fromValue = NSValue(caTransform3D: fromReadingTransform)
        scale.toValue = NSValue(caTransform3D: reading.transform)
        scale.duration = duration; scale.timingFunction = timing
        reading.add(scale, forKey: "transform")
        // Information is not squeezed into a tiny square: it leaves early on
        // close and appears after the housing has opened. The circle overlaps.
        fade(reading, from: fromReadingOpacity, to: opening ? 1 : 0,
             times: opening ? [0, 0.26, 0.8, 1] : [0, 0.03, 0.22, 1], duration: duration)
        fade(circle, from: fromCircleOpacity, to: opening ? 0 : 1,
             times: opening ? [0, 0.12, 0.4, 1] : [0, 0.55, 0.88, 1], duration: duration)
    }

    func finish() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shell.removeFromSuperlayer()
        circle.removeFromSuperlayer(); circle.contents = nil
        reading.removeAllAnimations()
        reading.transform = CATransform3DIdentity
        reading.anchorPoint = originalAnchor
        reading.zPosition = 0
        reading.opacity = 1
        container.isMorphing = false
        window.hasShadow = originalShadow
        window.setFrame(expandedFrame, display: false)
        container.contentHolder.frame = container.bounds
        container.workspace.frame = container.contentHolder.bounds
        reading.position = NSPoint(x: container.bounds.width * originalAnchor.x,
                                   y: container.bounds.height * originalAnchor.y)
        container.workspace.autoresizingMask = [.width, .height]
        CATransaction.commit()
    }

    private func local(_ frame: NSRect) -> NSRect { frame.offsetBy(dx: -union.minX, dy: -union.minY) }

    private func setPose(_ frame: NSRect, radius: CGFloat, readingOpacity: Float, circleOpacity: Float,
                         shadowOpacity: Float) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shell.bounds = NSRect(origin: .zero, size: frame.size)
        shell.position = NSPoint(x: frame.midX, y: frame.midY)
        shell.cornerRadius = radius
        shell.shadowOpacity = shadowOpacity
        reading.position = shell.position
        reading.transform = CATransform3DMakeScale(frame.width / expandedFrame.width,
            frame.height / expandedFrame.height, 1)
        reading.opacity = readingOpacity
        circle.position = shell.position
        circle.opacity = circleOpacity
        CATransaction.commit()
    }

    private func fade(_ layer: CALayer, from: Float, to: Float, times: [NSNumber], duration: TimeInterval) {
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [from, from, to, to]
        animation.keyTimes = times
        animation.duration = duration
        animation.timingFunctions = [.init(name: .linear), .init(name: .easeInEaseOut), .init(name: .linear)]
        layer.add(animation, forKey: "opacity")
    }

    private static func image(of view: NSView) -> CGImage? {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap.cgImage
    }
}
