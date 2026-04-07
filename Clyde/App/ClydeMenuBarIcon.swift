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
    static func templateImage(size: CGFloat = 18) -> NSImage {
        let sprite = ClydeSprite.body
        let gridSize = 16
        let pxSize = size / CGFloat(gridSize)

        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()

        NSColor.black.setFill()
        for row in 0..<gridSize {
            for col in 0..<gridSize {
                guard sprite[row][col] != nil else { continue }
                // The sprite grid is top-down (row 0 is the antenna tip)
                // while NSImage's coordinate space is bottom-up, so flip Y.
                let rect = NSRect(
                    x: CGFloat(col) * pxSize,
                    y: size - CGFloat(row + 1) * pxSize,
                    width: pxSize,
                    height: pxSize
                )
                rect.fill()
            }
        }

        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}
