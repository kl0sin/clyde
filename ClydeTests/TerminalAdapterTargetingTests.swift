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

    /// `ps -E` prints argv followed by the environment, space-separated.
    /// Warp's per-session link is pulled out of that; anything that is
    /// not a Warp session link is ignored so the fallback activates.
    func testWarpFocusURLIsReadFromTheProcessEnvironment() {
        let output = "claude --resume TERM_PROGRAM=WarpTerminal WARP_FOCUS_URL=warp://session/c17c6d3261a849288a7e8b00e82f796c WARP_HONOR_PS1=0"
        XCTAssertEqual(WarpAdapter.focusURL(inProcessEnvironment: output)?.absoluteString,
                       "warp://session/c17c6d3261a849288a7e8b00e82f796c")
        XCTAssertEqual(WarpAdapter.focusURL(inProcessEnvironment: "claude WARP_FOCUS_URL=warppreview://session/ab12")?.absoluteString,
                       "warppreview://session/ab12")

        XCTAssertNil(WarpAdapter.focusURL(inProcessEnvironment: "claude TERM_PROGRAM=WarpTerminal"), "older Warp")
        XCTAssertNil(WarpAdapter.focusURL(inProcessEnvironment: "claude WARP_FOCUS_URL=https://example.com/session/ab12"))
        XCTAssertNil(WarpAdapter.focusURL(inProcessEnvironment: "claude WARP_FOCUS_URL=warp://session/ab12;rm"))
        XCTAssertNil(WarpAdapter.focusURL(inProcessEnvironment: "claude OLD_WARP_FOCUS_URL=warp://session/ab12"))

        let quotedInArgv = "claude -p WARP_FOCUS_URL=warp://session/0000 WARP_FOCUS_URL=warp://session/ab12"
        XCTAssertEqual(WarpAdapter.focusURL(inProcessEnvironment: quotedInArgv)?.absoluteString,
                       "warp://session/ab12", "the environment follows argv")
    }

    func testGhosttyScriptTargetsTheBundleIdentifierAndTheSessionsTTY() {
        let script = GhosttyAdapter().focusScript(tty: "/dev/ttys023", marker: "clyde-x")

        XCTAssertTrue(script.contains(#"tell application id "com.mitchellh.ghostty""#), script)
        XCTAssertTrue(script.contains("> /dev/ttys023"))
        XCTAssertTrue(script.contains(#"set marker to "clyde-x""#))
    }
}
