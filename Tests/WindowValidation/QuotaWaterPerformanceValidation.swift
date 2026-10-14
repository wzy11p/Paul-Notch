import Foundation
import simd
#if !QUOTA_WATER_CHECKS
@testable import PaulNotchCore
#endif

/// Catches an unoptimized particle renderer being handed to the owner as an
/// interactive preview. Measures the actual solver and uploaded mask, not a
/// mock or a source-code flag. Run alone, never alongside another benchmark.
#if QUOTA_WATER_CHECKS
@main
#endif
struct QuotaWaterPerformanceValidation {
    static func main() { exit(run() ? 0 : 1) }
    static func run() -> Bool {
        let water = QuotaOrbSlosh()
        water.configure(fraction: 0.75)
        water.begin(position: .zero, at: 1)
        water.move(position: SIMD2(0.7, 0.1), at: 1.08)
        water.end(at: 1.09)
        var durations: [Double] = []
        var checksum: UInt64 = 0
        for frame in 1...45 {
            let start = DispatchTime.now().uptimeNanoseconds
            water.advance(to: 1.09 + Double(frame) / 30)
            let mask = water.maskRGBA()
            checksum += UInt64(mask[(frame * 19) % mask.count])
            durations.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        durations.sort()
        let p95 = durations[Int(Double(durations.count - 1) * 0.95)]
        let median = durations[durations.count / 2]
        print(String(format: "WATER_FRAME: median %.3f ms, p95 %.3f ms; %d particles; checksum %llu",
                     median, p95, water.liquid.particles.count, checksum))
        // Half a 60Hz UI budget leaves room for AppKit input/composition.
        // This is a local performance guard, not a universal hardware claim.
        guard p95 < 8 else {
            print("FAIL: water work exceeds the 8 ms local main-thread budget; do not launch this interactive build")
            return false
        }
        print("PASS: bounded local water-frame budget")
        return true
    }
}
