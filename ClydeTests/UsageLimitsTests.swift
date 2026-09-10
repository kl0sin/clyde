import XCTest
@testable import Clyde

final class UsageLimitsTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15 08:00:00 UTC

    private func payload(_ rateLimits: String?) -> Data {
        let limits = rateLimits.map { ",\"rate_limits\": \($0)" } ?? ""
        return """
        {"session_id": "abc-123", "model": {"id": "claude-opus-5", "display_name": "Opus"}\(limits)}
        """.data(using: .utf8)!
    }

    // MARK: - Parsing

    func testParsesBothWindows() {
        let data = payload("""
        {"five_hour": {"used_percentage": 42.5, "resets_at": 1800004320},
         "seven_day": {"used_percentage": 18, "resets_at": 1800400000}}
        """)
        let limits = UsageLimits.parse(data, modifiedAt: now)
        XCTAssertEqual(limits?.fiveHour?.usedPercentage, 42.5)
        XCTAssertEqual(limits?.fiveHour?.resetsAt, Date(timeIntervalSince1970: 1_800_004_320))
        XCTAssertEqual(limits?.sevenDay?.usedPercentage, 18)
        XCTAssertEqual(limits?.sessionID, "abc-123")
        XCTAssertEqual(limits?.modelName, "Opus")
        XCTAssertEqual(limits?.updatedAt, now)
    }

    func testOneWindowMayBeAbsent() {
        let data = payload("""
        {"seven_day": {"used_percentage": 18, "resets_at": 1800400000}}
        """)
        let limits = UsageLimits.parse(data, modifiedAt: now)
        XCTAssertNil(limits?.fiveHour)
        XCTAssertNotNil(limits?.sevenDay)
        XCTAssertEqual(limits?.hasAnyWindow, true)
    }

    func testNoRateLimitsMeansNoValue() {
        XCTAssertNil(UsageLimits.parse(payload(nil), modifiedAt: now))
    }

    func testGarbageMeansNoValue() {
        XCTAssertNil(UsageLimits.parse("not json".data(using: .utf8)!, modifiedAt: now))
    }

    func testWindowWithoutBothFieldsIsIgnored() {
        let data = payload("""
        {"five_hour": {"used_percentage": 42.5}, "seven_day": {"resets_at": 1800400000}}
        """)
        XCTAssertNil(UsageLimits.parse(data, modifiedAt: now))
    }

    // MARK: - Expiry

    func testExpiredWindowIsDropped() {
        let limits = UsageLimits(
            fiveHour: UsageWindow(usedPercentage: 84, resetsAt: now.addingTimeInterval(-60)),
            sevenDay: UsageWindow(usedPercentage: 30, resetsAt: now.addingTimeInterval(3600)),
            updatedAt: now.addingTimeInterval(-3600), sessionID: nil, modelName: nil)
        let live = limits.droppingExpiredWindows(now: now)
        XCTAssertNil(live.fiveHour)
        XCTAssertNotNil(live.sevenDay)
    }

    // MARK: - Level

    func testLevelThresholds() {
        let w = { (p: Double) in UsageWindow(usedPercentage: p, resetsAt: self.now) }
        XCTAssertEqual(UsageLimits.level(for: w(79.9), rateLimited: false), .normal)
        XCTAssertEqual(UsageLimits.level(for: w(80), rateLimited: false), .warning)
        XCTAssertEqual(UsageLimits.level(for: w(100), rateLimited: false), .exhausted)
        XCTAssertEqual(UsageLimits.level(for: w(42), rateLimited: true), .exhausted)
    }

    // MARK: - Staleness

    func testStaleAfterThirtyMinutesWithoutALiveSession() {
        let limits = UsageLimits(fiveHour: nil, sevenDay: nil,
                                 updatedAt: now.addingTimeInterval(-31 * 60), sessionID: nil, modelName: nil)
        XCTAssertTrue(limits.isStale(now: now, hasLiveSession: false))
        XCTAssertFalse(limits.isStale(now: now, hasLiveSession: true))
        let fresh = UsageLimits(fiveHour: nil, sevenDay: nil,
                                updatedAt: now.addingTimeInterval(-29 * 60), sessionID: nil, modelName: nil)
        XCTAssertFalse(fresh.isStale(now: now, hasLiveSession: false))
    }

    // MARK: - Text

    func testResetTextCountsDownUnderADay() {
        let w = UsageWindow(usedPercentage: 42, resetsAt: now.addingTimeInterval(72 * 60))
        XCTAssertEqual(UsageLimits.resetText(for: w, now: now, level: .normal), "resets in 1h 12m")
        let soon = UsageWindow(usedPercentage: 100, resetsAt: now.addingTimeInterval(47 * 60))
        XCTAssertEqual(UsageLimits.resetText(for: soon, now: now, level: .exhausted), "resumes in 0h 47m")
    }

    func testResetTextNamesTheDayBeyondADay() {
        let w = UsageWindow(usedPercentage: 18, resetsAt: now.addingTimeInterval(25 * 3600))
        let text = UsageLimits.resetText(for: w, now: now, level: .normal)
        XCTAssertTrue(text.hasPrefix("resets "), text)
        XCTAssertFalse(text.contains(" in "), text)
    }

    func testPercentText() {
        let w = UsageWindow(usedPercentage: 42.6, resetsAt: now)
        XCTAssertEqual(UsageLimits.percentText(for: w, level: .normal), "43%")
        XCTAssertEqual(UsageLimits.percentText(for: w, level: .exhausted), "full")
    }

    func testFreshnessText() {
        let limits = UsageLimits(fiveHour: nil, sevenDay: nil,
                                 updatedAt: now.addingTimeInterval(-40), sessionID: "abc", modelName: "Opus")
        XCTAssertEqual(limits.freshnessText(now: now, sessionName: "clyde", stale: false),
                       "Updated 40s ago from the clyde session")
        let old = UsageLimits(fiveHour: nil, sevenDay: nil,
                              updatedAt: now.addingTimeInterval(-47 * 60), sessionID: nil, modelName: nil)
        XCTAssertEqual(old.freshnessText(now: now, sessionName: nil, stale: true),
                       "As of 47m ago · refreshes with the next Claude Code turn")
    }
}
