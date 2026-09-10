import XCTest
@testable import Clyde

@MainActor
final class UsageLimitsStoreTests: XCTestCase {
    private var dir: URL!
    private var enabled = true

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clyde-limits-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        enabled = true
    }

    override func tearDown() async throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func makeStore() -> UsageLimitsStore {
        UsageLimitsStore(directory: dir, isEnabled: { [unowned self] in self.enabled })
    }

    private func writeSnapshot(fiveHourResetsAt: TimeInterval) throws {
        let json = """
        {"session_id": "abc", "model": {"display_name": "Opus"},
         "rate_limits": {"five_hour": {"used_percentage": 42, "resets_at": \(Int(fiveHourResetsAt))},
                         "seven_day": {"used_percentage": 18, "resets_at": \(Int(fiveHourResetsAt + 86_400 * 3))}}}
        """
        try json.write(to: dir.appendingPathComponent("statusline.json"), atomically: true, encoding: .utf8)
    }

    func testScanReadsTheSnapshot() throws {
        try writeSnapshot(fiveHourResetsAt: Date().timeIntervalSince1970 + 3600)
        let store = makeStore()
        store.scan()
        XCTAssertEqual(store.limits?.fiveHour?.usedPercentage, 42)
        XCTAssertEqual(store.limits?.sessionID, "abc")
    }

    func testNoSnapshotMeansNoLimits() {
        let store = makeStore()
        store.scan()
        XCTAssertNil(store.limits)
    }

    func testDisabledMeansNoLimitsEvenWithASnapshot() throws {
        try writeSnapshot(fiveHourResetsAt: Date().timeIntervalSince1970 + 3600)
        enabled = false
        let store = makeStore()
        store.scan()
        XCTAssertNil(store.limits)
    }

    func testAnExpiredWindowIsDroppedOnScan() throws {
        try writeSnapshot(fiveHourResetsAt: Date().timeIntervalSince1970 - 60)
        let store = makeStore()
        store.scan()
        XCTAssertNil(store.limits?.fiveHour)
        XCTAssertNotNil(store.limits?.sevenDay)
    }

    func testUpdatedAtIsTheFilesModificationTime() throws {
        try writeSnapshot(fiveHourResetsAt: Date().timeIntervalSince1970 + 3600)
        let store = makeStore()
        store.scan()
        let mtime = try XCTUnwrap(try FileManager.default
            .attributesOfItem(atPath: dir.appendingPathComponent("statusline.json").path)[.modificationDate] as? Date)
        XCTAssertEqual(store.limits?.updatedAt, mtime)
    }

    func testAReplacedFileIsPickedUpByTheWatcher() async throws {
        let store = makeStore()
        store.start()
        defer { store.stop() }
        XCTAssertNil(store.limits)

        try writeSnapshot(fiveHourResetsAt: Date().timeIntervalSince1970 + 3600)
        // The wrapper renames a temp file into place; atomic write does the same.
        let deadline = Date().addingTimeInterval(3)
        while store.limits == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(store.limits?.fiveHour?.usedPercentage, 42)
    }

    func testRestartingTheWatcherDoesNotCrashAndStillScans() throws {
        try writeSnapshot(fiveHourResetsAt: Date().timeIntervalSince1970 + 3600)
        let store = makeStore()
        store.start()
        store.stop()
        store.start()
        store.stop()
        store.scan()
        XCTAssertEqual(store.limits?.fiveHour?.usedPercentage, 42)
    }
}
