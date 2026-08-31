// Prints the geometry of an app's windows, including ones that are not
// on screen.
//
// Written because measuring Clyde's panel used to go through System
// Events, which needs Automation permission and fails outright when
// macOS has not granted it — the reason the v0.8.0 panel regression was
// so hard to prove. CGWindowListCopyWindowInfo needs no permission at
// all, and `.optionAll` sees the expanded panel while it is still
// hidden at alpha 0, so nothing has to be clicked open first.
//
// Usage: swift window-geometry.swift <app name>            (on-screen + hidden)
//        swift window-geometry.swift <app name> --onscreen (visible only)
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write("usage: window-geometry.swift <app name> [--onscreen]\n".data(using: .utf8)!)
    exit(2)
}
let owner = arguments[1]
let onscreenOnly = arguments.contains("--onscreen")
let option: CGWindowListOption = onscreenOnly
    ? [.optionOnScreenOnly, .excludeDesktopElements]
    : [.optionAll, .excludeDesktopElements]

let windows = CGWindowListCopyWindowInfo(option, kCGNullWindowID) as? [[String: Any]] ?? []
var found = 0
for window in windows {
    // Prefix match: development builds are named "Clyde (dev)" since
    // they were given their own bundle identity, and an exact match
    // silently found nothing — which reads exactly like a window that
    // does not exist.
    guard let name = window[kCGWindowOwnerName as String] as? String,
          name == owner || name.hasPrefix("\(owner) ("),
          let bounds = window[kCGWindowBounds as String] as? [String: Any],
          let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double
    else { continue }
    let layer = window[kCGWindowLayer as String] as? Int ?? 0
    let alpha = window[kCGWindowAlpha as String] as? Double ?? 1
    print("\(Int(width))x\(Int(height)) layer=\(layer) alpha=\(alpha) owner=\(name)")
    found += 1
}
// No windows at all is not the same answer as a window of the wrong
// size — a headless machine has to be able to say so.
exit(found == 0 ? 1 : 0)
