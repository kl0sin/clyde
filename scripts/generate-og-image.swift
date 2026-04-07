#!/usr/bin/env swift
// Generates site/img/og-preview.png — the social-share preview image
// referenced from the landing page's <meta property="og:image"> tag.
//
// Output: 1200×630 PNG, dark gradient background matching the site,
// Clyde sprite on the left, big "Clyde" wordmark + tagline on the right.
//
// Usage:
//     swift scripts/generate-og-image.swift

import Cocoa

// MARK: - Sprite mirror (kept in sync with ClydeAnimationView.swift)

let _e: NSColor? = nil
let _w: NSColor? = .white
let _h: NSColor? = NSColor(red: 0.910, green: 0.910, blue: 0.940, alpha: 1)
let _s: NSColor? = NSColor(red: 0.565, green: 0.565, blue: 0.627, alpha: 1)
let _b: NSColor? = NSColor(red: 0.100, green: 0.100, blue: 0.140, alpha: 1)
let _g: NSColor? = NSColor(red: 0.369, green: 0.910, blue: 0.518, alpha: 1)
let _G: NSColor? = NSColor(red: 0.659, green: 1.000, blue: 0.769, alpha: 1)
let _d: NSColor? = NSColor(red: 0.353, green: 0.353, blue: 0.416, alpha: 1)

let sprite: [[NSColor?]] = [
    [_e, _e, _e, _e, _e, _e, _e, _e, _e, _e, _e, _e, _e, _e, _e, _e],
    [_e, _e, _e, _e, _e, _e, _G, _g, _g, _G, _e, _e, _e, _e, _e, _e],
    [_e, _e, _e, _e, _e, _e, _e, _d, _d, _e, _e, _e, _e, _e, _e, _e],
    [_e, _e, _e, _e, _b, _b, _b, _b, _b, _b, _b, _b, _e, _e, _e, _e],
    [_e, _e, _e, _b, _w, _h, _h, _h, _h, _h, _h, _w, _s, _b, _e, _e],
    [_e, _e, _b, _w, _w, _w, _w, _w, _w, _w, _w, _w, _w, _s, _b, _e],
    [_e, _e, _b, _w, _w, _w, _b, _w, _w, _w, _b, _w, _w, _s, _b, _e],
    [_e, _e, _b, _w, _w, _b, _b, _w, _w, _b, _b, _w, _w, _s, _b, _e],
    [_e, _e, _b, _w, _w, _w, _w, _w, _w, _w, _w, _w, _w, _s, _b, _e],
    [_e, _e, _b, _w, _w, _w, _w, _w, _w, _w, _w, _w, _w, _s, _b, _e],
    [_e, _e, _b, _w, _w, _w, _w, _b, _b, _w, _w, _w, _w, _s, _b, _e],
    [_e, _e, _b, _w, _w, _w, _w, _w, _w, _w, _w, _w, _w, _s, _b, _e],
    [_e, _e, _e, _b, _w, _w, _w, _w, _w, _w, _w, _w, _s, _b, _e, _e],
    [_e, _e, _e, _e, _b, _b, _b, _b, _b, _b, _b, _b, _e, _e, _e, _e],
    [_e, _e, _e, _e, _e, _e, _e, _e, _e, _e, _e, _e, _e, _e, _e, _e],
    [_e, _e, _e, _e, _e, _e, _e, _e, _e, _e, _e, _e, _e, _e, _e, _e],
]

// MARK: - Image generation

let width: CGFloat = 1200
let height: CGFloat = 630

let workDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let outputPath = workDir.appendingPathComponent("site/img/og-preview.png")

let bgTop    = NSColor(red: 0.040, green: 0.040, blue: 0.063, alpha: 1)   // #0a0a10 ish
let bgBottom = NSColor(red: 0.075, green: 0.055, blue: 0.110, alpha: 1)   // slight purple bias
let glow     = NSColor(red: 0.749, green: 0.353, blue: 0.949, alpha: 1)
let purpleBright = NSColor(red: 0.851, green: 0.612, blue: 1.000, alpha: 1)
let blueBright   = NSColor(red: 0.480, green: 0.722, blue: 1.000, alpha: 1)
let textPrimary  = NSColor.white
let textDim      = NSColor(red: 0.541, green: 0.541, blue: 0.600, alpha: 1)

// Use an explicit NSBitmapImageRep so the output is exactly 1200×630
// pixels regardless of the host Mac's backing scale (otherwise Retina
// adds a 2× factor and Twitter/Facebook downscale a too-large image).
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(width),
    pixelsHigh: Int(height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    print("ERROR: failed to allocate bitmap")
    exit(1)
}
rep.size = NSSize(width: width, height: height)

NSGraphicsContext.saveGraphicsState()
guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
    print("ERROR: failed to create graphics context")
    exit(1)
}
NSGraphicsContext.current = ctx

// 1. Flat dark base — single solid colour, no banding.
let bgRect = NSRect(x: 0, y: 0, width: width, height: height)
NSColor(red: 0.055, green: 0.045, blue: 0.085, alpha: 1).setFill()
bgRect.fill()

// 2. ONE huge soft purple radial that spans the entire canvas. The
//    glow rect is intentionally larger than the canvas so the falloff
//    edges fall outside the visible area — no hard ring, no band, just
//    smooth atmosphere from the centre outward.
if let radial = NSGradient(colors: [
    glow.withAlphaComponent(0.32),
    glow.withAlphaComponent(0.18),
    glow.withAlphaComponent(0.06),
    glow.withAlphaComponent(0.0),
]) {
    let glowRect = NSRect(x: -600, y: -600, width: 2400, height: 1830)
    // Hot spot slightly left of canvas centre + slightly above the
    // sprite vertical centre. Soft, no directional artefacts.
    radial.draw(in: glowRect, relativeCenterPosition: NSPoint(x: -0.15, y: -0.05))
}

// 3. Clyde sprite — centred vertically in the left half.
let spriteSize: CGFloat = 360
let spriteOriginX: CGFloat = 130
let spriteOriginY: CGFloat = (height - spriteSize) / 2
let pixelSize = spriteSize / 16

for row in 0..<16 {
    for col in 0..<16 {
        guard let color = sprite[row][col] else { continue }
        let px = NSRect(
            x: spriteOriginX + CGFloat(col) * pixelSize,
            y: spriteOriginY + CGFloat(15 - row) * pixelSize, // flip Y for AppKit
            width: pixelSize,
            height: pixelSize
        )
        color.setFill()
        NSBezierPath(rect: px).fill()
    }
}

// MARK: - Right-side text block (centered horizontally + vertically)
//
// The right "column" starts where the sprite ends and runs to the
// canvas edge. We draw each text element centred horizontally inside
// that column, stacked vertically with a fixed gap, and then offset
// the whole stack so its bounding box is centred on height/2.

let columnX: CGFloat = spriteOriginX + spriteSize  // start right after sprite
let columnWidth: CGFloat = width - columnX

let centeredParagraph = NSMutableParagraphStyle()
centeredParagraph.alignment = .center

let labelFont = NSFont.systemFont(ofSize: 22, weight: .heavy)
let labelAttrs: [NSAttributedString.Key: Any] = [
    .font: labelFont,
    .foregroundColor: purpleBright,
    .kern: 3,
    .paragraphStyle: centeredParagraph,
]

let titleFont = NSFont.systemFont(ofSize: 130, weight: .heavy)
let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: titleFont,
    .foregroundColor: textPrimary,
    .kern: -3,
    .paragraphStyle: centeredParagraph,
]

let taglineFont = NSFont.systemFont(ofSize: 32, weight: .medium)
let taglineAttrs: [NSAttributedString.Key: Any] = [
    .font: taglineFont,
    .foregroundColor: textDim,
    .paragraphStyle: centeredParagraph,
]

// Heights of each block (approximate — system font ascent + descent).
let labelHeight: CGFloat = 28
let labelGap: CGFloat = 22
let titleHeight: CGFloat = 130
let titleGap: CGFloat = 24
let taglineLineHeight: CGFloat = 42
let taglineHeight: CGFloat = taglineLineHeight * 2

let totalBlockHeight = labelHeight + labelGap + titleHeight + titleGap + taglineHeight
// Center the block vertically. Cocoa origin is bottom-left so
// blockTop is the y of the top edge of the block.
let blockTop = (height + totalBlockHeight) / 2

// Layout (top → bottom): label, title, tagline.
var cursorY = blockTop - labelHeight
let labelRect = NSRect(x: columnX, y: cursorY, width: columnWidth, height: labelHeight)
("CLAUDE CODE COMPANION" as NSString).draw(in: labelRect, withAttributes: labelAttrs)

cursorY -= (labelGap + titleHeight)
let titleRect = NSRect(x: columnX, y: cursorY, width: columnWidth, height: titleHeight + 20)
("Clyde" as NSString).draw(in: titleRect, withAttributes: titleAttrs)

cursorY -= (titleGap + taglineHeight)
let taglineRect = NSRect(x: columnX, y: cursorY, width: columnWidth, height: taglineHeight + 8)
("Know what Claude is doing —\nwithout alt-tabbing." as NSString)
    .draw(in: taglineRect, withAttributes: taglineAttrs)

NSGraphicsContext.restoreGraphicsState()

// MARK: - Save as PNG

guard let png = rep.representation(using: .png, properties: [:]) else {
    print("ERROR: failed to encode PNG")
    exit(1)
}

do {
    try png.write(to: outputPath)
    print("✓ Wrote \(outputPath.path)")
} catch {
    print("ERROR: failed to write \(outputPath.path): \(error)")
    exit(1)
}
