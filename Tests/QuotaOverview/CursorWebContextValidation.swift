import Foundation
#if !DIRECT_MODEL_TEST
@testable import PaulNotchCore
#endif

private final class WebTree: CursorModelTree {
    struct Node { var role: String; var title = ""; var description = ""; var url = ""; var children: [Int] = [] }
    var nodes: [Int: Node] = [:]
    var reads: [(Int, CursorModelAttribute)] = []
    var changesURLOnModelRead = false
    func string(_ element: Int, _ attribute: CursorModelAttribute) -> String? {
        reads.append((element, attribute))
        if changesURLOnModelRead && element == 10 && attribute == .title { nodes[3]?.url = "https://example.org/" }
        guard let node = nodes[element] else { return nil }
        switch attribute { case .role: return node.role; case .title: return node.title
        case .description: return node.description; case .url: return node.url }
    }
    func children(_ element: Int) -> [Int]? {
        guard let children = nodes[element]?.children, children.count <= 64 else { return nil }
        return children
    }
    func parent(_ element: Int) -> Int? { nodes.first { $0.value.children.contains(element) }?.key }
    func same(_ lhs: Int, _ rhs: Int) -> Bool { lhs == rhs }
    static func fixture(_ label: String = "Claude Sonnet 5.5 High") -> WebTree {
        let tree = WebTree()
        // Sanitized structure observed in Chrome: content group with a large
        // message sibling and one direct textarea/context/model/voice row.
        tree.nodes = [
            0: .init(role: "AXWindow", children: [1, 30]),
            1: .init(role: "AXGroup", children: [2]),
            2: .init(role: "AXScrollArea", children: [3]),
            3: .init(role: "AXWebArea", url: "https://cursor.com/agents/bc-00000000-0000-0000-0000-000000000001?branch=main&app=files", children: [4, 40]),
            4: .init(role: "AXGroup", children: [5, 6]),
            5: .init(role: "AXGroup", title: "PRIVATE CHAT", children: Array(100...226)),
            6: .init(role: "AXGroup", children: [7, 8, 9, 10, 11]),
            7: .init(role: "AXTextArea", description: "PRIVATE DRAFT"),
            8: .init(role: "AXStaticText", title: "Add a follow up"),
            9: .init(role: "AXPopUpButton", title: "Add context and tools"),
            10: .init(role: "AXPopUpButton", title: label),
            11: .init(role: "AXButton", title: "Start voice input"),
            30: .init(role: "AXToolbar", children: [31]),
            31: .init(role: "AXTextField", title: "PRIVATE ADDRESS BAR"),
            40: .init(role: "AXGroup", children: [41, 42]),
            41: .init(role: "AXTextArea", description: "UNRELATED EXTENSION"),
            42: .init(role: "AXPopUpButton", title: "Grok 4.7")
        ]
        return tree
    }
}

@main struct CursorWebContextValidation {
    static func main() {
        var failures = 0
        func check(_ value: Bool, _ reason: String) { if !value { failures += 1; print("FAIL: \(reason)") } }
        for (label, pool, short) in [("Claude Sonnet 5.5 High", CursorModelPool.other, "Sonnet"), ("Grok 4.7 Extra High Fast", .cursor, "Grok 4.7")] {
            let tree = WebTree.fixture(label)
            let result = CursorWebSelector.read(tree, window: 0, focused: 3)
            check(result.isCursorPage && result.selection.pool == pool && result.selection.shortLabel == short,
                  "official Chrome agent composer selects correct existing pool: \(label)")
            check(!tree.reads.contains { [5, 7, 8, 31, 41].contains($0.0) && $0.1 != .role }, "no chat, draft, placeholder or address field contents are read")
            check(!tree.reads.contains { $0.0 >= 100 }, "large conversation sibling is never traversed")
        }
        let change = WebTree.fixture()
        _ = CursorWebSelector.read(change, window: 0, focused: 7)
        change.nodes[10]?.title = "Auto"
        check(CursorWebSelector.read(change, window: 0, focused: 7).selection == .automatic, "Auto clears selected model without guessing routing")
        change.nodes[10]?.title = "Future Unknown Model"
        let unknown = CursorWebSelector.read(change, window: 0, focused: 7)
        check(unknown.isCursorPage && unknown.selection == .unavailable, "recognized Cursor page with unknown model still switches provider and keeps dual quota")
        for url in ["https://cursor.com/", "https://cursor.com/docs", "https://cursor.com/agents-evil/x", "https://cursor.com.evil.test/agents/x", "https://evil.test/?cursor.com/agents/x", "http://cursor.com/agents/x", "https://user@cursor.com/agents/x", "https://cursor.com:8443/agents/x", "https://cursor.com/%61gents/x", "https://cursor.com/agents/x/nested"] {
            let tree = WebTree.fixture(); tree.nodes[3]?.url = url
            let result = CursorWebSelector.read(tree, window: 0, focused: 7)
            check(!result.isCursorPage && result.selection == .unavailable, "non-agent or deceptive URL cannot select Cursor: \(url)")
            check(!tree.reads.contains { $0.0 == 10 }, "reject origin before inspecting models")
        }
        let nested = WebTree.fixture()
        nested.nodes[2]?.children = [50]
        nested.nodes[50] = .init(role: "AXWebArea", url: "https://unrelated.example/", children: [3])
        check(!CursorWebSelector.read(nested, window: 0, focused: 7).isCursorPage, "official iframe inside unrelated top page is rejected")
        let multiple = WebTree.fixture()
        multiple.nodes[2]?.children.append(51)
        multiple.nodes[51] = .init(role: "AXWebArea", url: "https://cursor.com/agents/another", children: [])
        check(!CursorWebSelector.read(multiple, window: 0, focused: 7).isCursorPage, "multiple exposed pages are ambiguous, never infer the active tab")
        let stale = WebTree.fixture(); stale.changesURLOnModelRead = true
        check(!CursorWebSelector.read(stale, window: 0, focused: 7).isCursorPage, "tab navigation during capture discards the old model")
        let two = WebTree.fixture()
        two.nodes[4]?.children.append(60)
        two.nodes[60] = .init(role: "AXGroup", children: [61, 62, 63])
        two.nodes[61] = .init(role: "AXTextArea")
        two.nodes[62] = .init(role: "AXPopUpButton", title: "Add context and tools")
        two.nodes[63] = .init(role: "AXPopUpButton", title: "Grok 4.7")
        check(CursorWebSelector.read(two, window: 0, focused: 3).selection == .unavailable, "two visible composers without focused choice never borrow a model")
        check(CursorWebSelector.read(two, window: 0, focused: 61).selection.pool == .cursor, "focused second composer selects its own model")
        for iframe in [false, true] {
            let foreign = WebTree.fixture()
            foreign.nodes[70] = .init(role: iframe ? "AXWebArea" : "AXMenu", url: "https://extension.invalid/", children: [71])
            foreign.nodes[71] = .init(role: "AXGroup", children: [72, 73, 74])
            foreign.nodes[72] = .init(role: "AXTextArea")
            foreign.nodes[73] = .init(role: "AXPopUpButton", title: "Add context and tools")
            foreign.nodes[74] = .init(role: "AXPopUpButton", title: "Grok 4.7")
            foreign.nodes[iframe ? 3 : 0]?.children.append(70)
            let result = CursorWebSelector.read(foreign, window: 0, focused: 72)
            check(result.selection.pool == .other, "foreign focus must not replace the verified official composer")
            check(!foreign.reads.contains { [73, 74].contains($0.0) && $0.1 != .role },
                  "prove focus belongs to the official document before reading popup labels (iframe: \(iframe))")
        }
        let conflict = WebTree.fixture(); conflict.nodes[10]?.description = "Grok 4.7"
        check(CursorWebSelector.read(conflict, window: 0, focused: 7).selection == .unavailable, "conflicting popup labels fail closed")
        let cancelled = WebTree.fixture()
        check(!CursorWebSelector.read(cancelled, window: 0, focused: 3, canContinue: { false }).isCursorPage && cancelled.reads.isEmpty, "cancelled capture performs no more reads")
        let timeout = WebTree.fixture()
        check(!CursorWebSelector.read(timeout, window: 0, focused: 3, canContinue: { timeout.reads.count < 6 }).isCursorPage, "time budget fails closed")
        guard failures == 0 else { exit(1) }
        print("PASS: real Chrome structure, current official agent page, composer model, navigation races, ambiguity, privacy and bounded traversal")
    }
}
