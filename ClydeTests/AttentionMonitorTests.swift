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

    private func writeEventFile(pid: pid_t, modified: Date = Date()) throws {
        let file = tempDir.appendingPathComponent("\(pid).json")
        let body = #"{"pid":\#(pid),"event":"PermissionRequest","timestamp":0}"#
        try body.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
    }

    func testScanDetectsNewEvent() {
        let monitor = AttentionMonitor(eventsDir: tempDir, timeout: 60)
        try? writeEventFile(pid: 1234)

        var notified: pid_t?
        monitor.onAttentionNeeded = { notified = $0 }

        // Trigger scan via start (which calls scan immediately)
        monitor.start()
        monitor.stop()

        XCTAssertTrue(monitor.attentionPIDs.contains(1234))
        XCTAssertEqual(notified, 1234)
    }

    func testExpiredEventsAreCleanedUp() {
        let monitor = AttentionMonitor(eventsDir: tempDir, timeout: 60)
        let oldDate = Date().addingTimeInterval(-120) // 2 minutes ago
        try? writeEventFile(pid: 1234, modified: oldDate)

        monitor.start()
        monitor.stop()

        XCTAssertFalse(monitor.attentionPIDs.contains(1234))
        // File should have been removed
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("1234.json").path))
    }

    func testClearAttentionRemovesFile() {
        let monitor = AttentionMonitor(eventsDir: tempDir, timeout: 60)
        try? writeEventFile(pid: 5678)

        monitor.start()
        XCTAssertTrue(monitor.attentionPIDs.contains(5678))

        monitor.clearAttention(pid: 5678)
        monitor.stop()

        XCTAssertFalse(monitor.attentionPIDs.contains(5678))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("5678.json").path))
    }

    func testNonPIDFilesAreIgnored() {
        let monitor = AttentionMonitor(eventsDir: tempDir, timeout: 60)
        try? "garbage".write(
            to: tempDir.appendingPathComponent("not-a-pid.json"),
            atomically: true, encoding: .utf8
        )

        monitor.start()
        monitor.stop()

        XCTAssertTrue(monitor.attentionPIDs.isEmpty)
    }
}
