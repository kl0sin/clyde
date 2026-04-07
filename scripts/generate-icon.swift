#!/usr/bin/env swift
// Generates Clyde/Assets/AppIcon.icns programmatically.
//
// Produces a full .iconset with the standard macOS sizes, then invokes
// `iconutil` to compile it into AppIcon.icns. Run once (or whenever you
// want to refresh the icon design):
//
//     swift scripts/generate-icon.swift
//
// Requires macOS (uses Cocoa).

import Cocoa

// MARK: - Sprite (mirror of Clyde/Views/ClydeAnimationView.swift)
//
// Duplicated here on purpose so the script stays self-contained and doesn't
// need to be built as part of the Swift Package graph. If the canonical
// sprite ever changes, re-sync this block and re-run the script.

let _e: NSColor? = nil
let _w: NSColor? = .white
let _h: NSColor? = NSColor(red: 0.910, green: 0.910, blue: 0.940, alpha: 1) // forehead shine
let _s: NSColor? = NSColor(red: 0.565, green: 0.565, blue: 0.627, alpha: 1) // right-side shadow
let _b: NSColor? = NSColor(red: 0.100, green: 0.100, blue: 0.140, alpha: 1) // outline / eyes / mouth
let _g: NSColor? = NSColor(red: 0.369, green: 0.910, blue: 0.518, alpha: 1) // antenna tip
let _G: NSColor? = NSColor(red: 0.659, green: 1.000, blue: 0.769, alpha: 1) // antenna halo
let _d: NSColor? = NSColor(red: 0.353, green: 0.353, blue: 0.416, alpha: 1) // antenna stem

let sprite: [[NSColor?]] = [
    //0   1   2   3   4   5   6   7   8   9  10  11  12  13  14  15
    [_e, _e, _e, _e, _e, _e, _e, _e, _e, _e, _e, _e, _e, _e, _e, _e], // 0
    [_e, _e, _e, _e, _e, _e, _G, _g, _g, _G, _e, _e, _e, _e, _e, _e], // 1  antenna tip + halo
    [_e, _e, _e, _e, _e, _e, _e, _d, _d, _e, _e, _e, _e, _e, _e, _e], // 2  stem
    [_e, _e, _e, _e, _b, _b, _b, _b, _b, _b, _b, _b, _e, _e, _e, _e], // 3  top border
    [_e, _e, _e, _b, _w, _h, _h, _h, _h, _h, _h, _w, _s, _b, _e, _e], // 4  forehead shine
    [_e, _e, _b, _w, _w, _w, _w, _w, _w, _w, _w, _w, _w, _s, _b, _e], // 5
    [_e, _e, _b, _w, _w, _w, _b, _w, _w, _w, _b, _w, _w, _s, _b, _e], // 6  eye top + sparkle
    [_e, _e, _b, _w, _w, _b, _b, _w, _w, _b, _b, _w, _w, _s, _b, _e], // 7  eye bottom
    [_e, _e, _b, _w, _w, _w, _w, _w, _w, _w, _w, _w, _w, _s, _b, _e], // 8
    [_e, _e, _b, _w, _w, _w, _w, _w, _w, _w, _w, _w, _w, _s, _b, _e], // 9
    [_e, _e, _b, _w, _w, _w, _w, _b, _b, _w, _w, _w, _w, _s, _b, _e], // 10 closed grin
    [_e, _e, _b, _w, _w, _w, _w, _w, _w, _w, _w, _w, _w, _s, _b, _e], // 11
    [_e, _e, _e, _b, _w, _w, _w, _w, _w, _w, _w, _w, _s, _b, _e, _e], // 12
    [_e, _e, _e, _e, _b, _b, _b, _b, _b, _b, _b, _b, _e, _e, _e, _e], // 13 bottom border
    [_e, _e, _e, _e, _e, _e, _e, _e, _e, _e, _e, _e, _e, _e, _e, _e], // 14
    [_e, _e, _e, _e, _e, _e, _e, _e, _e, _e, _e, _e, _e, _e, _e, _e], // 15
]

// MARK: - Icon drawing

let workDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconsetDir = workDir.appendingPathComponent("Clyde/Assets/AppIcon.iconset")
let icnsPath = workDir.appendingPathComponent("Clyde/Assets/AppIcon.icns")

try? FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

// Sizes macOS expects inside an .iconset.
let specs: [(name: String, pixels: Int)] = [
    ("icon_16x16.png",        16),
    ("icon_16x16@2x.png",     32),
    ("icon_32x32.png",        32),
    ("icon_32x32@2x.png",     64),
    ("icon_128x128.png",     128),
    ("icon_128x128@2x.png",  256),
    ("icon_256x256.png",     256),
    ("icon_256x256@2x.png",  512),
    ("icon_512x512.png",     512),
    ("icon_512x512@2x.png", 1024),
]

/// Brand palette used for the dark backdrop + purple glow.
let bgTop    = NSColor(red: 0.09, green: 0.09, blue: 0.13, alpha: 1)
let bgBottom = NSColor(red: 0.13, green: 0.08, blue: 0.20, alpha: 1)
let glow     = NSColor(red: 0.749, green: 0.353, blue: 0.949, alpha: 1)

func renderIcon(size: Int) -> NSImage {
    let sideF = CGFloat(size)
    let image = NSImage(size: NSSize(width: sideF, height: sideF))
    image.lockFocus()
    defer { image.unlockFocus() }

    let rect = NSRect(x: 0, y: 0, width: sideF, height: sideF)
    let radius = sideF * 0.22          // macOS "squircle" radius
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    path.setClip()

    // Background gradient.
    if let gradient = NSGradient(colors: [bgTop, bgBottom]) {
        gradient.draw(in: rect, angle: -90)
    }

    // Purple radial glow behind the mascot.
    if let radial = NSGradient(colors: [glow.withAlphaComponent(0.55), glow.withAlphaComponent(0.0)]) {
        let glowRect = NSRect(
            x: sideF * 0.12,
            y: sideF * 0.08,
            width: sideF * 0.76,
            height: sideF * 0.76
        )
        radial.draw(in: glowRect, relativeCenterPosition: NSPoint(x: 0, y: 0))
    }

    // Mascot — drawn as a pixel grid scaled up to fill ~70% of the icon.
    let gridSide = sideF * 0.66
    let pixelSize = gridSide / 16
    let originX = (sideF - gridSide) / 2
    let originY = (sideF - gridSide) / 2
    for row in 0..<16 {
        for col in 0..<16 {
            guard let color = sprite[row][col] else { continue }
            let px = NSRect(
                x: originX + CGFloat(col) * pixelSize,
                y: originY + CGFloat(15 - row) * pixelSize, // flip Y
                width: pixelSize,
                height: pixelSize
            )
            color.setFill()
            NSBezierPath(rect: px).fill()
        }
    }

    // Subtle outer highlight so it reads on light wallpapers.
    NSColor.white.withAlphaComponent(0.08).setStroke()
    let stroke = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
    stroke.lineWidth = 1
    stroke.stroke()

    return image
}

func savePNG(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "generate-icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Couldn't make PNG"])
    }
    try png.write(to: url)
}

for spec in specs {
    let image = renderIcon(size: spec.pixels)
    let url = iconsetDir.appendingPathComponent(spec.name)
    do {
        try savePNG(image, to: url)
        print("  ✓ \(spec.name)")
    } catch {
        print("  ✗ \(spec.name): \(error)")
        exit(1)
    }
}

// Compile the .iconset into a .icns using the system tool.
let proc = Process()
proc.launchPath = "/usr/bin/iconutil"
proc.arguments = ["-c", "icns", iconsetDir.path, "-o", icnsPath.path]
try proc.run()
proc.waitUntilExit()

if proc.terminationStatus == 0 {
    print("✓ Wrote \(icnsPath.path)")
} else {
    print("iconutil failed with status \(proc.terminationStatus)")
    exit(1)
}
