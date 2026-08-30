import XCTest
@testable import Clyde

/// Both AppleScript adapters used to name their terminal — `tell
/// application "iTerm2"` — while every other lookup in the same file
/// went through the bundle identifier. When the scripting name doesn't
/// resolve (a rename, a localisation, a LaunchServices database with
/// stale entries for the same app) the script fails with
/// NSAppleScriptErrorAppName and clicking a session does nothing.
///
/// The identifier is declared once per adapter and the script now
/// interpolates it, so the two can no longer disagree.
final class TerminalAdapterTargetingTests: XCTestCase {

    func testITermScriptTargetsTheBundleIdentifier() {
        let adapter = ITermAdapter()

        let script = adapter.focusScript(parentPID: 4242)

        XCTAssertTrue(script.contains(#"tell application id "com.googlecode.iterm2""#), script)
        XCTAssertFalse(script.contains(#"tell application "iTerm2""#), "name lookup is the brittle path")
    }

    func testTerminalAppScriptTargetsTheBundleIdentifier() {
        let adapter = TerminalAppAdapter()

        let script = adapter.focusScript(tty: "/dev/ttys003")

        XCTAssertTrue(script.contains(#"tell application id "com.apple.Terminal""#), script)
        XCTAssertFalse(script.contains(#"tell application "Terminal""#))
    }

    /// The identifier in the script is the adapter's own, not a second
    /// copy of the string that can drift away from it.
    func testTheScriptUsesTheAdaptersOwnIdentifier() {
        XCTAssertTrue(ITermAdapter().focusScript(parentPID: 1)
            .contains(ITermAdapter().bundleIdentifier))
        XCTAssertTrue(TerminalAppAdapter().focusScript(tty: "/dev/ttys000")
            .contains(TerminalAppAdapter().bundleIdentifier))
    }

    /// Warp ships under two identifiers. Only the stable one was
    /// declared, so on a Preview install `isInstalled` was false and
    /// focusing a session reported the terminal as not installed.
    func testWarpKnowsItsPreviewBuild() {
        XCTAssertEqual(WarpAdapter().bundleIdentifiers,
                       ["dev.warp.Warp-Stable", "dev.warp.Warp-Preview"])
    }

    /// Every adapter's identifier list starts with the one it declares.
    func testEveryAdapterListsItsPrimaryIdentifierFirst() {
        let adapters: [TerminalAdapter] = [ITermAdapter(), TerminalAppAdapter(),
                                           WarpAdapter(), GhosttyAdapter()]
        for adapter in adapters {
            XCTAssertEqual(adapter.bundleIdentifiers.first, adapter.bundleIdentifier, adapter.name)
        }
    }
}
