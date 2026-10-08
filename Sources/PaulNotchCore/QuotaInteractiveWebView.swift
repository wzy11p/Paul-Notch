import AppKit
import WebKit

/// WebKit already requests a key panel, but normally drops the click which
/// activates it. An owned login inside the notch must focus on that same click.
/// This grants no focus on appearance, navigation or background quota reads.
@MainActor final class QuotaInteractiveWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Accessory panels lack an Edit menu. Forward standard edit actions only
    /// to the focused owned WebKit responder, never a different window/editor.
    static func performEditingKeyEquivalent(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard window.isKeyWindow, window.isVisible, event.type == .keyDown,
              event.modifierFlags.contains(.command),
              event.modifierFlags.intersection([.option, .control]).isEmpty,
              let responder = window.firstResponder as? NSView else { return false }
        var ancestor: NSView? = responder
        while let view = ancestor {
            if view is QuotaInteractiveWebView, view.window === window,
               !view.isHiddenOrHasHiddenAncestor {
                let key = event.charactersIgnoringModifiers?.lowercased()
                let shifted = event.modifierFlags.contains(.shift)
                let action: Selector?
                switch key {
                case "a" where !shifted: action = #selector(NSText.selectAll(_:))
                case "c" where !shifted: action = #selector(NSText.copy(_:))
                case "v" where !shifted: action = #selector(NSText.paste(_:))
                case "x" where !shifted: action = #selector(NSText.cut(_:))
                case "z": action = NSSelectorFromString(shifted ? "redo:" : "undo:")
                default: action = nil
                }
                guard let action, responder.responds(to: action) else { return false }
                // WebKit owns the clipboard/selection/undo operation. Paul
                // does not read the pasteboard or inject field contents.
                return NSApp.sendAction(action, to: responder, from: window)
            }
            ancestor = view.superview
        }
        return false
    }

    override func mouseDown(with event: NSEvent) {
        if let window, event.window === window, window.isVisible,
           !window.ignoresMouseEvents, !isHiddenOrHasHiddenAncestor,
           bounds.contains(convert(event.locationInWindow, from: nil)) {
            // A nonactivating notch can leave WebKit's DOM focused while the
            // previous application still owns keyboard delivery. Claim input
            // only for this explicit native click, before WebKit handles it.
            // Loading, DOM focus(), popup creation and hidden quota reads do
            // not enter this path and cannot activate Paul in the background.
            window.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
        super.mouseDown(with: event)
    }
}
