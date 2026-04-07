import AppKit

/// Renders the Clyde mascot as a template NSImage for the macOS menu bar.
///
/// Template images are monochrome masks that macOS tints according to the
/// current menu bar appearance (dark/light/transparent), which is why this
/// drops all the colour detail from `ClydeSprite.body` and just paints any
/// non-transparent pixel in solid black.
enum ClydeMenuBarIcon {
    /// Produces an `NSImage` with `isTemplate = true`. The default size of
    /// 18pt matches macOS' standard menu bar extra icon footprint.
    /// Used as a fallback when there are no live Clyde sessions to render
    /// the richer status capsule for.
    static func templateImage(size: CGFloat = 18) -> NSImage {
        let sprite = ClydeSprite.body
        let gridSize = 16
        let pxSize = size / CGFloat(gridSize)

        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            NSColor.black.setFill()
            for row in 0..<gridSize {
                for col in 0..<gridSize {
                    guard sprite[row][col] != nil else { continue }
                    let rect = NSRect(
                        x: CGFloat(col) * pxSize,
                        y: size - CGFloat(row + 1) * pxSize,
                        width: pxSize,
                        height: pxSize
                    )
                    rect.fill()
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// Dominant state expressed as a tuple of (kind, count). Used by the menu
/// bar status capsule to pick its colour and digit.
enum ClydeStatusKind {
    case ready
    case working
    case attention

    /// Foreground digit colour — bright, slightly desaturated for the
    /// menu bar context.
    var foreground: NSColor {
        switch self {
        case .ready:     return NSColor(red: 0.42, green: 1.00, blue: 0.55, alpha: 1)
        case .working:   return NSColor(red: 0.88, green: 0.65, blue: 1.00, alpha: 1)
        case .attention: return NSColor(red: 0.62, green: 0.78, blue: 1.00, alpha: 1)
        }
    }

    /// Two-stop background gradient (top → bottom).
    var gradientTop: NSColor {
        switch self {
        case .ready:     return NSColor(red: 0.37, green: 0.91, blue: 0.52, alpha: 0.32)
        case .working:   return NSColor(red: 0.85, green: 0.61, blue: 1.00, alpha: 0.34)
        case .attention: return NSColor(red: 0.48, green: 0.72, blue: 1.00, alpha: 0.36)
        }
    }
    var gradientBottom: NSColor {
        switch self {
        case .ready:     return NSColor(red: 0.18, green: 0.65, blue: 0.30, alpha: 0.20)
        case .working:   return NSColor(red: 0.61, green: 0.25, blue: 0.88, alpha: 0.22)
        case .attention: return NSColor(red: 0.14, green: 0.39, blue: 0.83, alpha: 0.22)
        }
    }
    /// Inset stroke colour (~0.5pt rim).
    var rim: NSColor {
        switch self {
        case .ready:     return NSColor(red: 0.37, green: 0.91, blue: 0.52, alpha: 0.55)
        case .working:   return NSColor(red: 0.85, green: 0.61, blue: 1.00, alpha: 0.60)
        case .attention: return NSColor(red: 0.48, green: 0.72, blue: 1.00, alpha: 0.65)
        }
    }
}

/// Renders the rich D2 menu bar status capsule:
/// rounded gradient block with the Clyde sprite as a subtle watermark
/// on the left and the dominant-state count on the right.
enum ClydeMenuBarStatus {
    /// Layout constants — kept here so all the drawing code references
    /// the same numbers.
    private static let height: CGFloat = 20
    private static let cornerRadius: CGFloat = 6
    private static let horizontalPadding: CGFloat = 6
    private static let spriteSize: CGFloat = 13
    /// Gap between sprite and count digits.
    private static let spriteToCountGap: CGFloat = 6
    /// Right padding after the count digits inside the capsule.
    private static let trailingPadding: CGFloat = 7
    /// Gap between the capsule and the tick column.
    private static let capsuleToTicksGap: CGFloat = 4
    /// Visual size of one tick (the small bar showing a non-dominant state).
    private static let tickWidth: CGFloat = 10
    private static let tickHeight: CGFloat = 2
    /// Vertical gap between the two stacked ticks.
    private static let tickGap: CGFloat = 3
    /// Padding after the ticks so they don't kiss the menu bar edge.
    private static let ticksTrailingPadding: CGFloat = 2

    /// Build the status image showing the dominant state inside the capsule
    /// and the two non-dominant states as colored ticks on the right.
    /// Pass live counts for each state. The dominant state is selected with
    /// priority attention > working > ready.
    /// The image is *not* a template — it carries colour information.
    static func image(attention: Int, working: Int, ready: Int) -> NSImage {
        // Pick dominant by priority. The other two become ticks, in stable
        // order (attention, working, ready, minus the dominant).
        let dominantKind: ClydeStatusKind
        let dominantCount: Int
        if attention > 0 {
            dominantKind = .attention
            dominantCount = attention
        } else if working > 0 {
            dominantKind = .working
            dominantCount = working
        } else {
            dominantKind = .ready
            dominantCount = ready
        }

        let allTicks: [(kind: ClydeStatusKind, count: Int)] = [
            (.attention, attention),
            (.working, working),
            (.ready, ready),
        ]
        let ticks = allTicks.filter { $0.kind != dominantKind }

        let countText = "\(dominantCount)"
        let digitFont = NSFont.systemFont(ofSize: 12, weight: .heavy)
        let digitAttrs: [NSAttributedString.Key: Any] = [
            .font: digitFont,
            .foregroundColor: dominantKind.foreground,
        ]
        let digitSize = (countText as NSString).size(withAttributes: digitAttrs)

        // Capsule width = leading padding + sprite + gap + digits + trailing.
        let capsuleWidth = ceil(
            horizontalPadding + spriteSize + spriteToCountGap + digitSize.width + trailingPadding
        )
        let totalWidth = ceil(
            capsuleWidth + capsuleToTicksGap + tickWidth + ticksTrailingPadding
        )

        let image = NSImage(size: NSSize(width: totalWidth, height: height), flipped: false) { _ in
            let capsuleRect = NSRect(x: 0, y: 0, width: capsuleWidth, height: height)
            drawCapsule(in: capsuleRect, kind: dominantKind)
            drawSpriteWatermark(at: NSPoint(x: horizontalPadding, y: (height - spriteSize) / 2))
            let digitOrigin = NSPoint(
                x: horizontalPadding + spriteSize + spriteToCountGap,
                y: (height - digitSize.height) / 2 - 0.5
            )
            (countText as NSString).draw(at: digitOrigin, withAttributes: digitAttrs)

            drawTicks(
                ticks: ticks,
                originX: capsuleWidth + capsuleToTicksGap
            )
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Vertically stacked ticks rendered to the right of the capsule.
    /// Each tick is bright in its state colour when count > 0 and dim
    /// white when there's nothing in that state.
    private static func drawTicks(
        ticks: [(kind: ClydeStatusKind, count: Int)],
        originX: CGFloat
    ) {
        let totalTicksHeight = CGFloat(ticks.count) * tickHeight + CGFloat(max(0, ticks.count - 1)) * tickGap
        var y = (height + totalTicksHeight) / 2 - tickHeight
        for tick in ticks {
            let color: NSColor = tick.count > 0 ? tick.kind.foreground : NSColor.white.withAlphaComponent(0.18)
            color.setFill()
            let rect = NSRect(x: originX, y: y, width: tickWidth, height: tickHeight)
            let path = NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1)
            path.fill()
            y -= (tickHeight + tickGap)
        }
    }

    private static func drawCapsule(in rect: NSRect, kind: ClydeStatusKind) {
        let path = NSBezierPath(
            roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
            xRadius: cornerRadius,
            yRadius: cornerRadius
        )

        // Vertical gradient fill.
        let gradient = NSGradient(
            starting: kind.gradientTop,
            ending: kind.gradientBottom
        )
        gradient?.draw(in: path, angle: -90)

        // Inset rim — a half-point stroke just inside the bounds.
        kind.rim.setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    /// Draws the Clyde sprite at the given origin in its native colours.
    /// Earlier versions painted every pixel a flat white at low alpha — that
    /// worked for the old Clyde silhouette but the redesigned face has eyes,
    /// mouth and antenna detail that get lost when collapsed to a single
    /// tone, so we render true-colour now.
    private static func drawSpriteWatermark(at origin: NSPoint) {
        let sprite = ClydeSprite.body
        let gridSize = 16
        let pxSize = spriteSize / CGFloat(gridSize)

        for row in 0..<gridSize {
            for col in 0..<gridSize {
                guard let swiftColor = sprite[row][col] else { continue }
                // Bridge SwiftUI Color → NSColor via NSColor(_:).
                let nsColor = NSColor(swiftColor)
                nsColor.setFill()
                // Sprite grid is top-down, AppKit coordinates are bottom-up.
                let cell = NSRect(
                    x: origin.x + CGFloat(col) * pxSize,
                    y: origin.y + spriteSize - CGFloat(row + 1) * pxSize,
                    width: pxSize,
                    height: pxSize
                )
                cell.fill()
            }
        }
    }
}
