import Foundation

struct CursorWebObservation: Equatable, Sendable {
    var isCursorPage: Bool
    var selection: CursorModelSelection
    static let unavailable = Self(isCursorPage: false, selection: .unavailable)
}

enum CursorWebSelector {
    private static let containers: Set<String> = ["AXWindow", "AXGroup", "AXScrollArea", "AXSplitGroup"]

    /// This verified website is a Cursor surface, not every browser tab and
    /// not a similarly named host. URLs are only inspected, never persisted.
    private static func isAgentPage(_ raw: String) -> Bool {
        guard raw.utf8.count <= 1024, let parts = URLComponents(string: raw),
              parts.scheme == "https", parts.host == "cursor.com", parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443, parts.percentEncodedPath == parts.path else { return false }
        let segments = parts.path.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count >= 2, segments[0].isEmpty, segments[1] == "agents" else { return false }
        if segments.count == 2 { return true }
        guard segments.count == 3 else { return false }
        return segments[2].utf8.count <= 120 && segments[2].utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    /// Chrome exposes its selected document as the single top-level WebArea.
    /// Stop at that boundary: an official iframe in another page is ineligible.
    private static func document<T: CursorModelTree>(_ tree: T, window: T.Element,
                                                    canContinue: () -> Bool) -> T.Element? {
        var stack: [(T.Element, Int)] = [(window, 0)], documents: [T.Element] = []
        var visited = 0
        while let (node, depth) = stack.popLast() {
            guard canContinue(), visited < 64, depth <= 12, let role = tree.string(node, .role) else { return nil }
            visited += 1
            if role == "AXWebArea" { documents.append(node); continue }
            guard containers.contains(role) else { continue }
            guard let children = tree.children(node), children.count <= 64 else { return nil }
            stack.append(contentsOf: children.map { ($0, depth + 1) })
        }
        return documents.count == 1 ? documents[0] : nil
    }

    /// Observed direct composer row: one textarea, context popup and model
    /// popup. Never inspect editable values, static text, chat or extension UI.
    private static func composer<T: CursorModelTree>(_ tree: T, node: T.Element,
                                                     canContinue: () -> Bool) -> CursorModelSelection? {
        guard canContinue(), tree.string(node, .role) == "AXGroup",
              let children = tree.children(node), children.count <= 16 else { return nil }
        var editors = 0, popups: [T.Element] = []
        for child in children {
            guard canContinue() else { return nil }
            switch tree.string(child, .role) {
            case "AXTextArea": editors += 1
            case "AXPopUpButton": popups.append(child)
            default: break
            }
        }
        guard editors == 1, popups.count == 2 else { return nil }
        var contexts = 0, modelLabels: [[String]] = []
        for popup in popups {
            guard canContinue() else { return nil }
            let labels = [tree.string(popup, .title), tree.string(popup, .description)].compactMap { $0 }.filter { !$0.isEmpty }
            if labels.contains("Add context and tools") { contexts += 1 }
            else { modelLabels.append(labels) }
        }
        guard contexts == 1, modelLabels.count == 1 else { return nil }
        let parsed = modelLabels[0].compactMap(CursorModelSelection.parse)
        guard let first = parsed.first, parsed.allSatisfy({ $0 == first }) else { return .unavailable }
        return first
    }

    private static func selected<T: CursorModelTree>(_ tree: T, document: T.Element, focused: T.Element?,
                                                    canContinue: () -> Bool) -> CursorModelSelection {
        if let focused {
            var node = focused, parents: [T.Element] = [], belongsToDocument = false
            for _ in 0..<32 {
                guard canContinue() else { return .unavailable }
                if tree.same(node, document) { belongsToDocument = true; break }
                guard let role = tree.string(node, .role), role != "AXWebArea", let parent = tree.parent(node) else { break }
                parents.append(parent); node = parent
            }
            // Focus may belong to a Chrome extension popup or child iframe.
            // Establish ownership before inspecting any of its control labels.
            if belongsToDocument {
                for parent in parents.prefix(3) {
                    if let candidate = composer(tree, node: parent, canContinue: canContinue) { return candidate }
                }
            }
        }
        var stack: [(T.Element, Int)] = [(document, 0)], candidates: [CursorModelSelection] = []
        var visited = 0
        while let (node, depth) = stack.popLast() {
            guard canContinue(), visited < 128, depth <= 16 else { return .unavailable }
            visited += 1
            guard let children = tree.children(node), children.count <= 64 else { return .unavailable }
            var groups: [T.Element] = [], local: [CursorModelSelection] = []
            for child in children {
                guard canContinue() else { return .unavailable }
                guard let role = tree.string(child, .role), containers.contains(role) else { continue }
                groups.append(child)
                if let value = composer(tree, node: child, canContinue: canContinue) { local.append(value) }
            }
            // A verified chat+composer parent supplies its row directly. Do not
            // descend its message sibling, even if it contains model names.
            if !local.isEmpty { candidates += local; continue }
            stack.append(contentsOf: groups.map { ($0, depth + 1) })
        }
        return candidates.count == 1 ? candidates[0] : .unavailable
    }

    static func read<T: CursorModelTree>(_ tree: T, window: T.Element, focused: T.Element?,
                                        canContinue: () -> Bool = { true }) -> CursorWebObservation {
        guard let page = document(tree, window: window, canContinue: canContinue), canContinue(),
              let url = tree.string(page, .url), isAgentPage(url) else { return .unavailable }
        let model = selected(tree, document: page, focused: focused, canContinue: canContinue)
        // Revalidate after capture: a same-window tab switch/navigation must
        // never publish the previous document's model under the current page.
        guard canContinue(), let current = document(tree, window: window, canContinue: canContinue),
              tree.same(page, current), tree.string(current, .url) == url else { return .unavailable }
        return .init(isCursorPage: true, selection: model)
    }
}
