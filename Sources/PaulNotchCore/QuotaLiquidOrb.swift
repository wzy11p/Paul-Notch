import AppKit
import SwiftUI
import QuartzCore

/// A waterline is meaningful only for an exact current percentage. Bounds,
/// unlimited plans and money must not acquire an invented numeric fill.
struct QuotaLiquidLevel: Equatable {
    let fraction: Double?
    init(value: QuotaOverviewValue?) {
        fraction = value?.fraction
    }
    func animates(visible: Bool, reducedMotion: Bool, lowPower: Bool, awake: Bool) -> Bool {
        guard let fraction else { return false }
        return fraction > 0 && fraction < 1 && visible && !reducedMotion && !lowPower && awake
    }

    /// Three identical periods cover the clipped disc while the mask translates
    /// by one diameter. The end pose equals the start: no frame loop or seam.
    func wavePath(diameter: CGFloat, phase: CGFloat, amplitude: CGFloat) -> CGPath {
        let path = CGMutablePath()
        guard let fraction, fraction > 0, diameter > 0 else { return path }
        let width = diameter * 3
        if fraction == 1 { path.addRect(CGRect(x: 0, y: -diameter, width: width, height: diameter * 2)); return path }
        let waterline = diameter * fraction
        let height = min(amplitude, waterline * 0.35, (diameter - waterline) * 0.35)
        // Overscan below the visible disc keeps a tilted mask from cutting
        // an empty wedge out of the liquid at its bottom corners.
        path.move(to: CGPoint(x: 0, y: -diameter))
        for index in 0...96 {
            let x = width * CGFloat(index) / 96
            path.addLine(to: CGPoint(x: x, y: waterline + sin(x / diameter * .pi * 2 + phase) * height))
        }
        path.addLine(to: CGPoint(x: width, y: -diameter)); path.closeSubpath()
        return path
    }
}

struct QuotaLiquidOrb: NSViewRepresentable {
    let value: QuotaOverviewValue?
    let reduceMotion: Bool
    var motion: QuotaOrbMotionRelay? = nil
    func makeNSView(context: Context) -> QuotaLiquidOrbView { QuotaLiquidOrbView(frame: .zero) }
    func updateNSView(_ view: QuotaLiquidOrbView, context: Context) {
        motion?.renderer = view
        view.configure(level: QuotaLiquidLevel(value: value), reducedMotion: reduceMotion)
    }
    static func dismantleNSView(_ view: QuotaLiquidOrbView, coordinator: ()) { view.stop() }
}

/// One native glass backdrop. Finite particle-water motion updates a tiny
/// alpha mask at 30 Hz; once flat, only four native bubbles and two soft currents
/// animate in the compositor. Hidden/sleep/reduced-motion states stop both.
@MainActor final class QuotaLiquidOrbView: NSView {
    private let glass = NSVisualEffectView()
    private let coating = NSView()
    private let orb = CALayer()
    private let backdrop = CAGradientLayer()
    private let rearLiquid = CAGradientLayer()
    private let frontLiquid = CAGradientLayer()
    private let rearMask = CAShapeLayer()
    private let frontMask = CAShapeLayer()
    private let rearSurface = CALayer()
    private let frontSurface = CALayer()
    private let cyanCurrent = CAGradientLayer()
    private let violetCurrent = CAGradientLayer()
    private let bubbles = (0..<4).map { _ in CAShapeLayer() }
    private let gloss = CAGradientLayer()
    private let reflection = CAGradientLayer()
    private let depth = CAGradientLayer()
    private let rim = CAShapeLayer()
    private var level = QuotaLiquidLevel(value: nil)
    private var reducedMotion = false
    private var awake = true
    private var stopped = false
    private let epoch = CACurrentMediaTime()
    private var renderedSize: CGFloat = 0
    private var renderedBounds = CGRect.zero
    private var renderedLevel = QuotaLiquidLevel(value: nil)
    private var renderedTransparency: Bool?
    private let slosh = QuotaOrbSlosh()
    private var simulationTimer: Timer?
    var isSimulating: Bool { simulationTimer != nil }
    var waterFlatBlend: Double { slosh.flatBlend }
    private var windowVisibilityObservation: NSKeyValueObservation?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.appearance = NSAppearance(named: .aqua)
        // Slightly stronger system frost softens background detail without
        // making the accepted light glass a dark HUD or adding another blur.
        glass.alphaValue = 0.28
        glass.wantsLayer = true
        glass.layer?.masksToBounds = true
        addSubview(glass, positioned: .below, relativeTo: nil)
        coating.wantsLayer = true
        coating.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(coating, positioned: .above, relativeTo: glass)
        orb.name = "quota-liquid-orb"
        orb.zPosition = 1
        orb.masksToBounds = true
        orb.shadowOpacity = 0
        coating.layer?.addSublayer(orb)
        backdrop.type = .radial
        backdrop.locations = [0, 0.65, 1]
        backdrop.startPoint = CGPoint(x: 0.25, y: 0.85); backdrop.endPoint = CGPoint(x: 1, y: 0)
        rearLiquid.startPoint = CGPoint(x: 0, y: 1); rearLiquid.endPoint = CGPoint(x: 1, y: 0)
        frontLiquid.locations = [0, 0.48, 1]
        frontLiquid.startPoint = CGPoint(x: 0, y: 1); frontLiquid.endPoint = CGPoint(x: 1, y: 0)
        rearMask.name = "quota-liquid-rear-mask"; frontMask.name = "quota-liquid-front-mask"
        rearSurface.name = "quota-liquid-rear-surface"; frontSurface.name = "quota-liquid-front-surface"
        rearSurface.addSublayer(rearMask); frontSurface.addSublayer(frontMask)
        rearLiquid.mask = rearSurface; frontLiquid.mask = frontSurface
        // Both refractions share the front liquid's *real* quota mask, so they
        // cannot appear in the empty glass, including during a quota retarget.
        for (current, tint) in [(cyanCurrent, NSColor(srgbRed: 0.42, green: 0.94, blue: 1, alpha: 0.22)),
                                (violetCurrent, NSColor(srgbRed: 0.83, green: 0.58, blue: 1, alpha: 0.18))] {
            current.type = .radial
            current.colors = [tint.cgColor, tint.withAlphaComponent(0.08).cgColor, NSColor.clear.cgColor]
            current.locations = [0, 0.45, 1]
            current.startPoint = CGPoint(x: 0.5, y: 0.5); current.endPoint = CGPoint(x: 1, y: 1)
            frontLiquid.addSublayer(current)
        }
        for (index, bubble) in bubbles.enumerated() {
            bubble.name = "quota-liquid-bubble-\(index)"
            bubble.fillColor = NSColor.white.withAlphaComponent(0.12).cgColor
            bubble.strokeColor = NSColor(srgbRed: 0.72, green: 0.95, blue: 1, alpha: 0.54).cgColor
            bubble.lineWidth = 0.45
            bubble.opacity = 0
            frontLiquid.addSublayer(bubble)
        }
        gloss.type = .radial
        gloss.colors = [NSColor.white.withAlphaComponent(0.18).cgColor,
                        NSColor.white.withAlphaComponent(0.04).cgColor, NSColor.clear.cgColor]
        gloss.locations = [0, 0.55, 1]
        gloss.startPoint = CGPoint(x: 0.20, y: 0.9); gloss.endPoint = CGPoint(x: 0.95, y: 0.15)
        reflection.type = .radial
        reflection.colors = [NSColor.white.withAlphaComponent(0.72).cgColor,
                             NSColor.white.withAlphaComponent(0.14).cgColor, NSColor.clear.cgColor]
        reflection.locations = [0, 0.45, 1]
        reflection.startPoint = CGPoint(x: 0.5, y: 0.5); reflection.endPoint = CGPoint(x: 1, y: 1)
        reflection.transform = CATransform3DMakeRotation(.pi / 7, 0, 0, 1)
        depth.type = .radial
        depth.colors = [NSColor.clear.cgColor, NSColor.clear.cgColor, NSColor.black.withAlphaComponent(0.10).cgColor]
        depth.locations = [0, 0.56, 1]
        depth.startPoint = CGPoint(x: 0.44, y: 0.60); depth.endPoint = CGPoint(x: 1.02, y: 0.10)
        rim.fillColor = NSColor.clear.cgColor
        rim.strokeColor = NSColor.white.withAlphaComponent(0.36).cgColor
        rim.lineWidth = 0.6
        [backdrop, rearLiquid, frontLiquid, depth, gloss, reflection, rim].forEach(orb.addSublayer)
        updateMaterial()
        setAccessibilityElement(false)
        NotificationCenter.default.addObserver(self, selector: #selector(environmentChanged),
            name: .NSProcessInfoPowerStateDidChange, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(environmentChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep),
            name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(level: QuotaLiquidLevel, reducedMotion: Bool) {
        guard !stopped else { return }
        self.level = level; self.reducedMotion = reducedMotion
        slosh.configure(fraction: level.fraction)
        updateMaterial()
        updateGeometry()
        updateMotion()
    }
    override func layout() { super.layout(); updateGeometry(); updateMotion() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowVisibilityObservation = nil
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        if let window, !stopped {
            NotificationCenter.default.addObserver(self, selector: #selector(environmentChanged),
                name: NSWindow.didChangeOcclusionStateNotification, object: window)
            // orderOut can leave the previous occlusion bit unchanged. Track
            // visibility independently so a hidden window always stops work.
            windowVisibilityObservation = window.observe(\.isVisible, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateMotion() }
            }
        }
        updateMotion()
    }
    override func viewDidHide() { super.viewDidHide(); updateMotion() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateMotion() }

    func stop() {
        stopped = true
        windowVisibilityObservation = nil
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        stopMotion()
    }
    @objc private func environmentChanged(_ note: Notification) { updateMaterial(); updateMotion() }
    @objc private func willSleep(_ note: Notification) { awake = false; updateMotion() }
    @objc private func didWake(_ note: Notification) { awake = true; updateMotion() }

    private var motionAllowed: Bool {
        level.animates(visible: window?.isVisible == true && window?.occlusionState.contains(.visible) == true &&
            !isHiddenOrHasHiddenAncestor && renderedSize > 0 && !stopped,
            reducedMotion: reducedMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, awake: awake)
    }

    private func updateGeometry() {
        let diameter = min(bounds.width, bounds.height)
        guard diameter > 0, bounds != renderedBounds || level != renderedLevel else { return }
        let resize = bounds != renderedBounds
        if resize { cancelSlosh(); stopMotion() }
        if level != renderedLevel { bubbles.forEach { $0.removeAnimation(forKey: "quota-liquid-bubble") } }
        let diameterChanged = diameter != renderedSize
        renderedSize = diameter; renderedBounds = bounds; renderedLevel = level
        CATransaction.begin(); CATransaction.setDisableActions(true)
        coating.frame = bounds
        orb.frame = CGRect(x: coating.bounds.midX - diameter / 2, y: coating.bounds.midY - diameter / 2,
                           width: diameter, height: diameter)
        orb.cornerRadius = diameter / 2
        glass.frame = CGRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2,
                             width: diameter, height: diameter)
        glass.layer?.cornerRadius = diameter / 2
        if diameterChanged {
            glass.maskImage = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
                NSColor.white.setFill(); NSBezierPath(ovalIn: rect).fill(); return true
            }
        }
        for surface in [backdrop, rearLiquid, frontLiquid, depth, gloss, rearSurface, frontSurface, rearMask, frontMask] {
            surface.frame = orb.bounds
        }
        cyanCurrent.bounds = CGRect(x: 0, y: 0, width: diameter * 1.02, height: diameter * 0.62)
        cyanCurrent.position = CGPoint(x: diameter * 0.35, y: diameter * 0.30)
        violetCurrent.bounds = CGRect(x: 0, y: 0, width: diameter * 0.8, height: diameter * 0.72)
        violetCurrent.position = CGPoint(x: diameter * 0.73, y: diameter * 0.22)
        reflection.bounds = CGRect(x: 0, y: 0, width: diameter * 0.37, height: diameter * 0.13)
        reflection.position = CGPoint(x: diameter * 0.31, y: diameter * 0.85)
        let scale = window?.backingScaleFactor ?? 2
        [orb, backdrop, rearLiquid, frontLiquid, rearMask, frontMask, rearSurface, frontSurface, cyanCurrent, violetCurrent,
         depth, gloss, reflection, rim].forEach { $0.contentsScale = scale }
        for (index, bubble) in bubbles.enumerated() {
            let radius = diameter * [0.012, 0.016, 0.010, 0.014][index]
            bubble.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
            bubble.path = CGPath(ellipseIn: bubble.bounds, transform: nil)
            bubble.contentsScale = scale
        }
        rim.frame = orb.bounds
        rim.path = CGPath(ellipseIn: orb.bounds.insetBy(dx: 0.4, dy: 0.4), transform: nil)
        rearLiquid.opacity = level.fraction == nil || level.fraction == 0 ? 0 : 1
        frontLiquid.opacity = rearLiquid.opacity
        CATransaction.commit()
        renderWater()
    }

    private func renderWater() {
        if slosh.flatBlend == 1 {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            for mask in [rearMask, frontMask] {
                mask.contents = nil
                mask.path = level.wavePath(diameter: renderedSize, phase: 0, amplitude: 0)
            }
            CATransaction.commit()
            return
        }
        let n = QuotaParticleLiquid.fieldSize
        let data = Data(slosh.maskRGBA())
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        rearMask.path = nil; frontMask.path = nil
        rearMask.contents = image; frontMask.contents = image
        CATransaction.commit()
    }

    private func updateMotion() {
        guard motionAllowed else { stopMotion(); return }
        for (index, bubble) in bubbles.enumerated() {
            guard bubble.animation(forKey: "quota-liquid-bubble") == nil else { continue }
            let d = renderedSize
            let x = d * [0.28, 0.46, 0.64, 0.75][index]
            let height = d * max(0.12, level.fraction ?? 0)
            let rise = CAKeyframeAnimation(keyPath: "position")
            rise.values = [CGPoint(x: x, y: d * 0.05),
                CGPoint(x: x + d * 0.025, y: height * 0.4),
                CGPoint(x: x - d * 0.018, y: height * 0.72),
                CGPoint(x: x + d * 0.01, y: height + d * 0.02)].map { NSValue(point: $0) }
            rise.keyTimes = [0, 0.35, 0.7, 1]
            rise.calculationMode = .cubic
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 0.8, 0.65, 0]
            fade.keyTimes = [0, 0.14, 0.80, 1]
            let group = CAAnimationGroup()
            group.duration = [4.8, 6.1, 5.5, 7.0][index]
            rise.duration = group.duration; fade.duration = group.duration
            group.animations = [rise, fade]; group.repeatCount = .infinity
            let now = CACurrentMediaTime()
            group.beginTime = bubble.convertTime(now, from: nil) -
                (now - epoch + Double(index) * 1.37).truncatingRemainder(dividingBy: group.duration)
            bubble.add(group, forKey: "quota-liquid-bubble")
        }
        startSimulationIfNeeded()
        for (current, duration, direction) in [(cyanCurrent, 8.5, 1.0), (violetCurrent, 11.0, -1.0)] {
            guard current.animation(forKey: "quota-liquid-current") == nil else { continue }
            let origin = current.position, dx = renderedSize * 0.13 * direction, dy = renderedSize * 0.10
            let animation = CAKeyframeAnimation(keyPath: "position")
            animation.values = [origin, CGPoint(x: origin.x + dx, y: origin.y + dy),
                CGPoint(x: origin.x, y: origin.y + dy * 1.5), CGPoint(x: origin.x - dx, y: origin.y + dy * 0.5), origin]
                .map { NSValue(point: $0) }
            animation.keyTimes = [0, 0.25, 0.5, 0.75, 1]
            animation.calculationMode = .cubic
            animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 4)
            animation.duration = duration; animation.repeatCount = .infinity
            let now = CACurrentMediaTime()
            animation.beginTime = current.convertTime(now, from: nil) - (now - epoch).truncatingRemainder(dividingBy: duration)
            current.add(animation, forKey: "quota-liquid-current")
        }
    }
    private func stopMotion() {
        simulationTimer?.invalidate(); simulationTimer = nil
        slosh.suspend()
        [cyanCurrent, violetCurrent].forEach { $0.removeAnimation(forKey: "quota-liquid-current") }
        bubbles.forEach { $0.removeAnimation(forKey: "quota-liquid-bubble") }
        if reducedMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ||
            ProcessInfo.processInfo.isLowPowerModeEnabled {
            slosh.cancel(); renderWater()
        }
    }
    private func startSimulationIfNeeded() {
        guard motionAllowed, slosh.isEvolving, simulationTimer == nil else { return }
        // Common mode includes native mouse tracking. The weak callback also
        // invalidates itself if teardown releases the view before its next tick.
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
            let keepRunning = MainActor.assumeIsolated {
                guard let self else { return false }
                guard self.motionAllowed else { self.stopMotion(); return false }
                self.slosh.advance(to: CACurrentMediaTime())
                self.renderWater()
                if !self.slosh.isEvolving {
                    self.simulationTimer = nil
                }
                return self.slosh.isEvolving
            }
            if !keepRunning { timer.invalidate() }
        }
        timer.tolerance = 0.003
        simulationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func updateMaterial() {
        let opaque = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        guard renderedTransparency != opaque else { return }
        renderedTransparency = opaque
        CATransaction.begin(); CATransaction.setDisableActions(true)
        glass.isHidden = opaque
        backdrop.colors = [color(0.24, 0.28, 0.36, opaque ? 1 : 0.05),
            color(0.095, 0.12, 0.19, opaque ? 1 : 0.04), color(0.04, 0.055, 0.10, opaque ? 1 : 0.08)]
        // Lift pigment luminance rather than stacking more opacity. Cyan-blue
        // water stays visible over dark windows, with the same transmission
        // and bounded masks; the reading support is behind this layer.
        rearLiquid.colors = [color(0.10, 0.75, 1, 0.12), color(0.32, 0.52, 0.98, 0.14)]
        frontLiquid.colors = [color(0.10, 0.72, 1, 0.28), color(0.12, 0.60, 0.98, 0.30),
            color(0.34, 0.52, 0.98, 0.34)]
        CATransaction.commit()
    }
    private func normalized(_ point: CGPoint) -> SIMD2<Double> {
        // AppKit screen coordinates are y-up; the water solver is y-down.
        SIMD2(Double(point.x / max(1, renderedSize)), -Double(point.y / max(1, renderedSize)))
    }
    func beginDrag(position: CGPoint, at time: Double) {
        guard motionAllowed else { return }
        slosh.begin(position: normalized(position), at: time)
    }
    func moveDrag(position: CGPoint, at time: Double) {
        guard motionAllowed else { return }
        slosh.move(position: normalized(position), at: time)
        startSimulationIfNeeded()
    }
    func endDrag(at time: Double) {
        guard motionAllowed else { return }
        slosh.end(at: time)
        startSimulationIfNeeded()
    }
    func cancelSlosh() {
        simulationTimer?.invalidate(); simulationTimer = nil
        slosh.cancel()
        if renderedSize > 0 { renderWater() }
    }
    private func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha).cgColor
    }
}
