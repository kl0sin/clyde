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

    func testSelectedAdapterDefaultsToFirst() {
        let launcher = TerminalLauncher()
        launcher.detectTerminals()
        XCTAssertNotNil(launcher.selectedAdapter)
        XCTAssertEqual(launcher.selectedAdapter?.name, launcher.availableTerminals.first?.name)
    }
}
