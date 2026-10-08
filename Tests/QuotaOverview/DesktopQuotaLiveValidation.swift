import AppKit

/// Explicit one-shot diagnostics only. Reads a known quota section, never enables
/// an app connection, saves a snapshot, grants permission or accesses credentials.
@main struct DesktopQuotaLiveValidation {
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard CommandLine.arguments.count == 2,
              let provider = DesktopQuotaProvider(rawValue: CommandLine.arguments[1]) else { exit(64) }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: provider.bundleID).first {
            let root = AXUIElementCreateApplication(app.processIdentifier)
            var windows: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &windows)
            print("AX boundary: trusted=\(AXIsProcessTrusted()), windowsResult=\(result.rawValue), windows=\((windows as? [AXUIElement])?.count ?? 0)")
            var queue = ((windows as? [AXUIElement]) ?? []).map { ($0, 0) }
            var index = 0
            var roles: [String: Int] = [:]
            let knownLabels = Set(["Search Settings", "Plan & Usage", "Grok Bot 设置", "用量与账单", "订阅与额度管理 - 豆包"])
            while index < queue.count, index < 1000 {
                let (element, depth) = queue[index]; index += 1
                func attribute(_ name: String) -> CFTypeRef? {
                    var value: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
                    return value
                }
                let role = attribute(kAXRoleAttribute) as? String ?? "unknown"
                roles[role, default: 0] += 1
                for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute] {
                    if let label = attribute(key) as? String, knownLabels.contains(label) {
                        print("Known quota navigation: \(label), role=\(role), attribute=\(key), depth=\(depth)")
                    }
                }
                if depth < 18, ![kAXTextAreaRole, kAXTableRole, kAXOutlineRole, kAXStaticTextRole].contains(role) {
                    queue += ((attribute(kAXChildrenAttribute) as? [AXUIElement]) ?? []).prefix(128).map { ($0, depth + 1) }
                }
            }
            print("AX role counts (no page content): \(roles)")
        }
        do {
            let result = try await DesktopQuotaReader.read(provider, interactive: false)
            print("LIVE \(provider.name): \(result.pools.map { "\($0.name) remaining \($0.remaining)%" }.joined(separator: "; "))")
            print("reset: \(result.resetLabel ?? "not provided")")
        } catch { print("BLOCKED: \(error)"); exit(1) }
    }
}
