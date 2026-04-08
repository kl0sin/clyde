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

    init(contentRect: NSRect) {
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
}
