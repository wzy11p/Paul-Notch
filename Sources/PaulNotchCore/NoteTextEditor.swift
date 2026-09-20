import AppKit
import SwiftUI

/// Owns the native editing buffer. SwiftUI status updates must never replace an
/// active IME composition, selection or undo history.
struct NoteTextEditor: NSViewRepresentable {
    let draftID: UUID
    let text: String
    let isEditable: Bool
    let focusRequest: Int
    let onEdit: (UUID, String, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(draftID: draftID, onEdit: onEdit) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let editor = CompositionNoteTextView(frame: .zero)
        editor.observeUndo()
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 16)
        editor.textColor = .labelColor
        editor.insertionPointColor = .labelColor
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainerInset = NSSize(width: 6, height: 8)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        editor.defaultParagraphStyle = paragraph
        editor.typingAttributes = [.font: NSFont.systemFont(ofSize: 16),
                                  .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        editor.setAccessibilityLabel("随笔正文")
        editor.delegate = context.coordinator
        editor.onBufferChanged = { [weak coordinator = context.coordinator] editor in
            coordinator?.publish(editor)
        }
        context.coordinator.synchronize(editor, draftID: draftID, text: text)
        editor.isEditable = isEditable
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? CompositionNoteTextView else { return }
        let coordinator = context.coordinator
        coordinator.onEdit = onEdit
        coordinator.synchronize(editor, draftID: draftID, text: text)
        if editor.isEditable != isEditable { editor.isEditable = isEditable }
        coordinator.requestFocus(editor, request: focusRequest, draftID: draftID)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        guard let editor = scroll.documentView as? CompositionNoteTextView else { return }
        // Composition snapshots already reached the draft. Detach callbacks before
        // teardown; a late input-method notification must not affect another note.
        editor.onBufferChanged = nil
        editor.delegate = nil
        coordinator.focusGeneration += 1
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        private(set) var draftID: UUID
        var onEdit: (UUID, String, Bool) -> Void
        private var applyingModel = false
        private var lastText: String?
        private var lastMarked = false
        private var consumedFocus: Int?
        var focusGeneration = 0

        init(draftID: UUID, onEdit: @escaping (UUID, String, Bool) -> Void) {
            self.draftID = draftID
            self.onEdit = onEdit
        }

        func synchronize(_ editor: CompositionNoteTextView, draftID: UUID, text: String) {
            let changedDraft = self.draftID != draftID
            // A status/autosave/hover refresh has no authority over marked text.
            guard changedDraft || (!editor.hasMarkedText() && editor.inputDepth == 0) else { return }
            guard changedDraft || editor.string != text else { return }
            applyingModel = true
            defer { applyingModel = false }
            if changedDraft {
                editor.unmarkText()
                editor.inputContext?.discardMarkedText()
                self.draftID = draftID
                focusGeneration += 1
            }
            let previousSelection = editor.selectedRange()
            editor.string = text
            editor.undoManager?.removeAllActions()
            let length = (text as NSString).length
            let location = changedDraft ? length : min(previousSelection.location, length)
            let selectionLength = changedDraft ? 0 : min(previousSelection.length, length - location)
            editor.setSelectedRange(NSRange(location: location, length: selectionLength))
            lastText = text
            lastMarked = false
        }

        func publish(_ editor: CompositionNoteTextView) {
            guard !applyingModel, editor.inputDepth == 0,
                  editor.undoManager?.isUndoing != true, editor.undoManager?.isRedoing != true else { return }
            let marked = editor.hasMarkedText()
            guard editor.string != lastText || marked != lastMarked else { return }
            lastText = editor.string
            lastMarked = marked
            // Retain the visible composition in the draft as a recovery snapshot,
            // but the store cannot record it until the IME commits or unmarks it.
            onEdit(draftID, editor.string, marked)
        }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? CompositionNoteTextView else { return }
            publish(editor)
        }

        func requestFocus(_ editor: CompositionNoteTextView, request: Int, draftID: UUID) {
            guard editor.isEditable, consumedFocus != request else { return }
            consumedFocus = request
            focusGeneration += 1
            let generation = focusGeneration
            DispatchQueue.main.async { [weak self, weak editor] in
                guard let self, let editor, self.focusGeneration == generation,
                      self.draftID == draftID, editor.isEditable,
                      let window = editor.window, window.firstResponder !== editor else { return }
                window.makeFirstResponder(editor)
            }
        }
    }
}

/// Marked-text methods can emit delegate notifications before the input method
/// has finished changing its ranges. Publish once the outermost operation ends.
final class CompositionNoteTextView: NSTextView {
    var onBufferChanged: ((CompositionNoteTextView) -> Void)?
    private(set) var inputDepth = 0
    private let localUndo = UndoManager()
    override var undoManager: UndoManager? { localUndo }

    func observeUndo() {
        for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(undoFinished), name: name, object: localUndo)
        }
    }

    @objc private func undoFinished(_ notification: Notification) {
        // UndoManager sends this notification before clearing isUndoing/isRedoing.
        // Publish the settled native buffer on the next main-loop turn.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onBufferChanged?(self)
        }
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        inputDepth += 1
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        inputDepth -= 1
        if inputDepth == 0 { onBufferChanged?(self) }
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        inputDepth += 1
        super.insertText(string, replacementRange: replacementRange)
        inputDepth -= 1
        if inputDepth == 0 { onBufferChanged?(self) }
    }

    override func unmarkText() {
        inputDepth += 1
        super.unmarkText()
        inputDepth -= 1
        if inputDepth == 0 { onBufferChanged?(self) }
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            if hasMarkedText() { unmarkText() }
            onBufferChanged?(self)
        }
        return resigned
    }
}
