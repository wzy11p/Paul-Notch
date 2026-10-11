import Foundation

enum CursorModelPool: String, Equatable, Sendable {
    case cursor = "Cursor Models", other = "Other Models"
    var marker: String { self == .cursor ? "内" : "外" }
}

enum CursorModelSelection: Equatable, Sendable {
    case model(name: String, short: String, pool: CursorModelPool)
    case automatic, unavailable, permissionRequired, disabled
    var pool: CursorModelPool? { if case .model(_, _, let pool) = self { return pool }; return nil }
    var shortLabel: String {
        switch self { case .model(_, let short, _): short; case .automatic: "Auto"
        case .permissionRequired: "待授权"; case .disabled: "双额度"; case .unavailable: "未识别" }
    }
    var explanation: String {
        switch self {
        case .model(let name, _, let pool): "当前会话所选 \(name)，对应 \(pool.rawValue)；不代表已提交任务实际正在使用的模型"
        case .automatic: "Auto 的实际路由模型尚未确认，分别显示两组额度"
        case .permissionRequired: "模型识别需要 Paul 的辅助功能授权；余额连接不受影响"
        case .disabled: "模型跟随未开启，分别显示两组额度"
        case .unavailable: "当前会话模型尚未确认，分别显示两组额度"
        }
    }
    // Explicit current official catalog, not a fuzzy brand-name classifier.
    // Unknown versions, custom endpoints and multi-model selections fail closed.
    private static let known: [(String, String, CursorModelPool)] = [
        ("Claude Opus 5.5", "Opus 5.5", .other), ("Claude Sonnet 5.5", "Sonnet", .other),
        ("Claude Haiku 5.5", "Haiku", .other), ("Claude Fable 5.1", "Fable", .other),
        ("Grok 4.7", "Grok 4.7", .cursor), ("Grok 4.6", "Grok 4.6", .cursor),
        ("Grok 4.5", "Grok 4.5", .cursor), ("Composer 2.5", "Composer", .cursor),
        ("GPT-5.6 Sol", "GPT 5.6", .other), ("GPT-5.6 Terra", "GPT 5.6", .other),
        ("GPT-5.6 Luna", "GPT 5.6", .other), ("Gemini 3.1 Pro", "Gemini", .other),
        ("Gemini 3.8 Flash", "Gemini", .other), ("Muse Spark 1.3", "Muse", .other)
    ]
    static func parse(_ label: String) -> Self? {
        guard label.utf8.count <= 96 else { return nil }
        // Cursor decorates some native Grok selector titles with trailing ZWSPs.
        // Normalize that observed suffix only; embedded/bidi controls still fail.
        var undecorated = label
        while undecorated.last == "\u{200B}" { undecorated.removeLast() }
        guard !undecorated.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        let normalized = undecorated.replacingOccurrences(of: "(", with: " ").replacingOccurrences(of: ")", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .replacingOccurrences(of: " Extra High", with: " XHigh")
        if ["Auto", "Auto Cost", "Auto Balance", "Auto Intelligence"].contains(normalized) { return .automatic }
        let modifiers: Set<String> = ["1M", "2M", "200k", "500k", "Fast", "MAX", "Max", "High", "Medium", "Low", "None", "Minimal", "XHigh", "Ultra", "Thinking"]
        for (name, short, pool) in known {
            guard normalized == name || normalized.hasPrefix(name + " ") else { continue }
            let suffix = normalized.dropFirst(name.count).split(separator: " ").map(String.init)
            guard suffix.allSatisfy(modifiers.contains), suffix.count <= 4 else { return nil }
            return .model(name: name, short: short, pool: pool)
        }
        return nil
    }
}

enum CursorModelAttribute: Equatable { case role, title, description, url }

protocol CursorModelTree {
    associatedtype Element
    func string(_ element: Element, _ attribute: CursorModelAttribute) -> String?
    func children(_ element: Element) -> [Element]?
    func parent(_ element: Element) -> Element?
    func same(_ lhs: Element, _ rhs: Element) -> Bool
}

enum CursorModelSelector {
    private static func isWorkbench<T: CursorModelTree>(_ tree: T, _ element: T.Element) -> Bool {
        guard let raw = tree.string(element, .url), let url = URL(string: raw) else { return false }
        return url.scheme == "vscode-file" && url.host == "vscode-app"
            && url.path.hasSuffix("/out/vs/code/electron-sandbox/workbench/workbench.html")
    }

    private static func toolbar<T: CursorModelTree>(_ tree: T, _ element: T.Element, parent: T.Element,
                                                   focused: T.Element?, canContinue: () -> Bool) -> (CursorModelSelection, Bool)? {
        guard canContinue(), let siblings = tree.children(parent), siblings.count <= 64 else { return nil }
        var prompts: [T.Element] = []
        for sibling in siblings {
            guard canContinue() else { return nil }
            if let value = prompt(tree, sibling, canContinue: canContinue) { prompts.append(value) }
        }
        guard prompts.count == 1, let prompt = prompts.first,
              let controls = tree.children(element), controls.count <= 24 else { return nil }
        var selections: [CursorModelSelection] = []
        var isFocused = focused.map { tree.same($0, prompt) || tree.same($0, element) } ?? false
        for control in controls {
            guard canContinue() else { return nil }
            guard tree.string(control, .role) == "AXPopUpButton" else { continue }
            let labels = [tree.string(control, .title), tree.string(control, .description)].compactMap { $0 }
            let parsed = labels.compactMap(CursorModelSelection.parse)
            if let first = parsed.first, parsed.allSatisfy({ $0 == first }) { selections.append(first) }
            if let focused, tree.same(focused, control) { isFocused = true }
        }
        return (selections.count == 1 ? selections[0] : .unavailable, isFocused)
    }

    private static func prompt<T: CursorModelTree>(_ tree: T, _ root: T.Element,
                                                  canContinue: () -> Bool) -> T.Element? {
        var node = root
        // Electron adds two single-child presentation wrappers around Prompt.
        // Never descend a text field, a multi-child group, or arbitrary content.
        for _ in 0..<4 {
            guard canContinue(), let role = tree.string(node, .role) else { return nil }
            if role == "AXTextArea" { return tree.string(node, .description) == "Prompt" ? node : nil }
            guard role == "AXGroup", let children = tree.children(node), children.count == 1 else { return nil }
            node = children[0]
        }
        return nil
    }

    // Start at the focused composer instead of walking through an unrelated
    // long editor document. Verify its enclosing official workbench AND window
    // before trusting the candidate; ancestor/group text is never read.
    private static func focusedComposer<T: CursorModelTree>(_ tree: T, window: T.Element, focused: T.Element,
                                                            canContinue: () -> Bool) -> CursorModelSelection? {
        var current = focused
        var candidate: CursorModelSelection?
        var sawWorkbench = false
        for depth in 0..<40 {
            guard canContinue(), let role = tree.string(current, .role) else { return .unavailable }
            if tree.same(current, window) { return sawWorkbench ? candidate : nil }
            if role == "AXWebArea" {
                guard isWorkbench(tree, current) else { return .unavailable }
                sawWorkbench = true
            }
            guard let parent = tree.parent(current) else { return nil }
            if candidate == nil, depth < 4 {
                guard let siblings = tree.children(parent) else { return .unavailable }
                var toolbars: [T.Element] = []
                for sibling in siblings {
                    guard canContinue() else { return .unavailable }
                    if tree.string(sibling, .role) == "AXToolbar" { toolbars.append(sibling) }
                }
                guard toolbars.count <= 1 else { return .unavailable }
                if let bar = toolbars.first,
                   let result = toolbar(tree, bar, parent: parent, focused: focused, canContinue: canContinue), result.1 {
                    candidate = result.0
                }
            }
            current = parent
        }
        return .unavailable
    }

    static func read<T: CursorModelTree>(_ tree: T, window: T.Element, focused: T.Element?,
                                        canContinue: () -> Bool = { true }) -> CursorModelSelection {
        // Only the native editor's own workbench is eligible. Embedded browser
        // pages, model menus, messages and editors cannot supply a selection.
        if let focused, let result = focusedComposer(tree, window: window, focused: focused, canContinue: canContinue) { return result }
        var stack: [(T.Element, T.Element?, Int, Bool)] = [(window, nil, 0, false)]
        var candidates: [(CursorModelSelection, Bool)] = []
        var visited = 0
        while let (element, parent, depth, inWorkbench) = stack.popLast() {
            guard canContinue(), visited < 384, depth <= 40 else { return .unavailable }
            visited += 1
            guard let role = tree.string(element, .role) else { return .unavailable }
            if ["AXStaticText", "AXTextArea", "AXTextField", "AXTable", "AXOutline", "AXList", "AXMenu", "AXMenuBar", "AXTabGroup"].contains(role) { continue }
            var eligible = inWorkbench
            if role == "AXWebArea" {
                guard isWorkbench(tree, element) else { continue }
                eligible = true
            }
            if role == "AXToolbar", eligible, let parent {
                if let result = toolbar(tree, element, parent: parent, focused: focused, canContinue: canContinue) { candidates.append(result) }
                continue
            }
            guard let children = tree.children(element), children.count <= 64 else { return .unavailable }
            if stack.count + children.count > 384 { return .unavailable }
            for child in children { stack.append((child, element, depth + 1, eligible)) }
        }
        let focusedCandidates = candidates.filter(\.1)
        if focusedCandidates.count == 1 { return focusedCandidates[0].0 }
        return candidates.count == 1 ? candidates[0].0 : .unavailable
    }
}
