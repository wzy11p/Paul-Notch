import Foundation

/// Pointer timing only; no windows, preferences or content access.
struct PresentationRevealPolicy {
    enum Action: Equatable { case none, reveal, hide }
    private var enteredAt: TimeInterval?
    private var exitedAt: TimeInterval?
    private var requiresExit = true
    private var regionID: String?

    mutating func reset() { self = Self() }

    mutating func update(now: TimeInterval, region: String, insideTrigger: Bool,
                         insideVisibleSurface: Bool, visible: Bool, editing: Bool) -> Action {
        if regionID != region {
            enteredAt = nil
            exitedAt = nil
            regionID = region
        }
        if !visible {
            exitedAt = nil
            if !insideTrigger { requiresExit = false; enteredAt = nil; return .none }
            guard !requiresExit else { return .none }
            guard let enteredAt else { self.enteredAt = now; return .none }
            if now - enteredAt >= 0.3 { self.enteredAt = nil; return .reveal }
        } else {
            enteredAt = nil
            if insideVisibleSurface || editing { exitedAt = nil; return .none }
            guard let exitedAt else { self.exitedAt = now; return .none }
            if now - exitedAt >= 0.5 { reset(); return .hide }
        }
        return .none
    }
}
