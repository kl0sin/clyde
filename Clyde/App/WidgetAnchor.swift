import AppKit

/// Single source of truth for the widget's position on screen. The
/// floating panel can be in two states (collapsed widget or expanded
/// session list) but the *anchor* — the point where the user wants the
/// widget to live — must stay stable across transitions and across user
/// drags of either window.
///
/// Historically the AppDelegate juggled an optional `savedWidgetOrigin`
/// that was updated from multiple async paths (windowDidMove debounce,
/// snap completion handler, transition fall-through). That created a
/// race where opening + closing the expanded view could leave the
/// widget in a slightly different spot than the user had placed it.
///
/// `WidgetAnchor` is a small value type that encapsulates the position
/// plus the helpers to compute the expanded-view frame from it (with
/// smart screen-space placement) and to back-derive an anchor from a
/// dragged expanded frame.
struct WidgetAnchor: Equatable {
    /// Bottom-left corner of the collapsed widget in screen coordinates
    /// (AppKit convention — origin in the bottom-left of the screen).
    var origin: NSPoint

    init(origin: NSPoint) {
        self.origin = origin
    }

    /// Frame gap when the expanded panel sits BELOW the widget
    /// (drop-down). Same as the pop-up gap — empirically the system
    /// shadows on both sides of the gap end up eating about the
    /// same amount, so symmetric frame gaps read symmetric on screen.
    static let panelGapBelow: CGFloat = 6

    /// Frame gap when the expanded panel sits ABOVE the widget
    /// (pop-up).
    static let panelGapAbove: CGFloat = 6

    /// Compute where the expanded view should appear, given its target
    /// size, the visible screen rect and the collapsed widget size.
    ///
    /// In the dual-panel architecture the expanded view is a sibling
    /// window, never the same window as the widget. So unlike the old
    /// single-panel design, the two must NOT overlap.
    ///
    /// Strategy:
    ///   1. Pick a horizontal alignment: align the expanded panel's
    ///      LEFT edge with the widget's LEFT edge when the widget is on
    ///      the left half of the screen, otherwise align RIGHT edges.
    ///      If the chosen side would push the expanded panel off the
    ///      opposite screen edge, swap to the other alignment.
    ///   2. Try to drop the expanded view DOWN from the widget bottom
    ///      (the natural macOS dropdown pattern). If the panel wouldn't
    ///      fit between the widget bottom and the screen bottom, pop
    ///      it UP above the widget instead.
    ///   3. Clamp to visible bounds in case neither direction fits.
    func expandedOrigin(
        for size: NSSize,
        in screen: NSRect,
        collapsedSize: NSSize
    ) -> NSPoint {
        // --- Horizontal: pick the alignment that touches the screen
        //     edge nearest the widget, so the panel grows inward. ---
        let widgetCenterX = origin.x + collapsedSize.width / 2
        let preferRight = widgetCenterX > screen.midX

        let leftAlignedX = origin.x
        let rightAlignedX = origin.x + collapsedSize.width - size.width

        var x = preferRight ? rightAlignedX : leftAlignedX

        // If the preferred side would push the expanded view off the
        // opposite edge, swap to the other alignment.
        if x < screen.minX { x = leftAlignedX }
        if x + size.width > screen.maxX { x = rightAlignedX }

        // --- Vertical: prefer dropping DOWN from the widget bottom,
        //     fall back to popping UP above the widget top, never
        //     overlap the widget. ---
        let widgetTopY = origin.y + collapsedSize.height
        let widgetBottomY = origin.y

        // Drop down: expanded TOP edge sits at widgetBottomY - panelGapBelow
        // → expanded origin = widgetBottomY - panelGapBelow - size.height.
        let downY = widgetBottomY - Self.panelGapBelow - size.height

        // Pop up: expanded BOTTOM edge sits at widgetTopY + panelGapAbove
        // → expanded origin = widgetTopY + panelGapAbove. Larger gap
        // here compensates for the expanded view's heavy bottom shadow.
        let upY = widgetTopY + Self.panelGapAbove

        // Available space in each direction (without the panel gap).
        let spaceBelow = widgetBottomY - screen.minY
        let spaceAbove = screen.maxY - widgetTopY

        var y: CGFloat
        if downY >= screen.minY {
            // Cleanly drops down inside the visible area. Preferred.
            y = downY
        } else if upY + size.height <= screen.maxY {
            // Doesn't fit downward — pop up above the widget instead.
            y = upY
        } else {
            // Neither direction fits the full panel inside the visible
            // area. Pick whichever side has MORE space and use the
            // properly-gapped position for THAT direction. The expanded
            // panel may extend beyond the screen edge, but it will
            // never overlap the widget — the gap is preserved.
            if spaceAbove >= spaceBelow {
                y = upY     // pop up; may clip above screen
            } else {
                y = downY   // drop down; may clip below screen
            }
        }

        // --- Final horizontal clamp (vertical is intentionally NOT
        //     clamped because clamping could push the panel into the
        //     widget area; we'd rather see the panel get clipped at
        //     the screen edge than overlap the widget) ---
        x = max(screen.minX, min(x, screen.maxX - size.width))

        return NSPoint(x: x, y: y)
    }

    /// Reverse calculation: given an expanded frame the user has dragged
    /// to a new position, derive what the widget anchor should become so
    /// that collapsing snaps the widget to a sensible spot near the
    /// dragged expanded view.
    static func from(
        expandedFrame: NSRect,
        in screen: NSRect,
        collapsedSize: NSSize
    ) -> WidgetAnchor {
        // Match the same anchor-side rule used during expansion: which
        // screen half is the expanded view's centre in?
        let expandedCenterX = expandedFrame.midX
        let preferRight = expandedCenterX > screen.midX

        let widgetX: CGFloat
        if preferRight {
            // Right-aligned: expanded.x + expanded.width == widget.x + collapsed.width
            widgetX = expandedFrame.maxX - collapsedSize.width
        } else {
            // Left-aligned: expanded.x == widget.x
            widgetX = expandedFrame.minX
        }

        // Vertical: assume the expanded view was opened upward from the
        // widget. Then expanded.y + expanded.height == widget.y + collapsed.height
        // → widget.y = expanded.y + expanded.height - collapsed.height
        var widgetY = expandedFrame.maxY - collapsedSize.height

        // Clamp inside visible bounds.
        let clampedX = max(
            screen.minX,
            min(widgetX, screen.maxX - collapsedSize.width)
        )
        widgetY = max(
            screen.minY,
            min(widgetY, screen.maxY - collapsedSize.height)
        )

        return WidgetAnchor(origin: NSPoint(x: clampedX, y: widgetY))
    }
}
