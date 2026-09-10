import XCTest
@testable import Clyde

final class UsageLimitsAlertsTests: XCTestCase {
    private let reset = Date(timeIntervalSince1970: 1_800_004_320)

    private func limits(_ percent: Double, resetsAt: Date? = nil) -> UsageLimits {
        UsageLimits(fiveHour: UsageWindow(usedPercentage: percent, resetsAt: resetsAt ?? reset),
                    sevenDay: UsageWindow(usedPercentage: 30, resetsAt: reset.addingTimeInterval(86_400)),
                    updatedAt: Date(), sessionID: nil, modelName: nil)
    }

    func testWarnsOnceWhenTheSessionCrossesEighty() {
        var alerts = UsageLimitsAlerts()
        XCTAssertEqual(alerts.alerts(for: limits(79), rateLimited: false), [])
        XCTAssertEqual(alerts.alerts(for: limits(81), rateLimited: false), [.sessionNearLimit(resetsAt: reset)])
        XCTAssertEqual(alerts.alerts(for: limits(90), rateLimited: false), [])
    }

    func testANewWindowWarnsAgain() {
        var alerts = UsageLimitsAlerts()
        _ = alerts.alerts(for: limits(85), rateLimited: false)
        let next = reset.addingTimeInterval(5 * 3600)
        XCTAssertEqual(alerts.alerts(for: limits(85, resetsAt: next), rateLimited: false),
                       [.sessionNearLimit(resetsAt: next)])
    }

    func testTheWeekDoesNotWarn() {
        var alerts = UsageLimitsAlerts()
        let weekOnly = UsageLimits(fiveHour: nil,
                                   sevenDay: UsageWindow(usedPercentage: 95, resetsAt: reset),
                                   updatedAt: Date(), sessionID: nil, modelName: nil)
        XCTAssertEqual(alerts.alerts(for: weekOnly, rateLimited: false), [])
    }

    func testAnnouncesTheResetAfterExhaustion() {
        var alerts = UsageLimitsAlerts()
        XCTAssertEqual(alerts.alerts(for: limits(100), rateLimited: false), [.sessionNearLimit(resetsAt: reset)])
        // Still exhausted: nothing new.
        XCTAssertEqual(alerts.alerts(for: limits(100), rateLimited: true), [])
        // The window turned over.
        XCTAssertEqual(alerts.alerts(for: limits(3, resetsAt: reset.addingTimeInterval(5 * 3600)), rateLimited: false),
                       [.sessionBackAfterReset])
    }

    func testAVanishedWindowAnnouncesOnlyOnceItsResetTimeHasPassed() {
        var alerts = UsageLimitsAlerts()
        _ = alerts.alerts(for: limits(100), rateLimited: false)
        XCTAssertEqual(alerts.alerts(for: nil, rateLimited: false, now: reset.addingTimeInterval(-60)), [])
        XCTAssertEqual(alerts.alerts(for: nil, rateLimited: false, now: reset.addingTimeInterval(60)),
                       [.sessionBackAfterReset])
    }

    func testClosingTheRateLimitedSessionIsNotAReset() {
        var alerts = UsageLimitsAlerts()
        _ = alerts.alerts(for: limits(42), rateLimited: true)
        XCTAssertEqual(alerts.alerts(for: limits(42), rateLimited: false, now: reset.addingTimeInterval(-60)), [])
        XCTAssertEqual(alerts.alerts(for: limits(42), rateLimited: false, now: reset.addingTimeInterval(60)),
                       [.sessionBackAfterReset])
    }

    func testStartingExhaustedDoesNotAnnounceAReset() {
        var alerts = UsageLimitsAlerts()
        XCTAssertEqual(alerts.alerts(for: nil, rateLimited: false), [])
        XCTAssertEqual(alerts.alerts(for: limits(10), rateLimited: false), [])
    }
}
