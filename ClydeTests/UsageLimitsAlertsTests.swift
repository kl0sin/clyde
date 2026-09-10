import XCTest
@testable import Clyde

final class UsageLimitsAlertsTests: XCTestCase {
    private let reset = Date(timeIntervalSince1970: 1_800_004_320)

    /// Comfortably before `reset`, and before every other reset time
    /// these tests construct — used as the default `now` so nothing in
    /// this file depends on the wall clock relative to the fixed
    /// `reset` fixture.
    private var before: Date { reset.addingTimeInterval(-60) }

    private func limits(_ percent: Double, resetsAt: Date? = nil) -> UsageLimits {
        UsageLimits(fiveHour: UsageWindow(usedPercentage: percent, resetsAt: resetsAt ?? reset),
                    sevenDay: UsageWindow(usedPercentage: 30, resetsAt: reset.addingTimeInterval(86_400)),
                    updatedAt: Date(), sessionID: nil, modelName: nil)
    }

    func testWarnsOnceWhenTheSessionCrossesEighty() {
        var alerts = UsageLimitsAlerts()
        XCTAssertEqual(alerts.alerts(for: limits(79), rateLimited: false, now: before), [])
        XCTAssertEqual(alerts.alerts(for: limits(81), rateLimited: false, now: before),
                       [.sessionNearLimit(resetsAt: reset)])
        XCTAssertEqual(alerts.alerts(for: limits(90), rateLimited: false, now: before), [])
    }

    func testANewWindowWarnsAgain() {
        var alerts = UsageLimitsAlerts()
        _ = alerts.alerts(for: limits(85), rateLimited: false, now: before)
        let next = reset.addingTimeInterval(5 * 3600)
        XCTAssertEqual(alerts.alerts(for: limits(85, resetsAt: next), rateLimited: false, now: before),
                       [.sessionNearLimit(resetsAt: next)])
    }

    func testTheWeekDoesNotWarn() {
        var alerts = UsageLimitsAlerts()
        let weekOnly = UsageLimits(fiveHour: nil,
                                   sevenDay: UsageWindow(usedPercentage: 95, resetsAt: reset),
                                   updatedAt: Date(), sessionID: nil, modelName: nil)
        XCTAssertEqual(alerts.alerts(for: weekOnly, rateLimited: false, now: before), [])
    }

    func testAnnouncesTheResetAfterExhaustion() {
        var alerts = UsageLimitsAlerts()
        XCTAssertEqual(alerts.alerts(for: limits(100), rateLimited: false, now: before),
                       [.sessionNearLimit(resetsAt: reset)])
        // Still exhausted: nothing new.
        XCTAssertEqual(alerts.alerts(for: limits(100), rateLimited: true, now: before), [])
        // The window turned over.
        let next = reset.addingTimeInterval(5 * 3600)
        XCTAssertEqual(alerts.alerts(for: limits(3, resetsAt: next), rateLimited: false, now: before),
                       [.sessionBackAfterReset])
    }

    func testAVanishedWindowAnnouncesOnlyOnceItsResetTimeHasPassed() {
        var alerts = UsageLimitsAlerts()
        _ = alerts.alerts(for: limits(100), rateLimited: false, now: before)
        XCTAssertEqual(alerts.alerts(for: nil, rateLimited: false, now: reset.addingTimeInterval(-60)), [])
        XCTAssertEqual(alerts.alerts(for: nil, rateLimited: false, now: reset.addingTimeInterval(60)),
                       [.sessionBackAfterReset])
    }

    func testClosingTheRateLimitedSessionIsNotAReset() {
        var alerts = UsageLimitsAlerts()
        _ = alerts.alerts(for: limits(42), rateLimited: true, now: before)
        XCTAssertEqual(alerts.alerts(for: limits(42), rateLimited: false, now: reset.addingTimeInterval(-60)), [])
        XCTAssertEqual(alerts.alerts(for: limits(42), rateLimited: false, now: reset.addingTimeInterval(60)),
                       [.sessionBackAfterReset])
    }

    func testStartingExhaustedDoesNotAnnounceAReset() {
        var alerts = UsageLimitsAlerts()
        XCTAssertEqual(alerts.alerts(for: nil, rateLimited: false, now: before), [])
        XCTAssertEqual(alerts.alerts(for: limits(10), rateLimited: false, now: before), [])
    }

    /// A new window that arrives already spent (still `rateLimited`, or
    /// itself at 100%) must not say "you can continue" in the same tick
    /// it says "used up" — the two facts belong to the same window.
    func testANewWindowThatIsAlreadySpentDoesNotAnnounceAReset() {
        var alerts = UsageLimitsAlerts()
        _ = alerts.alerts(for: limits(100), rateLimited: false, now: before)
        let next = reset.addingTimeInterval(5 * 3600)
        XCTAssertEqual(alerts.alerts(for: limits(100, resetsAt: next), rateLimited: true, now: before),
                       [.sessionNearLimit(resetsAt: next)])
    }
}
