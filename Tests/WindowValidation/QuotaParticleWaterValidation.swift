import Foundation
import simd

@main struct QuotaParticleWaterValidation {
    struct Failure: Error { let message: String }
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }
    static func main() throws {
        for fraction in [0.01, 0.25, 0.5, 0.74, 0.95, 0.99] {
            let water = QuotaOrbSlosh()
            water.configure(fraction: fraction)
            let resting = water.maskRGBA()
            try check(!water.isEvolving, "rest must have no particle clock")
            water.begin(position: .zero, at: 10)
            water.move(position: SIMD2(0.9, 0.15), at: 10.08)
            water.end(at: 10.09)
            let count = water.liquid.particles.count
            var sawTransition = false, largestBlendStep: Double = 0
            var previousBlend = water.flatBlend
            for frame in 1...600 {
                water.advance(to: 10.09 + Double(frame) / 30)
                let blend = water.flatBlend
                if blend > 0 && blend < 1 { sawTransition = true }
                largestBlendStep = max(largestBlendStep, abs(blend - previousBlend))
                previousBlend = blend
                try check(water.liquid.particles.count == count, "water cannot appear or disappear during a gesture")
                try check(water.liquid.particles.allSatisfy {
                    $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite &&
                    hypot($0.x - 0.5, $0.y - 0.5) <= QuotaParticleLiquid.radius
                }, "particles remain finite and inside the sphere")
            }
            try check(!water.isEvolving && water.flatBlend == 1, "release must reach flat, idle rest for every fill")
            try check(water.maskRGBA() == resting, "settled waterline is exact original quota, not a frozen lumpy field")
            if count > 0 {
                try check(sawTransition && largestBlendStep < 0.08, "final flattening must be progressive, not a snap")
            }
            let steps = water.liquid.stepCount
            water.advance(to: 10000)
            try check(water.liquid.stepCount == steps, "rest cannot keep doing fluid work")
        }

        func gesture(duration: Double) -> Float {
            let water = QuotaOrbSlosh(); water.configure(fraction: 0.5)
            water.begin(position: .zero, at: 0)
            for step in 1...60 {
                water.move(position: SIMD2(Double(step)/60, 0), at: duration * Double(step)/60)
            }
            return abs(water.liquid.particles.reduce(Float(0)) { $0 + $1.x } /
                       Float(water.liquid.particles.count) - 0.5)
        }
        let slow = gesture(duration: 1.5), fast = gesture(duration: 0.15)
        try check(fast > slow * 2, "fast and slow gestures cannot produce the same preset wave")

        let interrupted = QuotaOrbSlosh(); interrupted.configure(fraction: 0.74)
        interrupted.begin(position: .zero, at: 0)
        interrupted.move(position: SIMD2(0.8, 0), at: 0.08)
        interrupted.end(at: 0.09)
        var resumeTime = 0.09
        for frame in 1...600 {
            resumeTime = 0.09 + Double(frame) / 30
            interrupted.advance(to: resumeTime)
            if interrupted.flatBlend > 0.4 && interrupted.flatBlend < 0.7 { break }
        }
        let blendBeforeInput = interrupted.flatBlend
        interrupted.begin(position: .zero, at: resumeTime)
        interrupted.move(position: SIMD2(0.01, 0), at: resumeTime + 0.003)
        try check(interrupted.flatBlend >= blendBeforeInput - 0.02,
                  "re-grabbing during final flattening cannot reveal the old lumpy contour in one frame")

        let water = QuotaOrbSlosh(); water.configure(fraction: 0.74)
        water.begin(position: .zero, at: 10)
        water.move(position: SIMD2(0.5, 0), at: 10.05)
        water.advance(to: 10.15)
        let paused = water.liquid.particles
        water.suspend()
        water.advance(to: 500)
        try check(water.liquid.particles == paused, "resumption anchors the clock without hidden catch-up or lost momentum")
        water.advance(to: 500.04)
        try check(water.liquid.particles != paused, "visible resumption continues settling")
        water.begin(position: .zero, at: 501)
        water.configure(fraction: 0.73)
        water.move(position: SIMD2(0.5, 0), at: 501.05)
        try check(water.isEvolving, "real quota refresh must preserve an in-flight drag anchor")
        let steps = water.liquid.stepCount
        water.advance(to: 800)
        try check(water.liquid.stepCount - steps <= 8, "a scheduling stall cannot produce a catch-up storm")
        let field = water.maskRGBA()
        water.move(position: SIMD2(.nan, 1), at: 801)
        water.advance(to: .nan)
        try check(water.maskRGBA() == field, "nonfinite input cannot affect the rendered field")
        water.configure(fraction: nil)
        let unknown = water.maskRGBA()
        try check(!water.isEvolving && stride(from: 3, to: unknown.count, by: 4)
            .allSatisfy { unknown[$0] == 0 }, "unknown quotas have no fictitious water")
        if CommandLine.arguments.contains("--benchmark") {
            let sample = QuotaOrbSlosh(); sample.configure(fraction: 0.74)
            sample.begin(position: .zero, at: 1)
            sample.move(position: SIMD2(0.7, 0), at: 1.08)
            var times: [Double] = []
            for frame in 1...60 {
                let start = DispatchTime.now().uptimeNanoseconds
                sample.advance(to: 1.08 + Double(frame) / 30)
                _ = sample.maskRGBA()
                times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            times.sort()
            print("BENCHMARK: 4 fixed steps + 96px mask, median \(times[30]) ms, p95 \(times[57]) ms; \(sample.liquid.particles.count) particles")
        }
        print("PASS: particle containment, genuine quota, slow/fast response, gradual flat rest, no idle CPU steps, suspend/resume and bounded scheduling")
    }
}
