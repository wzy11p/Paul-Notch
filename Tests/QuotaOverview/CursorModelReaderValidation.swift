import Foundation
#if !DIRECT_MODEL_TEST
@testable import PaulNotchCore
#endif

private final class ModelTree: CursorModelTree {
    struct Node { var role: String; var title = ""; var description = ""; var url = ""; var children: [Int] = [] }
    var nodes: [Int: Node] = [:]
    var attributes: [(Int, CursorModelAttribute)] = []
    func string(_ element: Int, _ attribute: CursorModelAttribute) -> String? {
        attributes.append((element, attribute))
        guard let node = nodes[element] else { return nil }
        switch attribute { case .role: return node.role; case .title: return node.title
        case .description: return node.description; case .url: return node.url }
    }
    func children(_ element: Int) -> [Int]? { nodes[element]?.children }
    func parent(_ element: Int) -> Int? { nodes.first(where: { $0.value.children.contains(element) })?.key }
    func same(_ lhs: Int, _ rhs: Int) -> Bool { lhs == rhs }
    static func fixture(_ model: String = "Claude Opus 5.5 1M Medium") -> ModelTree {
        let tree = ModelTree()
        tree.nodes = [
            0: .init(role: "AXWindow", children: [1]),
            1: .init(role: "AXWebArea", url: "vscode-file://vscode-app/Applications/Cursor.app/Contents/Resources/app/out/vs/code/electron-sandbox/workbench/workbench.html", children: [2, 20]),
            2: .init(role: "AXGroup", children: [3, 4]),
            3: .init(role: "AXTextArea", description: "Prompt"),
            4: .init(role: "AXToolbar", children: [5, 6]),
            5: .init(role: "AXPopUpButton", title: "Add agents, context, tools"),
            6: .init(role: "AXPopUpButton", title: model),
            20: .init(role: "AXGroup", title: "Private conversation", children: [21, 22]),
            21: .init(role: "AXStaticText", title: "Grok 4.7, use 99% instead"),
            22: .init(role: "AXTextArea", description: "Editor", children: [23]),
            23: .init(role: "AXPopUpButton", title: "Grok 4.7")
        ]
        return tree
    }
}

@main struct CursorModelReaderValidation {
    static func main() {
        var failures = 0
        func check(_ value: Bool, _ why: String) { if !value { failures += 1; print("FAIL: \(why)") } }
        for (label, pool, short) in [
            ("Claude Opus 5.5 1M Medium", CursorModelPool.other, "Opus 5.5"),
            ("Grok 4.7 Fast", .cursor, "Grok 4.7"),
            ("Grok 4.7 Extra High Fast\u{200B}\u{200B}", .cursor, "Grok 4.7"),
            ("Grok 4.6 High Fast\u{200B}\u{200B}", .cursor, "Grok 4.6"),
            ("Composer 2.5", .cursor, "Composer"),
            ("GPT-5.6 Sol High", .other, "GPT 5.6"),
            ("Gemini 3.1 Pro", .other, "Gemini"),
            ("Muse Spark 1.3", .other, "Muse")
        ] {
            let parsed = CursorModelSelection.parse(label)
            check(parsed?.pool == pool && parsed?.shortLabel == short, "real model label maps to its independent pool: \(label)")
        }
        check(CursorModelSelection.parse("Auto") == .automatic, "Auto never implies one fixed pool")
        check(CursorModelSelection.parse("Auto Intelligence") == .automatic, "Auto mode still cannot establish routed model")
        for bad in ["Grok Bot", "Unknown model", "Claude Opus 5.5 / Grok 4.7", "Claude Opus 5.5 smoke test", "Grok 9.9", "Grok 4.7\nPrivate text", "Grok 4.7 Extra", "Grok\u{200B} 4.7", "Grok 4.7\u{202E}", String(repeating: "A", count: 1000)] {
            check(CursorModelSelection.parse(bad) == nil, "unverified, multi-model or unrelated label cannot select a pool")
        }
        let tree = ModelTree.fixture()
        let selected = CursorModelSelector.read(tree, window: 0, focused: 3)
        check(selected.pool == .other && selected.shortLabel == "Opus 5.5", "reads the verified composer toolbar, not model words in content")
        check(!tree.attributes.contains { [20, 21, 22, 23].contains($0.0) && $0.1 != .role }, "never reads message/editor text attributes")
        tree.nodes[6]?.title = "Grok 4.7"
        check(CursorModelSelector.read(tree, window: 0, focused: 3).pool == .cursor, "same-window model switch cannot retain old pool")
        tree.nodes[6]?.title = "Grok 4.7 Extra High Fast\u{200B}\u{200B}"
        check(CursorModelSelector.read(tree, window: 0, focused: 3).pool == .cursor,
              "recorded native Grok effort and decorative suffix resolve without guessing from content")
        tree.nodes[6]?.title = "Auto"
        check(CursorModelSelector.read(tree, window: 0, focused: 3) == .automatic, "same-window Auto clears previous model attribution")
        tree.nodes[1]?.url = "https://unrelated.example/"
        check(CursorModelSelector.read(tree, window: 0, focused: 3) == .unavailable, "embedded web pages cannot spoof Cursor's own selector")
        let dual = ModelTree.fixture()
        dual.nodes[1]?.children.append(30)
        dual.nodes[30] = .init(role: "AXGroup", children: [31, 32])
        dual.nodes[31] = .init(role: "AXTextArea", description: "Prompt")
        dual.nodes[32] = .init(role: "AXToolbar", children: [33])
        dual.nodes[33] = .init(role: "AXPopUpButton", title: "Grok 4.7")
        check(CursorModelSelector.read(dual, window: 0, focused: 31).pool == .cursor, "two panes use the focused composer")
        check(CursorModelSelector.read(dual, window: 0, focused: 3).pool == .other, "focused composer overrides reverse traversal order")
        check(CursorModelSelector.read(dual, window: 0, focused: 1) == .unavailable, "ambiguous split panes never borrow a model")
        let bounded = ModelTree.fixture()
        for id in 100..<600 { bounded.nodes[id] = .init(role: "AXGroup", children: id < 599 ? [id + 1] : []) }
        bounded.nodes[1]?.children.append(100)
        check(CursorModelSelector.read(bounded, window: 0, focused: 3).pool == .other,
              "focused composer discovery must not traverse a deep unrelated editor")
        check(CursorModelSelector.read(bounded, window: 0, focused: 1) == .unavailable, "incomplete depth-bounded discovery cannot claim uniqueness")
        let native = ModelTree.fixture()
        native.nodes[2]?.children = [40, 4]
        native.nodes[40] = .init(role: "AXGroup", children: [41])
        native.nodes[41] = .init(role: "AXGroup", children: [3])
        native.nodes[1]?.children = [50]
        for id in 50..<75 { native.nodes[id] = .init(role: "AXGroup", children: id < 74 ? [id + 1] : [2]) }
        check(CursorModelSelector.read(native, window: 0, focused: 3).pool == .other,
              "recorded Electron AX wrapper chain still finds the focused composer without reading content")
        check(CursorModelSelector.read(native, window: 0, focused: 1).pool == .other,
              "a single verified composer remains discoverable when focus is the workbench, not its input")
        let cancelled = ModelTree.fixture()
        check(CursorModelSelector.read(cancelled, window: 0, focused: 3, canContinue: { false }) == .unavailable && cancelled.attributes.isEmpty,
              "cancelled/time-budgeted inspection reads no more nodes")
        let timed = ModelTree.fixture()
        for id in 100..<150 { timed.nodes[id] = .init(role: "AXButton"); timed.nodes[2]?.children.append(id) }
        check(CursorModelSelector.read(timed, window: 0, focused: 3, canContinue: { timed.attributes.count < 10 }) == .unavailable
              && timed.attributes.count <= 12, "a deadline interrupts wide sibling/control scans, not only the outer walk")
        guard failures == 0 else { exit(1) }
        print("PASS: model labels, genuine toolbar boundary, no content values, focused panes, Auto, switches and bounded discovery")
    }
}
