import AppKit
import ApplicationServices

enum DesktopQuotaReader {
    @MainActor static func read(_ provider: DesktopQuotaProvider, interactive: Bool) async throws -> DesktopQuotaSnapshot {
        guard AXIsProcessTrusted() else { throw DesktopQuotaFailure.permission }
        guard let application = NSRunningApplication.runningApplications(withBundleIdentifier: provider.bundleID).first else {
            throw DesktopQuotaFailure.notRunning
        }
        let pid = application.processIdentifier
        // This is the only foreground transition, and only a user's explicit Read action reaches it.
        if interactive { application.activate(options: [.activateIgnoringOtherApps]) }
        defer {
            if interactive, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == provider.bundleID {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        let worker = Task.detached(priority: .userInitiated) {
            try DesktopQuotaAXSession(provider: provider, pid: pid).read(navigate: interactive)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}

/// A bounded, read-only quota adapter. The only actions allowed are explicit
/// navigation to Settings/Plan & Usage or the account menu; no synthetic keys,
/// billing changes, credentials, chat text fields or file access.
private final class DesktopQuotaAXSession {
    let provider: DesktopQuotaProvider
    let application: AXUIElement
    let deadline = ContinuousClock.now.advanced(by: .seconds(6))
    private var sawQuotaSection = false
    init(provider: DesktopQuotaProvider, pid: pid_t) {
        self.provider = provider
        application = AXUIElementCreateApplication(pid)
    }

    func read(navigate: Bool) throws -> DesktopQuotaSnapshot {
        if let snapshot = try capture(), !navigate || snapshot.resetLabel != nil { return snapshot }
        guard navigate else { throw sawQuotaSection ? DesktopQuotaFailure.invalidData : DesktopQuotaFailure.pageUnavailable }
        switch provider {
        case .cursor:
            if let settings = find(roles: [kAXButtonRole, kAXCheckBoxRole], matching: {
                $0.contains("Settings") || $0.contains("设置")
            }) { press(settings.element) }
            guard let usage = waitFor(roles: [kAXButtonRole], matching: { $0.contains("Plan & Usage") }) else {
                throw DesktopQuotaFailure.pageUnavailable
            }
            press(usage.element)
        case .grok:
            if find(roles: [kAXGroupRole], matching: { $0.contains("Grok Bot 设置") }) == nil {
                if find(roles: [kAXGroupRole, kAXMenuRole], matching: { $0.contains("打开账户菜单") }) == nil {
                    guard let account = find(roles: [kAXPopUpButtonRole, kAXButtonRole], matching: {
                        $0.contains("打开账户菜单") || $0.contains("Open account menu")
                    }) else { throw DesktopQuotaFailure.pageUnavailable }
                    press(account.element)
                }
                guard let settings = waitFor(roles: [kAXMenuItemRole, kAXButtonRole], matching: {
                    $0.contains("设置") || $0.contains("Settings")
                }) else { throw DesktopQuotaFailure.pageUnavailable }
                press(settings.element)
            }
            guard let usage = waitFor(roles: [kAXButtonRole], matching: {
                $0.contains("用量与账单") || $0.contains("Usage & Billing")
            }) else { throw DesktopQuotaFailure.pageUnavailable }
            press(usage.element)
        case .doubao:
            guard let account = find(roles: [kAXPopUpButtonRole], matching: { labels in
                labels.contains { $0.contains("套餐") && ($0.contains("飞书") || $0.contains("个人版")) }
            }) else { throw DesktopQuotaFailure.pageUnavailable }
            press(account.element)
            guard let quota = waitFor(roles: [kAXMenuItemRole], matching: {
                $0.contains { $0.hasPrefix("当前时段额度用量") }
            }) else { throw DesktopQuotaFailure.pageUnavailable }
            press(quota.element)
        }
        while ContinuousClock.now < deadline, !Task.isCancelled {
            if let snapshot = try capture() { return snapshot }
            Thread.sleep(forTimeInterval: 0.12) // Worker thread only; no main-thread blocking.
        }
        throw sawQuotaSection ? DesktopQuotaFailure.invalidData : DesktopQuotaFailure.pageUnavailable
    }

    private func capture() throws -> DesktopQuotaSnapshot? {
        let scope: AXUIElement
        switch provider {
        case .cursor:
            // A chat may quote a heading and percentages. Require the native
            // Settings navigation subtree before considering any quota text.
            guard let search = find(roles: [kAXTextFieldRole], matching: { $0.contains("Search Settings") }) else { return nil }
            var candidate = search.parent
            var quotaScope: AXUIElement?
            // Navigation and content are sibling branches, not grandchildren
            // of the search field. Stop at their bounded common ancestor.
            for _ in 0..<4 {
                guard let settings = candidate else { break }
                if let heading = find(root: settings, roles: ["AXHeading"], matching: { $0.contains("Plan & Usage") }),
                   find(root: settings, roles: [kAXButtonRole], matching: { $0.contains("Plan & Usage") }) != nil {
                    // The heading's parent is only the title row in Cursor.
                    quotaScope = heading.parent.flatMap(parent); break
                }
                candidate = parent(settings)
            }
            guard let quotaScope else { return nil }
            scope = quotaScope
        case .grok:
            if let settings = find(roles: [kAXGroupRole], matching: { $0.contains("Grok Bot 设置") }),
               let usage = find(root: settings.element, roles: [kAXGroupRole], matching: {
                   $0.contains("用量与账单") || $0.contains("Usage & Billing")
               }) {
                scope = usage.element
            } else {
                guard let menu = find(roles: [kAXGroupRole, kAXMenuRole], matching: {
                    $0.contains("打开账户菜单") || $0.contains("账户") || $0.contains("Account")
                }), let weekly = find(root: menu.element, roles: nil, matching: {
                    $0.contains { $0.hasPrefix("每周用量") || $0.hasPrefix("Weekly usage") }
                }) else { return nil }
                scope = weekly.element
            }
        case .doubao:
            if let subscription = find(roles: [kAXGroupRole], matching: { $0.contains("订阅") }),
               find(root: subscription.element, roles: ["AXWebArea"], matching: {
                   $0.contains { $0.contains("doubao.com/member/quota-management") }
               }) != nil {
                scope = subscription.element
            } else {
            guard let menu = find(roles: [kAXMenuRole], matching: { _ in true }),
                  let period = find(root: menu.element, roles: nil, matching: {
                      $0.contains { $0.hasPrefix("当前时段额度用量") }
                  }) else { return nil }
            scope = period.element
            }
        }
        sawQuotaSection = true
        var text = quotaText(scope)
        if provider == .cursor {
            for name in ["Cursor Models", "Other Models"] {
                guard let progress = find(root: scope, roles: [kAXProgressIndicatorRole], matching: { $0.contains(name) }),
                      let used = value(progress.element, kAXValueAttribute) as? NSNumber,
                      used.doubleValue.isFinite, (0...100).contains(used.doubleValue) else { return nil }
                text.append("\(name) \(used.doubleValue)% used")
            }
        }
        // Empty/loading snapshots are retryable within this bounded foreground read.
        return try? DesktopQuotaParser.parse(provider, lines: text, at: .now)
    }

    private struct Match { let element: AXUIElement; let parent: AXUIElement? }
    private func find(root: AXUIElement? = nil, roles: Set<String>?,
                      matching predicate: ([String]) -> Bool) -> Match? {
        let roots = root.map { [$0] } ?? ((value(application, kAXWindowsAttribute) as? [AXUIElement]) ?? [])
        var queue: [(AXUIElement, AXUIElement?, Int)] = (roots.isEmpty ? [root ?? application] : roots).map { ($0, nil, 0) }
        var index = 0
        while index < queue.count, index < 800, ContinuousClock.now < deadline, !Task.isCancelled {
            let (element, parent, depth) = queue[index]; index += 1
            let role = string(element, kAXRoleAttribute) ?? ""
            // Never inspect editable fields, message bodies, tables or large lists.
            if role == kAXTextFieldRole {
                // Chromium exposes Search Settings as a placeholder, not title.
                // Read the field's label only, never its editable value.
                let fieldLabels = labels(element) + [string(element, kAXPlaceholderValueAttribute)].compactMap { $0 }
                if roles?.contains(role) == true, predicate(fieldLabels) { return Match(element: element, parent: parent) }
                continue
            }
            if [kAXTextAreaRole, kAXTableRole, kAXOutlineRole].contains(role) { continue }
            if roles == nil || roles!.contains(role) {
                let text = labels(element, includeValue: role == "AXHeading")
                if predicate(text) { return Match(element: element, parent: parent) }
            }
            if role == kAXStaticTextRole || depth >= 18 { continue }
            for child in children(element).prefix(128) { queue.append((child, element, depth + 1)) }
        }
        return nil
    }
    private func waitFor(roles: Set<String>, matching predicate: ([String]) -> Bool) -> Match? {
        while ContinuousClock.now < deadline, !Task.isCancelled {
            if let match = find(roles: roles, matching: predicate) { return match }
            Thread.sleep(forTimeInterval: 0.12)
        }
        return nil
    }
    private func quotaText(_ root: AXUIElement) -> [String] {
        var output: [String] = []
        var visited = 0
        func collect(_ element: AXUIElement, depth: Int) -> [String] {
            guard visited < 160, depth <= 7, ContinuousClock.now < deadline, !Task.isCancelled else { return [] }
            visited += 1
            let role = string(element, kAXRoleAttribute) ?? ""
            if [kAXTextAreaRole, kAXTextFieldRole, kAXTableRole, kAXOutlineRole].contains(role) { return [] }
            var fragments = labels(element, includeValue: true)
            output += fragments
            for child in children(element).prefix(64) { fragments += collect(child, depth: depth + 1) }
            let unique = fragments.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            let caption = unique.joined(separator: " ")
            // Build captions within their own section in document order. A
            // breadth-first join mixes adjacent pools and loses reset phrases.
            if !caption.isEmpty, caption.count <= 512 { output.append(caption) }
            return unique
        }
        _ = collect(root, depth: 0)
        return output
    }
    private func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        guard ContinuousClock.now < deadline, !Task.isCancelled else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.12)
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }
    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let result = value(element, attribute) as? String, result.count <= 512 else { return nil }
        return result
    }
    private func labels(_ element: AXUIElement, includeValue: Bool = false) -> [String] {
        let keys = [kAXTitleAttribute, kAXDescriptionAttribute] + (includeValue ? [kAXValueAttribute] : [])
        var labels = keys.compactMap { string(element, $0) }.filter { !$0.isEmpty }
        if string(element, kAXRoleAttribute) == "AXWebArea",
           let raw = value(element, kAXURLAttribute), let url = raw as? URL,
           ["doubao.com", "www.doubao.com"].contains(url.host ?? ""), url.path == "/member/quota-management" {
            labels.append("doubao.com/member/quota-management")
        }
        return labels
    }
    private func children(_ element: AXUIElement) -> [AXUIElement] {
        (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }
    private func parent(_ element: AXUIElement) -> AXUIElement? {
        guard let value = value(element, kAXParentAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private func press(_ element: AXUIElement) {
        guard ContinuousClock.now < deadline, !Task.isCancelled else { return }
        AXUIElementPerformAction(element, kAXPressAction as CFString)
    }
}
