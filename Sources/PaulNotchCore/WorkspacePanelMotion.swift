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
    private var bubbleMorph: WorkspaceBubbleMorph?
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
        invalidateCallbacks()
        bubbleMorph?.finish()
        bubbleMorph = nil
    }

    private func invalidateCallbacks() {
        revision &+= 1
        fallback?.cancel()
        fallback = nil
        direction = nil
    }

    /// The detached workspace contracts to its saved circle, with the same
    /// revision guard as the hardware drawer. Retargeting cannot finish an old close.
    func morph(_ window: NSWindow, to frame: NSRect, direction: Direction, bubbleView: NSView? = nil,
               reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
               completion: @escaping @MainActor () -> Void) {
        // Retarget the existing presentation layers, not a new endpoint image.
        // General cancellation still releases the temporary raster immediately.
        invalidateCallbacks()
        self.direction = direction
        let ticket = revision
        let duration: TimeInterval = reduceMotion ? 0 : (direction == .opening ? 0.38 : 0.32)
        if !reduceMotion, bubbleMorph == nil, let container = window.contentView as? WorkspacePanelContainer {
            let expanded = direction == .opening ? frame : window.frame
            let bubble = direction == .opening ? window.frame : frame
            bubbleMorph = WorkspaceBubbleMorph(window: window, container: container,
                expandedFrame: expanded, bubbleFrame: bubble, bubbleView: bubbleView, opening: direction == .opening)
        }
        let finish: @MainActor () -> Void = { [weak self, weak window] in
            guard let self, let window, self.revision == ticket, self.direction != nil else { return }
            self.fallback?.cancel(); self.fallback = nil; self.direction = nil
            self.bubbleMorph?.finish(); self.bubbleMorph = nil
            window.setFrame(frame, display: false)
            completion()
        }
        if reduceMotion { finish(); return }
        fallback = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(duration + 0.25)) } catch { return }
            finish()
        }
        if let bubbleMorph {
            bubbleMorph.animate(opening: direction == .opening, duration: duration)
            // Core Animation owns all frames. One bounded task settles the native
            // endpoint; there is no app-driven per-frame timer or window resize.
            fallback?.cancel()
            fallback = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(duration)) } catch { return }
                finish()
            }
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            window.animator().setFrame(frame, display: true)
        } completionHandler: { Task { @MainActor in finish() } }
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
