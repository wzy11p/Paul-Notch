import Foundation

@main
struct PresentationRevealValidation {
    static func main() {
        var policy = PresentationRevealPolicy()
        var count = 0
        func expect(_ result: PresentationRevealPolicy.Action, _ expected: PresentationRevealPolicy.Action) {
            precondition(result == expected, "Check \(count + 1): \(result), expected \(expected)")
            count += 1
        }
        func sample(_ t: Double, _ inside: Bool, visible: Bool = false, editing: Bool = false,
                    region: String = "display-1") -> PresentationRevealPolicy.Action {
            policy.update(now: t, region: region, insideTrigger: inside,
                          insideVisibleSurface: inside, visible: visible, editing: editing)
        }
        expect(sample(0, true), .none) // enabling under pointer must not immediately reveal
        expect(sample(1, true), .none)
        expect(sample(2, false), .none)
        expect(sample(3, true), .none)
        expect(sample(3.2, true), .none)
        expect(sample(3.21, false), .none) // fast pass cancels dwell
        expect(sample(4, true), .none)
        expect(sample(4.29, true), .none)
        expect(sample(4.31, true), .reveal)
        expect(sample(5, true, visible: true), .none)
        expect(sample(6, false, visible: true), .none)
        expect(sample(6.4, false, visible: true), .none)
        expect(sample(6.51, false, visible: true), .hide)
        expect(sample(7, true), .none) // no reveal without leaving again
        expect(sample(8, false), .none)
        expect(sample(9, true), .none)
        expect(sample(9.31, true), .reveal)
        expect(sample(10, false, visible: true, editing: true), .none)
        expect(sample(100, false, visible: true, editing: true), .none)
        expect(sample(101, false, visible: true), .none)
        expect(sample(101.3, true, visible: true), .none) // re-entry cancels hide
        expect(sample(102, false, visible: true), .none)
        expect(sample(102.51, false, visible: true), .hide)
        expect(sample(103, false), .none)
        expect(sample(104, true), .none)
        expect(sample(104.25, true, region: "display-2"), .none)
        expect(sample(104.4, true, region: "display-2"), .none)
        expect(sample(104.56, true, region: "display-2"), .reveal)
        policy.reset()
        expect(sample(105, true), .none)
        expect(sample(106, true), .none)
        print("PASS: \(count) presentation reveal timing and editing checks")
    }
}
