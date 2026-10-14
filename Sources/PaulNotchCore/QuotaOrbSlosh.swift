import Foundation
import simd

/// Accepted 2D particle water, driven only while a gesture settles. The final
/// density contour eases into the exact quota height; idle bubbles are separate
/// compositor layers, never a reason to keep this solver awake.
final class QuotaOrbSlosh {
    let liquid = QuotaParticleLiquid(percent: 0)
    private(set) var flatBlend = 1.0
    private var fraction: Double?
    private var clock: Double?
    private var input: (position: SIMD2<Double>, time: Double, velocity: SIMD2<Double>)?
    private var settleTime = 0.0
    private var unforcedTime = 0.0
    private var fieldDirty = false
    private var reentryBlend = 0.0
    private var reentryTime = 0.0
    var isEvolving: Bool { liquid.isActive || flatBlend < 1 }

    func configure(fraction value: Double?) {
        let next = value.flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
        guard next != fraction else { return }
        let wasActive = liquid.isActive
        let mean = liquid.particles.reduce(SIMD2<Float>.zero) { $0 + SIMD2($1.z, $1.w) } /
            Float(max(1, liquid.particles.count))
        fraction = next
        liquid.reset(percent: Float(next ?? 0) * 100)
        flatBlend = 1; settleTime = 0; unforcedTime = 0; fieldDirty = false
        reentryBlend = 0; reentryTime = 0
        if wasActive, let next, next > 0, next < 1 { apply(mean) }
        // Keep the native input anchor across an actual source refresh.
    }

    func begin(position: SIMD2<Double>, at time: Double) {
        guard valid(position), time.isFinite else { suspend(); return }
        advance(to: time)
        input = (position, time, .zero)
    }
    func move(position: SIMD2<Double>, at time: Double) {
        guard let previous = input, valid(position), time.isFinite else { return }
        let dt = time - previous.time
        guard dt >= 0.002 else { return }
        advance(to: time)
        guard dt <= 0.25 else { input = (position, time, .zero); return }
        var velocity = (position - previous.position) / dt
        velocity /= max(1, simd_length(velocity) / 12)
        apply(SIMD2<Float>((previous.velocity - velocity) * 0.38))
        input = (position, time, velocity)
    }
    func end(at time: Double) {
        defer { input = nil }
        guard let previous = input, time.isFinite, time >= previous.time else { return }
        advance(to: time)
        if time - previous.time <= 0.25 { apply(SIMD2<Float>(previous.velocity * 0.38)) }
    }
    private func apply(_ impulse: SIMD2<Float>) {
        guard impulse.x.isFinite, impulse.y.isFinite, simd_length_squared(impulse) > 0.0000001 else { return }
        if !liquid.isActive {
            reentryBlend = flatBlend < 1 ? flatBlend : 0
            reentryTime = 0
        }
        if flatBlend == 1 { liquid.reset(percent: Float(fraction ?? 0) * 100) }
        liquid.impulse(impulse)
        if liquid.isActive {
            if reentryBlend == 0 { flatBlend = 0 }
            settleTime = 0; unforcedTime = 0; fieldDirty = true
        }
    }
    func advance(to time: Double) {
        guard time.isFinite else { return }
        guard let start = clock else { clock = time; return }
        guard time >= start else { return }
        guard isEvolving else { clock = time; return }
        let elapsed = min(time - start, QuotaParticleLiquid.dt * 8)
        let steps = min(8, Int((elapsed + 1e-9) / QuotaParticleLiquid.dt))
        let simulated = Double(steps) * QuotaParticleLiquid.dt
        if liquid.isActive {
            for _ in 0..<steps { liquid.step() }
            fieldDirty = steps > 0 || fieldDirty
            unforcedTime += simulated
            if reentryBlend > 0 {
                reentryTime += simulated
                let t = min(1, reentryTime / 0.16)
                flatBlend = reentryBlend * (1 - t * t * (3 - 2 * t))
                if t == 1 { reentryBlend = 0 }
            }
            // Coarse-grid pressure noise can never keep this widget awake.
            if unforcedTime >= 12 { liquid.stop() }
        } else {
            settleTime += simulated
            let t = min(1, settleTime / 1.8)
            flatBlend = t * t * (3 - 2 * t)
        }
        clock = time - max(0, elapsed - simulated)
    }
    /// Hide/sleep cancels input but preserves momentum and the gradual flatten.
    /// The first visible frame anchors a fresh clock, with no hidden catch-up.
    func suspend() { input = nil; clock = nil }
    func cancel() {
        suspend()
        liquid.reset(percent: Float(fraction ?? 0) * 100)
        flatBlend = 1; settleTime = 0; unforcedTime = 0; fieldDirty = false
        reentryBlend = 0; reentryTime = 0
    }
    private func valid(_ p: SIMD2<Double>) -> Bool { p.x.isFinite && p.y.isFinite }

    /// Small CPU alpha image, uploaded only during finite settling. Row zero
    /// is the top of the circle. Stable text remains outside this visual mask.
    func maskRGBA() -> [UInt8] {
        if fieldDirty { liquid.rebuildField(); fieldDirty = false }
        let n = QuotaParticleLiquid.fieldSize
        var rgba = [UInt8](repeating: 255, count: n * n * 4)
        let amount = Float(fraction ?? 0)
        let surface = 0.5 + (0.5 - amount) * 2 * QuotaParticleLiquid.radius
        for y in 0..<n { for x in 0..<n {
            let px = 0.5 + ((Float(x) + 0.5) / Float(n) - 0.5) * 2 * QuotaParticleLiquid.radius
            let py = 0.5 + ((Float(y) + 0.5) / Float(n) - 0.5) * 2 * QuotaParticleLiquid.radius
            let gx = px * Float(n) - 0.5, gy = py * Float(n) - 0.5
            let ix = min(n - 2, max(0, Int(floor(gx))))
            let iy = min(n - 2, max(0, Int(floor(gy))))
            let tx = min(1, max(0, gx - Float(ix))), ty = min(1, max(0, gy - Float(iy)))
            let a = liquid.field[iy * n + ix].x * (1 - tx) + liquid.field[iy * n + ix + 1].x * tx
            let b = liquid.field[(iy + 1) * n + ix].x * (1 - tx) + liquid.field[(iy + 1) * n + ix + 1].x * tx
            let particleDistance = (1 - a * (1 - ty) - b * ty) * 0.015
            let flatDistance = surface - py
            let distance = particleDistance * Float(1 - flatBlend) + flatDistance * Float(flatBlend)
            let t = min(1, max(0, (distance + 0.006) / 0.012))
            let alpha: Float = amount <= 0 ? 0 : amount >= 1 ? 1 : 1 - t * t * (3 - 2 * t)
            rgba[(y * n + x) * 4 + 3] = UInt8((alpha * 255).rounded())
        } }
        return rgba
    }
}

#if !QUOTA_WATER_CHECKS
import AppKit

/// Existing native drag input, no global mouse hook or observable frame state.
@MainActor final class QuotaOrbMotionRelay {
    weak var renderer: QuotaLiquidOrbView?
    func begin(position: CGPoint, at time: TimeInterval) { renderer?.beginDrag(position: position, at: time) }
    func move(position: CGPoint, at time: TimeInterval) { renderer?.moveDrag(position: position, at: time) }
    func end(at time: TimeInterval) { renderer?.endDrag(at: time) }
    func cancel() { renderer?.cancelSlosh() }
}
#endif
