import Foundation

@main
struct QuotaCardOrderValidation {
    @MainActor static func main() {
        var failures = 0
        func check(_ result: [String], _ expected: [String], _ name: String) {
            if result != expected { failures += 1; print("FAIL: \(name): \(result)") }
        }
        check(QuotaCardOrder.resolved(saved: ["b", "b", "removed", "a"], available: ["a", "b", "c"]),
              ["b", "a", "c"], "Saved order survives refresh; duplicates/stale IDs are removed; new cards append")
        check(QuotaCardOrder.merging(visible: ["c", "a"], into: ["a", "b", "c", "d"]),
              ["c", "b", "a", "d"], "Filtered reorder does not move hidden cards")
        check(QuotaCardOrder.merging(visible: ["c", "c"], into: ["a", "b", "c"]),
              ["a", "b", "c"], "Malformed duplicate reorder is rejected")
        check(QuotaCardOrder.merging(visible: ["unknown", "a"], into: ["a", "b", "c"]),
              ["a", "b", "c"], "Unknown identities cannot replace actual accounts")
        let suite = "local.paul.quota-order-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("preserve", forKey: "unrelated")
        let store = QuotaCardOrderStore(defaults: defaults)
        store.commit(["c", "a"], available: ["a", "b", "c", "d"])
        let reopened = QuotaCardOrderStore(defaults: defaults)
        check(reopened.saved, ["c", "b", "a", "d"], "Order survives reloading preferences")
        store.commit(["bad"], available: ["a", "b", "c", "d"])
        check(store.saved, ["c", "b", "a", "d"], "Invalid commits cannot damage saved order")
        if defaults.string(forKey: "unrelated") != "preserve" { failures += 1 }
        guard failures == 0 else { exit(1) }
        print("PASS: order normalization, filtered merging, invalid-order rejection")
    }
}
