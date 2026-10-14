import AppKit

/// Only Paul's two borderless surfaces may occupy the physical menu-bar band.
/// AppKit normally pushes a requested top-attached frame down to visibleFrame.
@MainActor class ScreenTopPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        if let screen, screen.frame.contains(frameRect) { return frameRect }
        return super.constrainFrameRect(frameRect, to: screen)
    }
}
