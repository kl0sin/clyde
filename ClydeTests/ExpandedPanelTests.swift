import XCTest
import AppKit
@testable import Clyde

/// The expanded panel is a fixed-size surface. It has no resize control
/// and every layout decision around it — the widget anchor gap, the slide
/// animation, the screen-edge clamping — assumes it stays exactly the size
/// it was created with.
///
/// v0.8.0 shipped a build where it did not. The panel came up 400×1476 on
/// a 400×420 window: over three times its height, running off the bottom
/// of the screen with the Activity bar out of reach. It never reproduced
/// on the development machine, because the released binary is built
/// against an older macOS SDK whose SwiftUI reports a different fitting
/// size for the session list, and AppKit sized the window to it.
///
/// So the panel now refuses. Nothing outside it needs to be right about
/// sizing for the panel to be the size it says it is.
final class ExpandedPanelTests: XCTestCase {

    private let fixed = NSSize(width: 400, height: 420)

    private func makePanel() -> ExpandedPanel {
        ExpandedPanel(contentRect: NSRect(origin: NSPoint(x: 100, y: 100), size: NSSize(width: 400, height: 420)))
    }

    func testPanelKeepsItsSizeWhenSomethingTriesToGrowIt() {
        let panel = makePanel()

        panel.setFrame(NSRect(x: 100, y: 100, width: 400, height: 1476), display: false)

        XCTAssertEqual(panel.frame.size, fixed, "the shipped bug, in one line")
    }

    /// Moving is the whole point of the panel — it follows the widget
    /// around the screen. Only the size is pinned.
    func testPanelStillMoves() {
        let panel = makePanel()

        panel.setFrame(NSRect(x: 640, y: 480, width: 400, height: 420), display: false)

        XCTAssertEqual(panel.frame.origin, NSPoint(x: 640, y: 480))
        XCTAssertEqual(panel.frame.size, fixed)
    }

    /// A resize request that also moves the window must keep the move and
    /// drop only the resize: the slide-in animation sets both at once.
    func testAMoveWithABadSizeKeepsTheMove() {
        let panel = makePanel()

        panel.setFrame(NSRect(x: 300, y: 200, width: 400, height: 900), display: false)

        XCTAssertEqual(panel.frame.origin, NSPoint(x: 300, y: 200))
        XCTAssertEqual(panel.frame.size, fixed)
    }

    func testContentSizeIsPinnedToo() {
        let panel = makePanel()

        panel.setContentSize(NSSize(width: 400, height: 1476))

        XCTAssertEqual(panel.frame.size, fixed)
    }
    // MARK: - The widget panel, same exposure

    /// The widget is 130×46 and the comment beside it records an earlier
    /// incident of exactly this kind: SwiftUI content pushing the panel a
    /// few points taller, which drifts the anchor maths that positions the
    /// expanded panel beside it. It was corrected with the same one-shot
    /// setFrame that failed to hold for the expanded panel in v0.8.0, so
    /// it gets the same refusal rather than waiting for its turn.
    func testWidgetPanelKeepsItsSize() {
        let widget = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 130, height: 46))

        widget.setFrame(NSRect(x: 40, y: 60, width: 130, height: 300), display: false)

        XCTAssertEqual(widget.frame.size, NSSize(width: 130, height: 46))
        XCTAssertEqual(widget.frame.origin, NSPoint(x: 40, y: 60), "dragging the widget still works")
    }

}
