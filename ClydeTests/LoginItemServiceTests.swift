import XCTest
import ServiceManagement
@testable import Clyde

final class LoginItemServiceTests: XCTestCase {

    /// Restore the override between tests so one test's mock doesn't
    /// leak into the next — same hygiene as `CleatProbeTests`.
    override func tearDown() {
        LoginItemService.backendOverride = nil
        super.tearDown()
    }

    // MARK: - isEnabled

    func testIsEnabledTrueWhenRegistered() {
        LoginItemService.backendOverride = MockLoginItemBackend(status: .enabled)
        XCTAssertTrue(LoginItemService.isEnabled)
    }

    func testIsEnabledFalseWhenNotRegistered() {
        LoginItemService.backendOverride = MockLoginItemBackend(status: .notRegistered)
        XCTAssertFalse(LoginItemService.isEnabled)
    }

    func testIsEnabledFalseWhenApprovalPending() {
        // `.requiresApproval` means the toggle wouldn't actually
        // launch Clyde yet, so the binding must read as off — the
        // UI surfaces the pending state via `currentStatus` instead.
        LoginItemService.backendOverride = MockLoginItemBackend(status: .requiresApproval)
        XCTAssertFalse(LoginItemService.isEnabled)
    }

    func testIsEnabledFalseWhenNotFound() {
        LoginItemService.backendOverride = MockLoginItemBackend(status: .notFound)
        XCTAssertFalse(LoginItemService.isEnabled)
    }

    // MARK: - currentStatus

    func testCurrentStatusPassesThroughRawStatus() {
        // The UI needs the raw status to tell `.requiresApproval`
        // apart from `.notRegistered` — both read as "off" through
        // `isEnabled`.
        LoginItemService.backendOverride = MockLoginItemBackend(status: .requiresApproval)
        XCTAssertEqual(LoginItemService.currentStatus, .requiresApproval)
    }

    // MARK: - setEnabled

    func testSetEnabledTrueRegisters() throws {
        let mock = MockLoginItemBackend(status: .notRegistered)
        LoginItemService.backendOverride = mock

        try LoginItemService.setEnabled(true)

        XCTAssertEqual(mock.registerCalls, 1)
        XCTAssertEqual(mock.unregisterCalls, 0)
        XCTAssertTrue(LoginItemService.isEnabled)
    }

    func testSetEnabledFalseUnregisters() throws {
        let mock = MockLoginItemBackend(status: .enabled)
        LoginItemService.backendOverride = mock

        try LoginItemService.setEnabled(false)

        XCTAssertEqual(mock.unregisterCalls, 1)
        XCTAssertEqual(mock.registerCalls, 0)
        XCTAssertFalse(LoginItemService.isEnabled)
    }

    func testSetEnabledPropagatesRegisterError() {
        // The unsigned-dev-build case: launchd refuses the
        // registration. The error must reach the caller so the UI
        // can show it and reconcile the toggle back to the truth.
        let mock = MockLoginItemBackend(status: .notRegistered)
        mock.registerError = NSError(domain: "ClydeTests", code: 1)
        LoginItemService.backendOverride = mock

        XCTAssertThrowsError(try LoginItemService.setEnabled(true))
        XCTAssertFalse(LoginItemService.isEnabled, "a failed register must not flip the reported state")
    }

    func testSetEnabledPropagatesUnregisterError() {
        let mock = MockLoginItemBackend(status: .enabled)
        mock.unregisterError = NSError(domain: "ClydeTests", code: 2)
        LoginItemService.backendOverride = mock

        XCTAssertThrowsError(try LoginItemService.setEnabled(false))
        XCTAssertTrue(LoginItemService.isEnabled, "a failed unregister must keep reporting enabled")
    }

    func testRegisterRequiringApprovalLeavesToggleOff() throws {
        // First-time registration on some systems lands in
        // `.requiresApproval` rather than `.enabled` — register()
        // succeeds but the user still has to flip the switch in
        // System Settings. The toggle must read as off while the UI
        // shows the approval hint.
        let mock = MockLoginItemBackend(status: .notRegistered)
        mock.statusAfterRegister = .requiresApproval
        LoginItemService.backendOverride = mock

        try LoginItemService.setEnabled(true)

        XCTAssertFalse(LoginItemService.isEnabled)
        XCTAssertEqual(LoginItemService.currentStatus, .requiresApproval)
    }
}

// MARK: - mock

private final class MockLoginItemBackend: LoginItemBackend {
    var status: SMAppService.Status
    var registerCalls = 0
    var unregisterCalls = 0
    var registerError: Error?
    var unregisterError: Error?
    /// Status to report after a successful `register()` — defaults
    /// to `.enabled`, set to `.requiresApproval` to simulate the
    /// first-time approval flow.
    var statusAfterRegister: SMAppService.Status = .enabled

    init(status: SMAppService.Status) {
        self.status = status
    }

    func register() throws {
        registerCalls += 1
        if let error = registerError { throw error }
        status = statusAfterRegister
    }

    func unregister() throws {
        unregisterCalls += 1
        if let error = unregisterError { throw error }
        status = .notRegistered
    }
}
