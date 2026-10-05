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
                                           WarpAdapter(), GhosttyAdapter(), CmuxAdapter()]
        for adapter in adapters {
            XCTAssertEqual(adapter.bundleIdentifiers.first, adapter.bundleIdentifier, adapter.name)
        }
    }

    /// `ps -E` prints argv followed by the environment, space-separated.
    /// The variable is the last whole-word `KEY=`, not the same text in
    /// an argument or inside a longer name.
    func testEnvironmentValueIsTheVariableNotAnArgument() {
        let output = "claude -p WARP_FOCUS_URL=warp://session/0000 OLD_WARP_FOCUS_URL=x WARP_FOCUS_URL=warp://session/ab12 WARP_HONOR_PS1=0"
        XCTAssertEqual(WarpAdapter.environmentValue("WARP_FOCUS_URL", in: output), "warp://session/ab12")
        XCTAssertNil(WarpAdapter.environmentValue("WARP_FOCUS_URL", in: "claude OLD_WARP_FOCUS_URL=x"))
        XCTAssertNil(WarpAdapter.environmentValue("WARP_FOCUS_URL", in: "claude TERM_PROGRAM=WarpTerminal"), "older Warp")
    }

    /// Only a Warp session link is opened.
    func testWarpOpensOnlySessionLinks() {
        XCTAssertEqual(WarpAdapter.focusURL("warp://session/c17c6d3261a849288a7e8b00e82f796c")?.absoluteString,
                       "warp://session/c17c6d3261a849288a7e8b00e82f796c")
        XCTAssertNotNil(WarpAdapter.focusURL("warppreview://session/ab12"))
        XCTAssertNil(WarpAdapter.focusURL("https://example.com/session/ab12"))
        XCTAssertNil(WarpAdapter.focusURL("warp://session/ab12;rm"))
    }

    func testGhosttyScriptTargetsTheBundleIdentifierAndTheSessionsTTY() {
        let script = GhosttyAdapter().focusScript(tty: "/dev/ttys023", marker: "clyde-x")

        XCTAssertTrue(script.contains(#"tell application id "com.mitchellh.ghostty""#), script)
        XCTAssertTrue(script.contains("> /dev/ttys023"))
        XCTAssertTrue(script.contains(#"set marker to "clyde-x""#))
    }

    func testCmuxAcceptsOnlyASurfaceUUID() {
        XCTAssertEqual(CmuxAdapter.surfaceID("D0F1E5BE-4FC2-4009-9A41-3CFDF27331E7"), "D0F1E5BE-4FC2-4009-9A41-3CFDF27331E7")
        XCTAssertNil(CmuxAdapter.surfaceID("x\" & quit"))
        XCTAssertNil(CmuxAdapter.surfaceID(""))
    }

    func testCmuxScriptTargetsTheBundleIdentifierAndTheSurface() {
        let script = CmuxAdapter().focusScript(surfaceID: "D0F1E5BE-4FC2-4009-9A41-3CFDF27331E7")
        XCTAssertTrue(script.contains(#"tell application id "com.cmuxterm.app""#), script)
        XCTAssertTrue(script.contains(#"if id of t is "D0F1E5BE-4FC2-4009-9A41-3CFDF27331E7""#))
    }
}
