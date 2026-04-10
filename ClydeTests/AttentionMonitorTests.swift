import XCTest
@testable import Clyde

@MainActor
final class AttentionMonitorTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clyde-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Write an event file using the given PID. The PID MUST be alive
    /// (`kill(pid, 0) == 0`) for the scan to consider it valid, so most
    /// tests use `getpid()` or pid 1 (init, always alive on macOS).
    private func writeEventFile(pid: pid_t) throws {
        let file = tempDir.appendingPathComponent("\(pid).json")
        let body = #"{"pid":\#(pid),"event":"PermissionRequest","timestamp":0}"#
        try body.write(to: file, atomically: true, encoding: .utf8)
    }

    func testScanDetectsNewEventForLivePID() {
        let monitor = AttentionMonitor(eventsDir: tempDir)
        // Use the test process's own PID — guaranteed alive.
        let pid = getpid()
        try? writeEventFile(pid: pid)

        var notified: pid_t?
        monitor.onAttentionNeeded = { notified = $0 }

        monitor.start()
        monitor.stop()

        XCTAssertTrue(monitor.attentionPIDs.contains(pid))
        XCTAssertEqual(notified, pid)
    }

    /// Regression: attention events used to expire after 60 seconds via
    /// an mtime-based timeout. A user who walked away from a permission
    /// prompt for more than a minute would see "Needs Input" silently
    /// flip to "Working" even though the prompt was still active. The
    /// fix: events are valid as long as the owning Claude PID is alive.
    /// This test verifies the mtime-based expiry is gone.
    func testAttentionPersistsIndefinitelyForLivePID() {
        let monitor = AttentionMonitor(eventsDir: tempDir)
        let pid = getpid()
        try? writeEventFile(pid: pid)

        // Backdate the file's mtime to 10 minutes ago — under the old
        // 60-second timeout this would have been pruned immediately.
        let tenMinutesAgo = Date().addingTimeInterval(-600)
        try? FileManager.default.setAttributes(
            [.modificationDate: tenMinutesAgo],
            ofItemAtPath: tempDir.appendingPathComponent("\(pid).json").path
        )

        monitor.start()
        monitor.stop()

        // The event must still be active — liveness, not mtime, is the
        // deciding signal.
        XCTAssertTrue(monitor.attentionPIDs.contains(pid),
                      "Attention for a live PID must not expire based on mtime")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: tempDir.appendingPathComponent("\(pid).json").path
            ),
            "Event file for a live PID must not be deleted by scan"
        )
    }

    /// When the Claude process has exited, the attention event file
    /// becomes stale — nobody is waiting for the user's input anymore.
    /// Scan should clean it up and drop the PID from attentionPIDs.
    func testDeadPIDEventIsCleanedUp() {
        let monitor = AttentionMonitor(eventsDir: tempDir)
        // PID 999_999 almost certainly doesn't exist.
        let deadPID: pid_t = 999_999
        try? writeEventFile(pid: deadPID)

        monitor.start()
        monitor.stop()

        XCTAssertFalse(monitor.attentionPIDs.contains(deadPID))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: tempDir.appendingPathComponent("\(deadPID).json").path
            ),
            "Event file for a dead PID should be removed"
        )
    }

    func testClearAttentionRemovesFile() {
        let monitor = AttentionMonitor(eventsDir: tempDir)
        let pid = getpid()
        try? writeEventFile(pid: pid)

        monitor.start()
        XCTAssertTrue(monitor.attentionPIDs.contains(pid))

        monitor.clearAttention(pid: pid)
        monitor.stop()

        XCTAssertFalse(monitor.attentionPIDs.contains(pid))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: tempDir.appendingPathComponent("\(pid).json").path
            )
        )
    }

    func testNonPIDFilesAreIgnored() {
        let monitor = AttentionMonitor(eventsDir: tempDir)
        try? "garbage".write(
            to: tempDir.appendingPathComponent("not-a-pid.json"),
            atomically: true, encoding: .utf8
        )

        monitor.start()
        monitor.stop()

        XCTAssertTrue(monitor.attentionPIDs.isEmpty)
    }
}
