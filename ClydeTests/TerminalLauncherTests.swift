import XCTest
@testable import Clyde

@MainActor
final class TerminalLauncherTests: XCTestCase {
    func testDetectTerminalsFiltersToInstalled() {
        let launcher = TerminalLauncher()
        launcher.detectTerminals()
        for terminal in launcher.availableTerminals {
            XCTAssertTrue(terminal.isInstalled)
        }
    }

    func testTerminalAppIsAlwaysAvailable() {
        let launcher = TerminalLauncher()
        launcher.detectTerminals()
        XCTAssertTrue(launcher.availableTerminals.contains(where: { $0.name == "Terminal" }))
    }
}

/// Finding which terminal hosts a session used to be a substring search
/// over the parent process's executable path. It is the same brittle
/// name lookup the AppleScript targets had: `contains("stable")` claimed
/// any binary with "stable" in its path for Warp, and a terminal whose
/// binary is not named after its app was never matched at all.
///
/// The process's bundle identifier is the reliable answer, and every
/// adapter already declares one. The path match stays as a fallback for
/// the cases where a pid has no bundle at all.
@MainActor
final class TerminalHostMatchingTests: XCTestCase {

    func testMatchesTheTerminalByItsBundleIdentifier() {
        let launcher = TerminalLauncher()

        XCTAssertTrue(launcher.adapter(forBundleIdentifier: "com.googlecode.iterm2") is ITermAdapter)
        XCTAssertTrue(launcher.adapter(forBundleIdentifier: "com.apple.Terminal") is TerminalAppAdapter)
        XCTAssertTrue(launcher.adapter(forBundleIdentifier: "com.mitchellh.ghostty") is GhosttyAdapter)
        XCTAssertTrue(launcher.adapter(forBundleIdentifier: "dev.warp.Warp-Stable") is WarpAdapter)
    }

    /// Warp Preview is Warp. Reported as "Terminal application is not
    /// installed" before, because only the stable identifier was known.
    func testMatchesWarpPreview() {
        XCTAssertTrue(TerminalLauncher().adapter(forBundleIdentifier: "dev.warp.Warp-Preview") is WarpAdapter)
    }

    func testAnUnknownTerminalMatchesNothing() {
        XCTAssertNil(TerminalLauncher().adapter(forBundleIdentifier: "net.kovidgoyal.kitty"))
        XCTAssertNil(TerminalLauncher().adapter(forBundleIdentifier: ""))
    }

    func testTheFallbackStillRecognisesEachTerminalsExecutable() {
        let launcher = TerminalLauncher()

        XCTAssertTrue(launcher.adapter(forProcessPath: "/applications/iterm.app/contents/macos/iterm2") is ITermAdapter)
        XCTAssertTrue(launcher.adapter(forProcessPath: "/system/applications/utilities/terminal.app/contents/macos/terminal") is TerminalAppAdapter)
        XCTAssertTrue(launcher.adapter(forProcessPath: "/applications/warp.app/contents/macos/stable") is WarpAdapter)
        XCTAssertTrue(launcher.adapter(forProcessPath: "/applications/ghostty.app/contents/macos/ghostty") is GhosttyAdapter)
    }

    /// The bug in the fallback: "stable" on its own was enough to be Warp.
    func testTheFallbackDoesNotClaimUnrelatedBinaries() {
        let launcher = TerminalLauncher()

        XCTAssertNil(launcher.adapter(forProcessPath: "/applications/stableclient.app/contents/macos/stable"))
        XCTAssertNil(launcher.adapter(forProcessPath: "/usr/local/bin/rustable"))
        XCTAssertNil(launcher.adapter(forProcessPath: "/applications/kitty.app/contents/macos/kitty"))
    }
}
