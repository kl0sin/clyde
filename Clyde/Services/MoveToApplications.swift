import Foundation
import AppKit
import Security

/// Offers, once, to move Clyde into Applications.
///
/// macOS keeps a separate permission for every copy of an app. A copy
/// left in Downloads is a second row in System Settings; a copy opened
/// straight from a disk image is translocated to a random read-only
/// path, so a permission granted to it belongs to a directory that
/// disappears. Either way the pane shows Clyde as granted while the
/// running copy is denied, which is unfixable from inside the app —
/// TCC entries are not ours to remove.
///
/// Every app that needs a permission solves this the same way, and so
/// does this one: ask at first launch, move, relaunch.
enum MoveToApplications {

    static let declinedKey = "declinedMoveToApplications"

    /// Whether to put the question to the user at all.
    static func shouldOffer(location: AppLocation,
                            isDevBuild: Bool,
                            declinedBefore: Bool) -> Bool {
        // A development build lives in a build directory deliberately,
        // and moving it would replace the copy being tested.
        guard !isDevBuild else { return false }
        // Asked once. A question repeated at every launch teaches
        // people to dismiss it unread.
        guard !declinedBefore else { return false }
        // Only where the copy is doomed. A translocated copy sits in a
        // directory macOS is about to throw away and one on a disk
        // image goes on eject, so a permission granted there is lost
        // the moment it is given. A copy in Downloads works fine until
        // somebody moves it — that one gets the panel's advisory
        // rather than a modal in front of a menu-bar app that has not
        // drawn its icon yet.
        return location == .translocated || location == .diskImage
    }

    /// The Applications folder is a parameter so the file work below
    /// can be exercised against a temporary directory. Production never
    /// passes anything else.
    static func destination(for bundlePath: String,
                            in applications: URL = URL(fileURLWithPath: "/Applications")) -> URL {
        applications.appendingPathComponent((bundlePath as NSString).lastPathComponent)
    }

    /// Whether the copy left behind should go.
    ///
    /// A disk image is read-only and its copy disappears on eject;
    /// anywhere else the stray copy is the whole problem, and leaving
    /// it means the second permission row comes back.
    static func shouldRemoveSource(at location: AppLocation) -> Bool {
        location != .diskImage
    }

    /// A translocated copy cannot be moved — the path is a read-only
    /// mirror macOS made. What has to travel is the original.
    static func needsOriginalPath(for location: AppLocation) -> Bool {
        location == .translocated
    }

    /// Where a translocated copy actually came from, if macOS will say.
    ///
    /// `SecTranslocateCreateOriginalPathForURL` exists in the Security
    /// framework but is not surfaced to Swift, so it is resolved at
    /// runtime. A miss is not a failure worth shouting about — the
    /// advisory still tells the user to move the app by hand.
    static func originalPath(of bundle: URL) -> URL? {
        typealias CreateOriginalPath =
            @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                                 "SecTranslocateCreateOriginalPathForURL") else { return nil }
        let create = unsafeBitCast(symbol, to: CreateOriginalPath.self)
        guard let original = create(bundle as CFURL, nil) else { return nil }
        return original.takeRetainedValue() as URL
    }

    // MARK: - Doing it

    /// Put the question, and act on the answer.
    ///
    /// Called once at launch. Everything here is reversible by the
    /// user: the app is copied, not deleted out from under them, and
    /// the copy left behind is removed only after the new one is in
    /// place.
    @MainActor
    static func offerIfNeeded(defaults: UserDefaults = .standard) {
        let location = AppLocation.current
        // A development build is skipped, because it lives in a build
        // directory on purpose. The default below lets a dev build take
        // this path anyway, which is the only way to see the alert and
        // the relaunch actually happen — reads a key no real user sets,
        // like `assumeShortcutPermissions` beside it.
        let isDev = (Bundle.main.bundleIdentifier ?? "").hasSuffix(".dev")
            && !defaults.bool(forKey: "offerMoveInDevBuild")
        guard shouldOffer(location: location,
                          isDevBuild: isDev,
                          declinedBefore: defaults.bool(forKey: declinedKey))
        else { return }

        let bundle = URL(fileURLWithPath: Bundle.main.bundlePath)
        // A translocated copy is a read-only mirror; the original is
        // what can travel. Without it there is nothing to move, so say
        // so rather than pretending.
        let source = needsOriginalPath(for: location) ? originalPath(of: bundle) : bundle
        guard let source else {
            ClydeLog.general.info("Translocated copy with no resolvable original — leaving the advisory to explain")
            return
        }

        let alert = NSAlert()
        alert.messageText = "Move Clyde to Applications?"
        alert.informativeText = """
            macOS keeps a separate permission for every copy of an app. \
            Run from here, Clyde asks for permissions that belong to this \
            copy rather than to the one you keep — which is why a shortcut \
            can look granted and still do nothing.
            """
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not now")
        alert.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else {
            defaults.set(true, forKey: declinedKey)
            ClydeLog.general.info("User declined the move to Applications")
            return
        }

        do {
            let moved = try move(from: source)
            relaunch(at: moved)
        } catch {
            ClydeLog.general.error("Could not move to Applications: \(error.localizedDescription, privacy: .public)")
            let failure = NSAlert()
            failure.messageText = "Clyde could not move itself"
            failure.informativeText = "Drag Clyde to your Applications folder and open it from there. (\(error.localizedDescription))"
            failure.runModal()
        }
    }

    /// Copy into Applications, replacing an older copy if one is there,
    /// then remove the source when it is somewhere removable.
    @discardableResult
    static func move(from source: URL,
                     into applications: URL = URL(fileURLWithPath: "/Applications")) throws -> URL {
        let target = destination(for: source.path, in: applications)
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) {
            // Replacing rather than deleting first: an interrupted
            // delete would leave the user with no copy at all.
            _ = try fm.replaceItemAt(target, withItemAt: source)
            return target
        }
        try fm.copyItem(at: source, to: target)
        if shouldRemoveSource(at: AppLocation.classify(bundlePath: source.path)) {
            try? fm.removeItem(at: source)
        }
        return target
    }

    /// Start the copy in Applications and stand down.
    @MainActor
    static func relaunch(at bundle: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}
