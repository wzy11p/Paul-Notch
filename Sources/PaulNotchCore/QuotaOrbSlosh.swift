import AppKit

/// Event-anchored analytic response, not a frame-by-frame fluid simulation.
/// Positive mouse acceleration makes the liquid lag toward the left.
struct QuotaOrbSlosh {
    struct Sample {
        var slope = 0.0
        var velocity = 0.0
    }
    private var anchor = Sample()
    private var anchorTime = 0.0
    private var input: (x: Double, time: Double, velocity: Double)?

    func sample(at time: Double) -> Sample {
        guard time.isFinite else { return Sample() }
        let t = max(0, time - anchorTime)
        guard t < 2 else { return Sample() }
        let decay = 3.8, frequency = 10.5
        let b = (anchor.velocity + decay * anchor.slope) / frequency
        let cosine = cos(frequency * t), sine = sin(frequency * t), attenuation = exp(-decay * t)
        let position = attenuation * (anchor.slope * cosine + b * sine)
        let velocity = attenuation * (-decay * (anchor.slope * cosine + b * sine)
            + frequency * (-anchor.slope * sine + b * cosine))
        // End at exact rest without a compositor-removal snap.
        let u = min(1, max(0, (t - 1.6) / 0.4))
        let taper = 1 - u * u * (3 - 2 * u)
        let derivative = u > 0 ? -6 * u * (1 - u) / 0.4 : 0
        return Sample(slope: position * taper, velocity: velocity * taper + position * derivative)
    }

    mutating func begin(x: Double, at time: Double) {
        guard x.isFinite, time.isFinite else { cancel(); return }
        input = (x, time, 0)
    }
    @discardableResult mutating func move(x: Double, at time: Double) -> Bool {
        guard x.isFinite, time.isFinite, let previous = input else { return false }
        let dt = time - previous.time
        guard dt >= 0.004 else { return false }
        guard dt <= 0.25 else { input = (x, time, 0); return false }
        let velocity = min(1800, max(-1800, (x - previous.x) / dt))
        impulse(deltaVelocity: velocity - previous.velocity, at: time)
        input = (x, time, velocity)
        return true
    }
    @discardableResult mutating func end(at time: Double) -> Bool {
        guard time.isFinite, let previous = input else { return false }
        // A mouse-up after resting is not a fresh braking impulse.
        if time >= previous.time, time - previous.time <= 0.25 {
            impulse(deltaVelocity: -previous.velocity, at: time)
        }
        input = nil
        return true
    }
    mutating func cancel() { anchor = Sample(); anchorTime = 0; input = nil }
    private mutating func impulse(deltaVelocity: Double, at time: Double) {
        let current = sample(at: time)
        anchor = Sample(slope: min(0.30, max(-0.30, current.slope)),
            velocity: min(2.4, max(-2.4, current.velocity - deltaVelocity / 78 * 0.22)))
        anchorTime = time
    }
}

/// Native input -> native compositor. No @Published per-pointer updates,
/// global mouse observer, retained window or additional animation clock.
@MainActor final class QuotaOrbMotionRelay {
    weak var renderer: QuotaLiquidOrbView?
    func begin(x: CGFloat, at time: TimeInterval) { renderer?.beginDrag(x: Double(x), at: time) }
    func move(x: CGFloat, at time: TimeInterval) { renderer?.moveDrag(x: Double(x), at: time) }
    func end(at time: TimeInterval) { renderer?.endDrag(at: time) }
    func cancel() { renderer?.cancelSlosh() }
}
