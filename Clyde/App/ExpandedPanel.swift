import AppKit

/// NSPanel hosting the rich expanded view (session list + activity timeline
/// + summary bar) and the Settings screen. It's a sibling of the widget
/// `FloatingPanel` — they live independently and animate independently.
///
/// The expanded panel only exists while the user is interacting with the
/// expanded UI. When the user collapses it, AppDelegate animates its
/// `alphaValue` to 0 and `orderOut`s it; on the next expand it's positioned
/// next to the current widget anchor and faded back in.
final class ExpandedPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The one size this panel is ever allowed to be.
    ///
    /// `minSize`/`maxSize` do not cover this: they constrain the user's
    /// resize handles, which a borderless panel does not even have, and
    /// AppKit sizes a window to its content view's fitting size regardless.
    /// v0.8.0 shipped a build where that produced a 400×1476 panel — over
    /// three times its height, hanging off the bottom of the screen with
    /// the Activity bar out of reach — while the same source built on the
    /// development machine was correct. The released binary is compiled
    /// against an older macOS SDK whose SwiftUI reports a different
    /// fitting size for the scrollable session list, so the defect was
    /// invisible everywhere except in the artifact users install.
    ///
    /// Refusing here is the fix that does not depend on which SwiftUI
    /// computed what: the panel is a fixed surface, so it declines to be
    /// anything else. Position still moves freely — that is the panel's
    /// whole job.
    private let fixedSize: NSSize

    init(contentRect: NSRect) {
        fixedSize = contentRect.size
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .floating
        isFloatingPanel = true
        // Background-drag is disabled because SessionListView relies on
        // SwiftUI onDrag/onDrop for row reordering — letting the whole
        // background move the window would hijack those gestures. The
        // header drag is implemented manually via an NSEvent monitor in
        // AppDelegate so it only triggers in the title-bar strip.
        isMovableByWindowBackground = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(NSRect(origin: frameRect.origin, size: fixedSize), display: flag)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool, animate: Bool) {
        super.setFrame(NSRect(origin: frameRect.origin, size: fixedSize),
                       display: flag, animate: animate)
    }

    override func setContentSize(_ size: NSSize) {
        super.setContentSize(fixedSize)
    }
}
