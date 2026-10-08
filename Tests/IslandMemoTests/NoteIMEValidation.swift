import AppKit
import SwiftUI

private struct TestNoteSurface: View {
    @ObservedObject var notes: NoteStore
    var body: some View {
        VStack {
            NoteTextEditor(draftID: notes.draft.id, text: notes.draft.body,
                           isEditable: notes.isLoaded && !notes.isSaving, focusRequest: 0) { id, body, marked in
                notes.updateComposition(marked, forDraftID: id)
                notes.updateBody(body, forDraftID: id)
            }
            .id(notes.draft.id)
            Text(notes.status)
        }.frame(width: 480, height: 240).padding(16)
            .foregroundStyle(.white).background(Color(white: 0.10))
            .preferredColorScheme(.dark)
    }
}

@main struct NoteIMEValidation {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let repository = LocalNoteRepository(directory: root)
        let store = NoteStore(repository: repository)
        await store.load()
        store.updateBody("测试🙂\n中间插入")
        let host = NSHostingView(rootView: TestNoteSurface(notes: store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host // Offscreen only; never launch a parallel preview app.
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        func find(_ view: NSView) -> CompositionNoteTextView? {
            if let editor = view as? CompositionNoteTextView { return editor }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        guard var editor = find(host) else { fatalError("No native editor") }
        window.makeFirstResponder(editor)
        let original = editor.string
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        editor.setMarkedText("pinyin", selectedRange: NSRange(location: 6, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        let composed = editor.string
        let markedRange = editor.markedRange()
        let selection = editor.selectedRange()
        precondition(editor.hasMarkedText(), "Marked input did not start")
        precondition(!store.canCommit, "Store did not receive composing state")
        precondition(store.draft.body == composed, "Recovery snapshot must include visible composition")
        let earlyCommit = await store.commit()
        precondition(!earlyCommit, "Cannot record unfinished composition")
        store.select(nil) // Selecting the same new draft must not clear composition protection.
        precondition(!store.canCommit)
        try await Task.sleep(for: .milliseconds(750))
        precondition(editor.string == composed && editor.hasMarkedText(), "Autosave changed marked text")
        precondition(editor.markedRange() == markedRange && editor.selectedRange() == selection)
        for _ in 0..<4 { store.objectWillChange.send(); try await Task.sleep(for: .milliseconds(40)) }
        precondition(editor.string == composed && editor.hasMarkedText(), "Refresh destroyed composition")
        precondition(editor.selectedRange() == selection, "Refresh moved the candidate caret")
        print("PASS: composition, cursor and marked range survive autosave and repeated refresh; early record blocked")

        // Simulate an IME editing its preedit (backspace), then committing a candidate.
        editor.setMarkedText("pin", selectedRange: NSRange(location: 3, length: 0), replacementRange: editor.markedRange())
        store.objectWillChange.send()
        try await Task.sleep(for: .milliseconds(80))
        precondition(editor.hasMarkedText() && editor.string.contains("pin"))
        editor.insertText("拼音", replacementRange: editor.markedRange())
        let expected = "测试拼音🙂\n中间插入"
        try await Task.sleep(for: .milliseconds(400))
        precondition(!editor.hasMarkedText() && editor.string == expected && store.draft.body == expected)
        precondition(store.canCommit)
        await store.flushDraft()
        let restored = NoteStore(repository: LocalNoteRepository(directory: root))
        await restored.load()
        precondition(restored.draft.body == expected)
        print("PASS: preedit correction, candidate commit, emoji/multiline/middle insertion and disk restore")
        host.layoutSubtreeIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("native-ime-editor.png"))
        }

        // Plain text editing must keep native undo and selection across status updates.
        editor.breakUndoCoalescing()
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.insertText("追加", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.breakUndoCoalescing()
        try await Task.sleep(for: .milliseconds(400))
        precondition(editor.undoManager?.canUndo == true)
        editor.undoManager?.undo()
        try await Task.sleep(for: .milliseconds(100))
        if editor.string != expected || store.draft.body != expected {
            let summary = "UNDO diagnostic: editorExact=\(editor.string == expected) storeExact=\(store.draft.body == expected) editorLength=\((editor.string as NSString).length) expectedLength=\((expected as NSString).length) undoLevel=\(editor.undoManager?.groupingLevel ?? -1)\n"
            FileHandle.standardOutput.write(Data(summary.utf8))
        }
        precondition(editor.string == expected && store.draft.body == expected, "Undo lost prior composition")
        editor.undoManager?.redo()
        try await Task.sleep(for: .milliseconds(100))
        precondition(editor.string == expected + "追加" && store.draft.body == editor.string)
        let oldID = store.draft.id
        let oldEditor = editor
        let committed = await store.commit()
        precondition(committed)
        try await Task.sleep(for: .milliseconds(100))
        guard let nextEditor = find(host) else { fatalError("No new draft editor") }
        editor = nextEditor
        precondition(editor !== oldEditor && oldEditor.onBufferChanged == nil, "Old IME session remains connected")
        oldEditor.insertText("late old IME", replacementRange: NSRange(location: NSNotFound, length: 0))
        precondition(editor.string.isEmpty && store.draft.id != oldID)
        store.updateBody("stale synthetic event", forDraftID: oldID)
        store.updateComposition(true, forDraftID: oldID)
        precondition(store.draft.body.isEmpty && store.composingDraftID == nil)
        precondition(editor.undoManager?.canUndo == false, "Undo leaked between drafts")
        print("PASS: undo/redo, record/new draft identity, stale callback rejection and undo isolation")

        // Move away while composing: retain the visible old draft without writing it into the destination.
        let pendingID = store.draft.id
        editor.setMarkedText("weixuan", selectedRange: NSRange(location: 7, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        let pending = editor.string
        guard let saved = store.notes.first else { fatalError("Missing recorded fixture") }
        store.select(saved)
        try await Task.sleep(for: .milliseconds(120))
        guard let savedEditor = find(host) else { fatalError("No saved note editor") }
        editor = savedEditor
        precondition(editor.string == saved.body && !editor.hasMarkedText())
        precondition(store.library.drafts["new"]?.body == pending)
        store.updateBody("late old callback", forDraftID: pendingID)
        precondition(store.draft.body == saved.body)
        store.select(nil)
        try await Task.sleep(for: .milliseconds(120))
        guard let pendingEditor = find(host) else { fatalError("No pending draft editor") }
        editor = pendingEditor
        precondition(editor.string == pending && !editor.hasMarkedText() && store.canCommit)
        editor.selectAll(nil)
        editor.insertText("", replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(80))
        precondition(editor.string.isEmpty && store.draft.body.isEmpty)
        // Repeated composition cancellation and rapid committed input must not resurrect old text.
        editor.setMarkedText("ceshi", selectedRange: NSRange(location: 5, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: editor.markedRange())
        editor.unmarkText()
        for piece in ["快速", "输入", "🙂", "\n第二行"] {
            editor.insertText(piece, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        try await Task.sleep(for: .milliseconds(450))
        precondition(editor.string == "快速输入🙂\n第二行" && store.draft.body == editor.string)
        await store.flushDraft()
        print("PASS: navigation preserves unfinished draft literally, destination protected, deletion/cancellation/rapid typing retained")
        precondition(original == "测试🙂\n中间插入")
        window.contentView = nil
        print("All synthetic IME bridge tests passed. Real input-method candidate UI is a separate acceptance test.")
    }
}
