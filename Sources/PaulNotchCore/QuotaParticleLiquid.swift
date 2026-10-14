import Foundation
import simd

// Particle/grid transfers, separation and pressure projection adapted from
// Matthias Müller, Ten Minute Physics, 18-flip.html (MIT), commit
// b5239f60d0a3d0b9b57db0db25a85374ccc84aee. See THIRD_PARTY_NOTICES.md.
// Paul additions: closed circular vessel, bounded native scheduling, sleep,
// field reconstruction and input validation. This is a 2D approximation.
final class QuotaParticleLiquid {
    static let dt: Double = 1.0 / 120
    static let fieldSize = 96
    static let radius: Float = 0.46875
    private static let n = 33
    private static let h: Float = 1 / 32
    private static let r: Float = 0.3 / 32
    private static let bins = 50
    private static let binScale: Float = 1 / (2.2 * r)
    private(set) var particles: [SIMD4<Float>] = []
    private(set) var stepCount = 0
    private(set) var isActive = false
    /// Density, horizontal/vertical velocity, reserved. Reused, never a history.
    private(set) var field = [SIMD4<Float>](repeating: .zero, count: fieldSize * fieldSize)
    private var u = [Float](repeating: 0, count: n * n)
    private var v = [Float](repeating: 0, count: n * n)
    private var wu = [Float](repeating: 0, count: n * n)
    private var wv = [Float](repeating: 0, count: n * n)
    private var oldU = [Float](repeating: 0, count: n * n)
    private var oldV = [Float](repeating: 0, count: n * n)
    private var density = [Float](repeating: 0, count: n * n)
    private var open = [Float](repeating: 0, count: n * n)
    private var kind = [UInt8](repeating: 2, count: n * n) // fluid 0, air 1, solid 2
    private var heads = [Int](repeating: -1, count: bins * bins)
    private var next: [Int] = []
    private var quietSteps = 0
    private var activeSteps = 0
    private var valid = false

    init(percent: Float = 74) { reset(percent: percent) }
    func reset(percent: Float) {
        particles.removeAll(keepingCapacity: true)
        particles.reserveCapacity(2200)
        stepCount = 0; activeSteps = 0; quietSteps = 0; isActive = false
        valid = percent.isFinite && percent > 0 && percent < 100
        for i in field.indices { field[i] = .zero }
        guard valid else { return }
        let spacing = 2 * Self.r, rowHeight = spacing * sqrt(Float(3)) / 2
        let surface = 0.5 + (0.5 - percent / 100) * 2 * Self.radius
        let limit = Self.radius - Self.r
        var row = 0, y: Float = 0.5 + limit
        while y >= surface + Self.r * 0.6 {
            var x: Float = 0.5 - limit + (row % 2 == 0 ? 0 : Self.r)
            while x <= 0.5 + limit {
                if hypot(x - 0.5, y - 0.5) <= limit {
                    particles.append(SIMD4(x, y, 0, 0))
                }
                x += spacing
            }
            y -= rowHeight; row += 1
        }
        next = [Int](repeating: -1, count: particles.count)
        for x in 0..<Self.n { for y in 0..<Self.n {
            let q = SIMD2((Float(x) + 0.5) * Self.h - 0.5, (Float(y) + 0.5) * Self.h - 0.5)
            open[x * Self.n + y] = simd_length(q) < Self.radius && x > 0 && y > 0 &&
                x < Self.n - 1 && y < Self.n - 1 ? 1 : 0
        } }
        rebuildField()
    }

    /// Relative liquid velocity in diameters/second, not a prescribed wave.
    func impulse(_ delta: SIMD2<Float>) {
        guard valid, !particles.isEmpty, delta.x.isFinite, delta.y.isFinite,
              simd_length_squared(delta) > 0.0000001 else { return }
        let bounded = delta / max(1, simd_length(delta) / 2.5)
        for i in particles.indices {
            var p = particles[i]
            let velocity = SIMD2(p.z, p.w) + bounded
            let limited = velocity / max(1, simd_length(velocity) / 3)
            p.z = limited.x; p.w = limited.y; particles[i] = p
        }
        isActive = true; activeSteps = 0; quietSteps = 0
    }

    func stop() {
        isActive = false; quietSteps = 0
        for i in particles.indices { particles[i].z = 0; particles[i].w = 0 }
    }

    func step() {
        guard valid, isActive else { return }
        let dt = Float(Self.dt)
        // Fixed dt and a bounded speed keep displacement below one grid cell.
        let damping = exp(-dt * (activeSteps > 360 ? 2.5 : 0.65))
        for i in particles.indices {
            var p = particles[i]
            p.z *= damping; p.w = p.w * damping + 4.8 * dt
            p.x += p.z * dt; p.y += p.w * dt; particles[i] = p
        }
        separate()
        collide()
        transferToGrid()
        project()
        transferFromGrid()
        collide()
        stepCount += 1; activeSteps += 1
        var energy: Float = 0, maximum: Float = 0
        for p in particles {
            let e = p.z * p.z + p.w * p.w; energy += e; maximum = max(maximum, e)
        }
        // Below subpixel travel per display tick at 78pt. Coarse-grid pressure
        // noise is not useful motion and must not keep a quota widget awake.
        if activeSteps > 100 && energy / Float(max(1, particles.count)) < 0.006 && maximum < 0.16 {
            quietSteps += 1
        } else { quietSteps = 0 }
        if quietSteps >= 48 {
            isActive = false
            for i in particles.indices { particles[i].z = 0; particles[i].w = 0 }
        }
    }

    private func collide() {
        let limit = Self.radius - Self.r
        for i in particles.indices {
            var p = particles[i]
            let q = SIMD2(p.x - 0.5, p.y - 0.5), length = simd_length(q)
            if length > limit {
                let normal = q / length
                p.x = 0.5 + normal.x * limit; p.y = 0.5 + normal.y * limit
                // Lose only the outward component. Tangential momentum runs
                // UP the round wall; gravity returns it. No elastic bounce.
                let outward = max(0, p.z * normal.x + p.w * normal.y)
                p.z -= normal.x * outward; p.w -= normal.y * outward
            }
            let speed = hypot(p.z, p.w)
            if speed > 3 { p.z *= 3 / speed; p.w *= 3 / speed }
            particles[i] = p
        }
    }

    private func separate() {
        for i in heads.indices { heads[i] = -1 }
        for i in particles.indices {
            let p = particles[i]
            let x = max(0, min(Self.bins - 1, Int(p.x * Self.binScale)))
            let y = max(0, min(Self.bins - 1, Int(p.y * Self.binScale)))
            let cell = x * Self.bins + y
            next[i] = heads[cell]; heads[cell] = i
        }
        let distance = 2 * Self.r
        for i in particles.indices {
            let px = max(1, min(Self.bins - 2, Int(particles[i].x * Self.binScale)))
            let py = max(1, min(Self.bins - 2, Int(particles[i].y * Self.binScale)))
            for x in (px - 1)...(px + 1) { for y in (py - 1)...(py + 1) {
                var j = heads[x * Self.bins + y]
                while j >= 0 {
                    if j > i {
                        let d = SIMD2(particles[j].x - particles[i].x, particles[j].y - particles[i].y)
                        let length = simd_length(d)
                        if length > 0.000001 && length < distance {
                            let shift = d * (0.5 * (distance - length) / length)
                            particles[i].x -= shift.x; particles[i].y -= shift.y
                            particles[j].x += shift.x; particles[j].y += shift.y
                        }
                    }
                    j = next[j]
                }
            } }
        }
    }

    private func weights(_ p: SIMD4<Float>, offset: SIMD2<Float>) -> (SIMD4<Int32>, SIMD4<Float>) {
        let position = SIMD2(p.x, p.y) / Self.h - offset
        let x = max(0, min(Self.n - 2, Int(floor(position.x))))
        let y = max(0, min(Self.n - 2, Int(floor(position.y))))
        let t = simd_clamp(position - SIMD2(Float(x), Float(y)), .zero, SIMD2(repeating: 1))
        return (SIMD4(Int32(x * Self.n + y), Int32((x + 1) * Self.n + y),
                      Int32((x + 1) * Self.n + y + 1), Int32(x * Self.n + y + 1)),
                SIMD4((1-t.x)*(1-t.y), t.x*(1-t.y), t.x*t.y, (1-t.x)*t.y))
    }

    private func transferToGrid() {
        for i in u.indices {
            u[i] = 0; v[i] = 0; wu[i] = 0; wv[i] = 0; density[i] = 0
            kind[i] = open[i] > 0 ? 1 : 2
        }
        for p in particles {
            let x = max(0, min(Self.n - 1, Int(p.x / Self.h)))
            let y = max(0, min(Self.n - 1, Int(p.y / Self.h)))
            if open[x * Self.n + y] > 0 { kind[x * Self.n + y] = 0 }
            let (ix, wx) = weights(p, offset: SIMD2(0, 0.5))
            let (iy, wy) = weights(p, offset: SIMD2(0.5, 0))
            let (id, wd) = weights(p, offset: SIMD2(0.5, 0.5))
            for k in 0..<4 {
                let a = Int(ix[k]), b = Int(iy[k])
                u[a] += p.z * wx[k]; wu[a] += wx[k]
                v[b] += p.w * wy[k]; wv[b] += wy[k]
                density[Int(id[k])] += wd[k]
            }
        }
        for x in 0..<Self.n { for y in 0..<Self.n {
            let i = x * Self.n + y
            if wu[i] > 0 { u[i] /= wu[i] }; if wv[i] > 0 { v[i] /= wv[i] }
            if x == 0 || open[i] == 0 || open[i - Self.n] == 0 { u[i] = 0 }
            if y == 0 || open[i] == 0 || open[i - 1] == 0 { v[i] = 0 }
            oldU[i] = u[i]; oldV[i] = v[i]
        } }
    }

    private func project() {
        for _ in 0..<18 {
            for x in 1..<(Self.n - 1) { for y in 1..<(Self.n - 1) {
                let i = x * Self.n + y
                if kind[i] != 0 { continue }
                let left = open[i - Self.n], right = open[i + Self.n]
                let above = open[i - 1], below = open[i + 1]
                let sum = left + right + above + below
                if sum == 0 { continue }
                let divergence = u[i + Self.n] - u[i] + v[i + 1] - v[i]
                // Mild density-drift correction; never create new particles.
                let compression = max(0, density[i] - 3.21) * 0.08
                let pressure = -(divergence - compression) / sum * 1.7
                u[i] -= left * pressure; u[i + Self.n] += right * pressure
                v[i] -= above * pressure; v[i + 1] += below * pressure
            } }
        }
    }

    private func transferFromGrid() {
        for i in particles.indices {
            var p = particles[i]
            for component in 0..<2 {
                let (indices, w) = weights(p, offset: component == 0 ? SIMD2(0, 0.5) : SIMD2(0.5, 0))
                let offset = component == 0 ? Self.n : 1
                var total: Float = 0, pic: Float = 0, correction: Float = 0
                for k in 0..<4 {
                    let index = Int(indices[k])
                    if kind[index] == 1 && (index < offset || kind[index - offset] == 1) { continue }
                    let value = component == 0 ? u[index] : v[index]
                    let old = component == 0 ? oldU[index] : oldV[index]
                    total += w[k]; pic += w[k] * value; correction += w[k] * (value - old)
                }
                if total > 0 {
                    p[component + 2] = 0.06 * pic / total + 0.94 * (p[component + 2] + correction / total)
                }
            }
            particles[i] = p
        }
    }

    /// Compact smooth particle reconstruction, not a second fluid simulation.
    /// A density isocontour can separate, fold and rejoin without preset shapes.
    func rebuildField() {
        for i in field.indices { field[i] = .zero }
        let scale = Float(Self.fieldSize), support: Float = 0.030
        for p in particles {
            let x0 = max(0, Int((p.x - support) * scale)), x1 = min(Self.fieldSize - 1, Int((p.x + support) * scale))
            let y0 = max(0, Int((p.y - support) * scale)), y1 = min(Self.fieldSize - 1, Int((p.y + support) * scale))
            for y in y0...y1 { for x in x0...x1 {
                let d = SIMD2((Float(x) + 0.5) / scale - p.x, (Float(y) + 0.5) / scale - p.y)
                let q = max(0, 1 - simd_length_squared(d) / (support * support))
                let w = q * q * q
                field[y * Self.fieldSize + x] += SIMD4(w, w * p.z, w * p.w, 0)
            } }
        }
        for i in field.indices {
            if field[i].x > 0.0001 { field[i].y /= field[i].x; field[i].z /= field[i].x }
        }
    }
}
