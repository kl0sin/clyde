import Foundation

/// Where this copy of Clyde is running from.
///
/// macOS keys a permission to the application it was granted to, and it
/// tells copies apart. A second copy at a second path is a second row
/// in System Settings, and a copy launched straight from a downloaded
/// disk image is worse: macOS *translocates* it to a random read-only
/// path, so the grant belongs to a location that will not exist next
/// time. Either way the pane shows Clyde as granted while the copy the
/// user actually runs is denied — which is exactly what a user hit on
/// a second machine, and what no amount of re-granting can fix.
enum AppLocation: Equatable {
    /// In an Applications folder, where a permission survives.
    case installed
    /// Run from a downloaded disk image, so macOS moved it somewhere
    /// random and read-only.
    case translocated
    /// Still on the mounted disk image.
    case diskImage
    /// Somewhere else — Downloads, the Desktop, a build directory.
    case elsewhere

    static func classify(bundlePath: String) -> AppLocation {
        if bundlePath.contains("/AppTranslocation/") { return .translocated }
        if bundlePath.hasPrefix("/Volumes/") { return .diskImage }
        // Both the system folder and the user's own count: keeping
        // applications in ~/Applications is an ordinary arrangement,
        // and a permission granted there survives just as well.
        if bundlePath.hasPrefix("/Applications/") { return .installed }
        if bundlePath.range(of: "^/Users/[^/]+/Applications/", options: .regularExpression) != nil {
            return .installed
        }
        return .elsewhere
    }

    /// Test override. Production never sets it.
    nonisolated(unsafe) static var override: AppLocation?

    /// Where this copy actually is.
    static var current: AppLocation {
        override ?? classify(bundlePath: Bundle.main.bundlePath)
    }

    /// False when a permission granted to this copy cannot be expected
    /// to hold — the honest thing to say before sending someone to
    /// System Settings.
    var canKeepPermissions: Bool { self == .installed }

    /// What to tell the user, or nil when nothing is wrong.
    var advice: String? {
        switch self {
        case .installed:
            return nil
        case .translocated:
            return "Clyde is running from a copy macOS moved somewhere temporary, which happens when an app is opened straight from a download. A permission granted now belongs to that temporary copy. Drag Clyde to your Applications folder and open it from there."
        case .diskImage:
            return "Clyde is running from its disk image. Drag it to your Applications folder and open it from there, or the permission is granted to a copy that disappears when the image is ejected."
        case .elsewhere:
            return "Clyde is not in your Applications folder. macOS keeps a separate permission for every copy of an app, so move this one to Applications and open it from there."
        }
    }
}
