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

    /// Compute where the expanded view should appear, given its target
    /// size, the visible screen rect and the collapsed widget size.
    ///
    /// Strategy:
    ///   1. Pick horizontal anchor (left vs right edge of widget) based
    ///      on which screen half the widget centre is in.
    ///   2. Try to expand UP from the widget (default macOS pattern).
    ///   3. If the upward expansion would go above the screen, expand
    ///      DOWN from the widget bottom instead.
    ///   4. Clamp to visible bounds in case neither direction fits.
    func expandedOrigin(
        for size: NSSize,
        in screen: NSRect,
        collapsedSize: NSSize
    ) -> NSPoint {
        // --- Horizontal: pick anchor side ---
        let widgetCenterX = origin.x + collapsedSize.width / 2
        let preferRight = widgetCenterX > screen.midX

        let leftAlignedX = origin.x
        let rightAlignedX = origin.x + collapsedSize.width - size.width

        var x = preferRight ? rightAlignedX : leftAlignedX

        // If the preferred side would push the expanded view off the
        // opposite edge, swap to the other alignment.
        if x < screen.minX { x = leftAlignedX }
        if x + size.width > screen.maxX { x = rightAlignedX }

        // --- Vertical: pick direction ---
        let widgetTopY = origin.y + collapsedSize.height
        let widgetBottomY = origin.y

        // Default: expand upward from the widget's top edge.
        // The expanded view's TOP edge sits at widgetTopY, so its origin
        // (bottom-left in AppKit coords) is widgetTopY - size.height.
        let upY = widgetTopY - size.height
        // Alternative: expand downward from the widget's bottom edge.
        // The expanded view's TOP edge sits at widgetBottomY, so its
        // origin is widgetBottomY - size.height.
        let downwardOriginY = widgetBottomY - size.height

        var y: CGFloat
        if upY >= screen.minY {
            y = upY                  // upward fits, prefer it
        } else if downwardOriginY + size.height <= screen.maxY {
            y = downwardOriginY      // upward doesn't fit, downward does
        } else {
            // Neither direction fits cleanly — clamp to visible bounds.
            y = max(screen.minY, screen.maxY - size.height)
        }

        // --- Final clamp ---
        x = max(screen.minX, min(x, screen.maxX - size.width))
        y = max(screen.minY, min(y, screen.maxY - size.height))

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
