import Foundation

@main
struct QuotaCardVisibilityValidation {
    @MainActor static func main() {
        let suite = CommandLine.arguments[1]
        let mode = CommandLine.arguments[2]
        let defaults = UserDefaults(suiteName: suite)!
        let available = ["codex", "cursor", "grok", "doubao", "muse", "deepseek", "minimax-api", "minimax-audio"]
        var failures = 0
        func check(_ value: @autoclosure () -> Bool, _ name: String) {
            if !value() { failures += 1; print("FAIL: \(name)") }
        }
        if mode == "write" {
            defaults.removePersistentDomain(forName: suite)
            defaults.set(true, forKey: "quota.deepseek.enabled.v1")
            defaults.set("owned-profile-sentinel", forKey: "unrelated-profile")
            let order = QuotaCardOrderStore(defaults: defaults)
            order.commit(["grok", "codex", "cursor", "doubao", "muse", "deepseek", "minimax-api", "minimax-audio"], available: available)
            let visibility = QuotaCardVisibilityStore(defaults: defaults)
            check(visibility.hidden.isEmpty, "An existing installation retains all current cards by default")
            visibility.hide("minimax-audio", available: available)
            visibility.hide("minimax-audio", available: available)
            visibility.hide("unknown", available: available)
            check(visibility.hidden == ["minimax-audio"], "Removing a pending card is idempotent and rejects unknown identities")
            for id in available { visibility.hide(id, available: available) }
            check(available.filter { !visibility.hidden.contains($0) }.isEmpty, "All Home cards can be removed, including Codex")
            visibility.show("codex")
            check(available.filter { !visibility.hidden.contains($0) } == ["codex"], "Adding back one card does not restore the others")
            check(order.saved == ["grok", "codex", "cursor", "doubao", "muse", "deepseek", "minimax-api", "minimax-audio"],
                  "Hiding cards never changes their saved order")
        } else {
            defer { defaults.removePersistentDomain(forName: suite) }
            let visibility = QuotaCardVisibilityStore(defaults: defaults)
            check(available.filter { !visibility.hidden.contains($0) } == ["codex"],
                  "A separate cold process restores the selected Home visibility")
            visibility.show("muse")
            visibility.show("muse")
            check(available.filter { !visibility.hidden.contains($0) } == ["codex", "muse"],
                  "Restoring a saved card is immediate and idempotent")
            check(defaults.bool(forKey: "quota.deepseek.enabled.v1"), "Home removal never disconnects an account")
            check(defaults.string(forKey: "unrelated-profile") == "owned-profile-sentinel", "Unrelated profile preferences remain intact")
            let order = QuotaCardOrderStore(defaults: defaults)
            order.commit(["muse", "codex"], available: available)
            check(order.saved == ["grok", "muse", "cursor", "doubao", "codex", "deepseek", "minimax-api", "minimax-audio"],
                  "Reordering visible cards preserves the hidden cards' slots")
        }
        guard failures == 0 else { exit(1) }
        print("PASS: \(mode) Home-only removal/restoration, preserved connections and order")
    }
}
