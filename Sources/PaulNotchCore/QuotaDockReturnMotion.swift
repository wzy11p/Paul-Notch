import AppKit
import QuartzCore

/// One short compositor flight in the existing panel. The live 92pt content
/// keeps its viewport; there is no snapshot of other windows or frame timer.
@MainActor final class QuotaDockReturnMotion {
    private var flight: Flight?
    private var completion: (@MainActor () -> Void)?
    private var arrivalTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var observations: [(NotificationCenter, NSObjectProtocol)] = []
    private var visibility: NSKeyValueObservation?
    var isRunning: Bool { flight != nil }

    func start(_ window: NSWindow, to destination: NSRect,
               reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
               completion: @escaping @MainActor () -> Void) {
        guard !isRunning else { return }
        guard !reduceMotion, !ProcessInfo.processInfo.isLowPowerModeEnabled,
              window.isVisible, let content = window.contentView else { completion(); return }
        generation &+= 1
        let ticket = generation
        let distance = hypot(window.frame.midX - destination.midX, window.frame.midY - destination.midY)
        let duration = min(0.52, max(0.28, 0.30 + distance / 2500))
        self.completion = completion
        flight = Flight(window: window, content: content, destination: destination, duration: duration)
        arrivalTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(duration)) } catch { return }
            guard let self, self.generation == ticket else { return }
            self.finishImmediately()
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification, finish: false)
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidResignActiveNotification, finish: false)
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification, finish: true)
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, finish: true)
        observe(NotificationCenter.default, .NSProcessInfoPowerStateDidChange, finish: true)
        visibility = window.observe(\.isVisible, options: [.new]) { [weak self] window, _ in
            MainActor.assumeIsolated { if !window.isVisible { self?.cancel() } }
        }
    }

    /// An explicit open supersedes flight without waiting or losing the click.
    func finishImmediately() {
        guard let flight else { return }
        let done = completion
        clear()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        flight.restore()
        done?()
        CATransaction.commit()
    }

    /// Hide/quit cancels the uncommitted return; saved floating placement stays.
    func cancel() {
        let prior = flight
        clear()
        prior?.restore()
    }

    private func clear() {
        generation &+= 1
        arrivalTask?.cancel(); arrivalTask = nil
        visibility = nil
        for (center, token) in observations { center.removeObserver(token) }
        observations.removeAll()
        flight = nil; completion = nil
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, finish: Bool) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if finish { self?.finishImmediately() } else { self?.cancel() }
            }
        }
        observations.append((center, token))
    }

    @MainActor private final class Flight {
        let window: NSWindow
        let content: NSView
        let source: NSRect
        let autoresizing: NSView.AutoresizingMask
        let ignoresMouse: Bool
        let stage = NSView()
        let carrier = NSView()
        let merge = CALayer()

        init(window: NSWindow, content: NSView, destination: NSRect, duration: TimeInterval) {
            self.window = window; self.content = content; source = window.frame
            autoresizing = content.autoresizingMask; ignoresMouse = window.ignoresMouseEvents
            let union = source.union(destination)
            let start = CGPoint(x: source.midX - union.minX, y: source.midY - union.minY)
            let end = CGPoint(x: destination.midX - union.minX, y: destination.midY - union.minY)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            stage.frame = NSRect(origin: .zero, size: union.size)
            stage.wantsLayer = true; stage.layer?.backgroundColor = NSColor.clear.cgColor
            carrier.wantsLayer = true; carrier.layer?.backgroundColor = NSColor.clear.cgColor
            carrier.frame = NSRect(origin: .zero, size: source.size)
            content.removeFromSuperview()
            content.autoresizingMask = []
            content.frame = NSRect(origin: .zero, size: source.size)
            carrier.addSubview(content); stage.addSubview(carrier)
            window.contentView = stage
            window.setFrame(union, display: false)
            window.ignoresMouseEvents = true // the transparent flight rectangle is never a click barrier
            content.layoutSubtreeIfNeeded()
            let layer = carrier.layer!
            layer.name = "quota-dock-return-flight"
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.bounds = NSRect(origin: .zero, size: source.size)
            layer.position = start
            merge.name = "quota-dock-return-merge"
            merge.backgroundColor = NSColor.black.cgColor
            merge.cornerRadius = min(16, destination.height / 2)
            merge.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            merge.cornerCurve = .continuous
            merge.position = end; merge.bounds = NSRect(origin: .zero, size: destination.size)
            merge.opacity = 0
            stage.layer?.insertSublayer(merge, at: 0)
            CATransaction.commit()

            var positions: [NSValue] = [], transforms: [NSValue] = []
            var opacities: [NSNumber] = [], mergeOpacity: [NSNumber] = [], mergeBounds: [NSValue] = []
            for index in 0...40 {
                let p = CGFloat(index) / 40
                let travel = Self.ease(min(1, p / 0.88))
                // A shallow, bounded arc rises first; source/target are frozen
                // at commitment so foreground changes cannot yank the route.
                let bend = min(32, abs(end.x - start.x) * 0.08) * sin(.pi * travel)
                let position = CGPoint(x: start.x + (end.x - start.x) * travel,
                                       y: start.y + (end.y - start.y) * travel + bend)
                let absorb = Self.ease(max(0, (p - 0.70) / 0.30))
                let stretch = sin(.pi * min(1, p / 0.70)) * (1 - absorb)
                positions.append(NSValue(point: position))
                transforms.append(NSValue(caTransform3D: CATransform3DMakeScale(
                    (1 - 0.045 * stretch) * (1 - 0.82 * absorb),
                    (1 + 0.09 * stretch) * (1 - 0.90 * absorb), 1)))
                opacities.append(NSNumber(value: Double(1 - Self.ease(max(0, (p - 0.68) / 0.32)))))
                mergeOpacity.append(NSNumber(value: Double(absorb)))
                mergeBounds.append(NSValue(rect: NSRect(x: 0, y: 0,
                    width: 24 + (destination.width - 24) * absorb, height: destination.height)))
            }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.position = end; layer.opacity = 0
            layer.transform = transforms.last!.caTransform3DValue
            merge.opacity = 1
            CATransaction.commit()
            Self.animate(layer, "position", positions, duration)
            Self.animate(layer, "transform", transforms, duration)
            Self.animate(layer, "opacity", opacities, duration)
            Self.animate(merge, "opacity", mergeOpacity, duration)
            Self.animate(merge, "bounds", mergeBounds, duration)
        }

        func restore() {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            carrier.layer?.removeAllAnimations(); merge.removeAllAnimations()
            content.removeFromSuperview()
            window.contentView = content
            window.setFrame(source, display: false)
            content.frame = NSRect(origin: .zero, size: source.size)
            content.autoresizingMask = autoresizing
            window.ignoresMouseEvents = ignoresMouse
            CATransaction.commit()
        }
        private static func ease(_ value: CGFloat) -> CGFloat {
            let t = min(1, max(0, value))
            return t * t * t * (t * (t * 6 - 15) + 10)
        }
        private static func animate(_ layer: CALayer, _ key: String, _ values: [Any], _ duration: TimeInterval) {
            let animation = CAKeyframeAnimation(keyPath: key)
            animation.values = values
            animation.duration = duration
            animation.calculationMode = .linear
            layer.add(animation, forKey: "quota-dock-return-\(key)")
        }
    }
}
