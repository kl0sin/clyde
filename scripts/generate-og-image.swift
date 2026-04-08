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

// Palette mirrors site/styles.css :root vars exactly so the OG card
// reads as a screenshot of the hero. Near-black base, gentle purple
// ellipse from the top, faint blue/green washes at the bottom corners.
let bgBase       = NSColor(red: 10/255,  green: 10/255,  blue: 16/255,  alpha: 1) // --bg #0a0a10
let purpleGlow   = NSColor(red: 191/255, green: 90/255,  blue: 242/255, alpha: 1) // --purple
let blueGlow     = NSColor(red: 74/255,  green: 144/255, blue: 226/255, alpha: 1) // --blue
let greenGlow    = NSColor(red: 52/255,  green: 199/255, blue: 89/255,  alpha: 1) // --green
let purpleStart  = NSColor(red: 217/255, green: 156/255, blue: 255/255, alpha: 1) // --purple-bright
let purpleMid    = NSColor(red: 191/255, green: 90/255,  blue: 242/255, alpha: 1) // --purple
let blueEnd      = NSColor(red: 122/255, green: 184/255, blue: 255/255, alpha: 1) // --blue-bright
let textPrimary  = NSColor(red: 240/255, green: 240/255, blue: 245/255, alpha: 1) // --text
let textDim      = NSColor(red: 138/255, green: 138/255, blue: 153/255, alpha: 1) // --text-dim

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

// MARK: - Background
//
// Reproduces the hero-bg layer from site/styles.css:
//   radial-gradient(ellipse 800x600 at 50% 0%,  rgba(191,90,242,0.18))
//   radial-gradient(ellipse 600x400 at 20% 80%, rgba(74,144,226,0.10))
//   radial-gradient(ellipse 600x400 at 80% 80%, rgba(52,199,89,0.06))
// over a flat #0a0a10 base. CSS uses top-anchored ellipses (Y=0), so
// the bright spot is at the canvas's top edge, not its centre.

let bgRect = NSRect(x: 0, y: 0, width: width, height: height)
bgBase.setFill()
bgRect.fill()

// Helper: draw an ellipse-shaped radial wash centred on (cx, cy) in
// canvas pixels, with the given semi-axes and peak alpha. We achieve
// the elliptical falloff by scaling the CTM around the centre, then
// drawing a circular gradient in the scaled space.
func drawRadial(
    centerX: CGFloat,
    centerY: CGFloat,
    radiusX: CGFloat,
    radiusY: CGFloat,
    color: NSColor,
    peakAlpha: CGFloat
) {
    guard let cg = NSGraphicsContext.current?.cgContext else { return }
    cg.saveGState()
    cg.translateBy(x: centerX, y: centerY)
    cg.scaleBy(x: radiusX / radiusY, y: 1.0)
    let colors = [
        color.withAlphaComponent(peakAlpha).cgColor,
        color.withAlphaComponent(0).cgColor,
    ] as CFArray
    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: colors,
        locations: [0.0, 1.0]
    ) {
        cg.drawRadialGradient(
            gradient,
            startCenter: .zero, startRadius: 0,
            endCenter: .zero, endRadius: radiusY,
            options: []
        )
    }
    cg.restoreGState()
}

// Cocoa origin is bottom-left, CSS origin is top-left. So CSS "y=0"
// (top of canvas) maps to Cocoa y=height, and "y=80%" maps to y≈height*0.2.
drawRadial(
    centerX: width / 2,
    centerY: height,
    radiusX: 800,
    radiusY: 600,
    color: purpleGlow,
    peakAlpha: 0.18
)
drawRadial(
    centerX: width * 0.20,
    centerY: height * 0.20,
    radiusX: 600,
    radiusY: 400,
    color: blueGlow,
    peakAlpha: 0.10
)
drawRadial(
    centerX: width * 0.80,
    centerY: height * 0.20,
    radiusX: 600,
    radiusY: 400,
    color: greenGlow,
    peakAlpha: 0.06
)

// Sprite layout: centred horizontally, upper portion of the canvas.
let spriteSize: CGFloat = 220
let spriteCenterX = width / 2
let spriteCenterY = height * 0.70
let spriteOriginX = spriteCenterX - spriteSize / 2
let spriteOriginY = spriteCenterY - spriteSize / 2
let pixelSize = spriteSize / 16

// MARK: - Sprite

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

// MARK: - Wordmark + tagline (centred, stacked under the sprite)
//
// We render BOTH "Meet" and "Clyde" via Core Text glyph paths so they
// share identical baseline metrics — drawing one with NSString.draw(in:)
// and the other via a CT clip path produced visibly different baselines.
// "Meet " is filled flat white; "Clyde" is filled with the same 135°
// purple→purple→blue gradient as the .gradient-text class on the site.

let titleFont = NSFont.systemFont(ofSize: 130, weight: .heavy)
let taglineFont = NSFont.systemFont(ofSize: 34, weight: .semibold)
let subFont = NSFont.systemFont(ofSize: 22, weight: .medium)

/// Build a CGPath of an entire string's glyphs, with origin at the
/// text's baseline. Returns the path plus its advance width.
func glyphPath(for string: String, font: NSFont, kern: CGFloat) -> (CGPath, CGFloat) {
    let attr = NSAttributedString(string: string, attributes: [
        .font: font,
        .kern: kern,
    ])
    let line = CTLineCreateWithAttributedString(attr)
    let path = CGMutablePath()
    let runs = CTLineGetGlyphRuns(line) as! [CTRun]
    for run in runs {
        let runFont = unsafeBitCast(
            CFDictionaryGetValue(
                CTRunGetAttributes(run),
                Unmanaged.passUnretained(kCTFontAttributeName).toOpaque()
            ),
            to: CTFont.self
        )
        let glyphCount = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: glyphCount)
        var positions = [CGPoint](repeating: .zero, count: glyphCount)
        CTRunGetGlyphs(run, CFRangeMake(0, glyphCount), &glyphs)
        CTRunGetPositions(run, CFRangeMake(0, glyphCount), &positions)
        for i in 0..<glyphCount {
            if let g = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) {
                let t = CGAffineTransform(translationX: positions[i].x, y: positions[i].y)
                path.addPath(g, transform: t)
            }
        }
    }
    let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    return (path, advance)
}

let titleKern: CGFloat = -3

let (meetPath, meetAdvance) = glyphPath(for: "Meet ", font: titleFont, kern: titleKern)
let (clydePath, clydeAdvance) = glyphPath(for: "Clyde", font: titleFont, kern: titleKern)

let titleTotalWidth = meetAdvance + clydeAdvance
let titleStartX = (width - titleTotalWidth) / 2

// Position the baseline so the wordmark sits a comfortable gap below
// the sprite.
let titleBaselineY = spriteOriginY - 110

if let cg = NSGraphicsContext.current?.cgContext {
    // --- "Meet " in flat white ---
    cg.saveGState()
    cg.translateBy(x: titleStartX, y: titleBaselineY)
    cg.addPath(meetPath)
    cg.setFillColor(textPrimary.cgColor)
    cg.fillPath()
    cg.restoreGState()

    // --- "Clyde" with the 135° purple→purple→blue gradient ---
    cg.saveGState()
    cg.translateBy(x: titleStartX + meetAdvance, y: titleBaselineY)
    cg.addPath(clydePath)
    cg.clip()

    let bbox = clydePath.boundingBoxOfPath
    let colors = [
        purpleStart.cgColor,
        purpleMid.cgColor,
        blueEnd.cgColor,
    ] as CFArray
    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: colors,
        locations: [0.0, 0.5, 1.0]
    ) {
        // CSS linear-gradient(135deg, ...) goes from top-left to
        // bottom-right of the box. In Cocoa's bottom-up coords that's
        // (minX, maxY) → (maxX, minY).
        cg.drawLinearGradient(
            gradient,
            start: CGPoint(x: bbox.minX, y: bbox.maxY),
            end: CGPoint(x: bbox.maxX, y: bbox.minY),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }
    cg.restoreGState()
}

// Tagline + sub-tagline (centred, white & dim, mirroring the hero copy).
let centeredParagraph = NSMutableParagraphStyle()
centeredParagraph.alignment = .center

let taglineAttrs: [NSAttributedString.Key: Any] = [
    .font: taglineFont,
    .foregroundColor: textPrimary,
    .paragraphStyle: centeredParagraph,
]
let taglineY = titleBaselineY - 90
let taglineRect = NSRect(x: 0, y: taglineY, width: width, height: 60)
("Know what Claude is doing — without alt-tabbing." as NSString)
    .draw(in: taglineRect, withAttributes: taglineAttrs)

let subAttrs: [NSAttributedString.Key: Any] = [
    .font: subFont,
    .foregroundColor: textDim,
    .paragraphStyle: centeredParagraph,
]
let subY = taglineY - 44
let subRect = NSRect(x: 0, y: subY, width: width, height: 36)
("A friendly menu bar companion for Claude Code on macOS." as NSString)
    .draw(in: subRect, withAttributes: subAttrs)

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
