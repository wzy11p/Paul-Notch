import Foundation
import Combine

/// Identity-only preference. This never stores, rewrites or reconnects account data.
enum QuotaCardOrder {
    static func resolved(saved: [String], available: [String]) -> [String] {
        let valid = Set(available)
        var seen = Set<String>()
        return (saved + available).filter { valid.contains($0) && seen.insert($0).inserted }
    }

    static func merging(visible: [String], into all: [String]) -> [String] {
        let moved = Set(visible)
        guard moved.count == visible.count, moved.isSubset(of: Set(all)) else { return all }
        var iterator = visible.makeIterator()
        return all.map { moved.contains($0) ? iterator.next()! : $0 }
    }
}

@MainActor
final class QuotaCardOrderStore: ObservableObject {
    private static let key = "quota-card-order-v1"
    private let defaults: UserDefaults
    @Published private(set) var saved: [String]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        saved = defaults.stringArray(forKey: Self.key) ?? []
    }

    func commit(_ visible: [String], available: [String]) {
        let current = QuotaCardOrder.resolved(saved: saved, available: available)
        let next = QuotaCardOrder.merging(visible: visible, into: current)
        guard next != current else { return }
        defaults.set(next, forKey: Self.key)
        saved = next
    }
}
