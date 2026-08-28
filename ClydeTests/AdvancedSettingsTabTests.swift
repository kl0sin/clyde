import XCTest
@testable import Clyde

final class AdvancedSettingsTabTests: XCTestCase {

    func testNoEventsReadsAsNoHistory() {
        XCTAssertEqual(
            AdvancedSettingsTab.historySummary(eventCount: 0, sizeBytes: 0, oldestDate: nil),
            "No history recorded yet."
        )
    }

    func testSummarySentenceIncludesCountSizeAndOldestDate() {
        let oldest = Date(timeIntervalSince1970: 1_787_660_000)
        let expectedDate = DateFormatter.localizedString(from: oldest, dateStyle: .medium, timeStyle: .none)

        let summary = AdvancedSettingsTab.historySummary(eventCount: 42, sizeBytes: 200_000, oldestDate: oldest)

        XCTAssertEqual(summary, "42 events, 195 KB, since \(expectedDate).")
    }

    func testSummaryFallsBackToDashWhenOldestDateIsMissing() {
        let summary = AdvancedSettingsTab.historySummary(eventCount: 3, sizeBytes: 1024, oldestDate: nil)

        XCTAssertEqual(summary, "3 events, 1 KB, since —.")
    }

    func testSizeUnderOneMegabyteRendersAsWholeKilobytes() {
        XCTAssertEqual(AdvancedSettingsTab.formatSize(bytes: 200_000), "195 KB")
    }

    func testSizeAtExactlyOneMegabyteRendersAsMegabytes() {
        XCTAssertEqual(AdvancedSettingsTab.formatSize(bytes: 1_048_576), "1.0 MB")
    }

    func testSizeOverOneMegabyteRendersWithOneDecimal() {
        // A heavy year of history (tens of MB) should still read cleanly.
        XCTAssertEqual(AdvancedSettingsTab.formatSize(bytes: 26_000_000), "24.8 MB")
    }

    func testZeroBytesRendersAsZeroKilobytes() {
        XCTAssertEqual(AdvancedSettingsTab.formatSize(bytes: 0), "0 KB")
    }
}

extension AdvancedSettingsTabTests {

    func testAfterClearingSucceedsResultsInClearedOutcome() {
        XCTAssertEqual(ClearHistoryOutcome.afterClearing(didSucceed: true), .cleared)
    }

    func testAfterClearingFailsResultsInFailedOutcome() {
        XCTAssertEqual(ClearHistoryOutcome.afterClearing(didSucceed: false), .failed)
    }
}
