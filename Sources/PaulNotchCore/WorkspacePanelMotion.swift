import AppKit
import QuartzCore

/// Native adaptation of TO-DO Panel's collapse generation/watchdog mechanism
/// (v1.1.2, main.js). MIT attribution: THIRD_PARTY_NOTICES.md.
/// AppKit owns interpolation. A new intent retargets the existing animation;
/// only the latest completion may perform window lifecycle side effects.
@MainActor
final class WorkspacePanelMotion {
    enum Direction { case opening, closing }
    typealias Animation = @MainActor (NSView, NSPoint, TimeInterval, CAMediaTimingFunction,
                                     @escaping @Sendable () -> Void) -> Void

    private(set) var direction: Direction?
    private var revision: UInt64 = 0
    private var fallback: Task<Void, Never>?
    private let animation: Animation

    init(animation: @escaping Animation = WorkspacePanelMotion.appKitAnimation) {
        self.animation = animation
    }

    func move(_ view: NSView, to origin: NSPoint, direction: Direction,
              reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              completion: @escaping @MainActor () -> Void) {
        cancel()
        self.direction = direction
        let ticket = revision
        let duration: TimeInterval = reduceMotion ? 0 : (direction == .opening ? 0.26 : 0.18)
        let timing = direction == .opening
            ? CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            : CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)

        // Reduced motion must settle synchronously, not wait for an animation
        // completion that may never arrive for a zero-duration transaction.
        if reduceMotion {
            animation(view, origin, 0, timing, {})
            finish(ticket, view: view, origin: origin, completion: completion)
            return
        }

        fallback = Task { @MainActor [weak self, weak view] in
            do { try await Task.sleep(for: .seconds(duration + 0.25)) }
            catch { return }
            guard let self, let view, self.revision == ticket, self.direction != nil else { return }
            self.animation(view, origin, 0, timing, {})
            self.finish(ticket, view: view, origin: origin, completion: completion)
        }
        animation(view, origin, duration, timing) { [weak self, weak view] in
            Task { @MainActor in
                guard let self, let view else { return }
                self.finish(ticket, view: view, origin: origin, completion: completion)
            }
        }
    }

    func cancel() {
        revision &+= 1
        fallback?.cancel()
        fallback = nil
        direction = nil
    }

    private func finish(_ ticket: UInt64, view: NSView, origin: NSPoint,
                        completion: @MainActor () -> Void) {
        guard revision == ticket, direction != nil else { return }
        fallback?.cancel()
        fallback = nil
        direction = nil
        view.setFrameOrigin(origin)
        completion()
    }

    private static func appKitAnimation(_ view: NSView, _ origin: NSPoint, _ duration: TimeInterval,
                                       _ timing: CAMediaTimingFunction,
                                       _ completion: @escaping @Sendable () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = timing
            view.animator().setFrameOrigin(origin)
        } completionHandler: { completion() }
    }
}
