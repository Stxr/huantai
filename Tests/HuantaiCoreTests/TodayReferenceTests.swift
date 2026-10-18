import Foundation
import HuantaiCore
import XCTest

final class TodayReferenceTests: XCTestCase {
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    func testDayEndAllowanceCarriesUnspentReferenceAndRetainsSignedOverage() throws {
        let reset = date("2026-10-08T16:00:00Z")
        let now = date("2026-10-04T04:00:00Z")
        let calendar = calendar("Asia/Shanghai")
        for used in [9.0, 40, 50, 120] {
            let window = UsageWindow(usedPercent: used, windowDurationMins: 10080, resetsAt: reset)
            let projection = UsageProjection.calculate(window: window, now: now, calendar: calendar)
            let allowance = 100.0 * 3 / 7
            XCTAssertEqual(
                try XCTUnwrap(projection.todayReferenceBudgetPercent), allowance, accuracy: 0.000001)
            XCTAssertEqual(
                try XCTUnwrap(projection.todayReferenceRemainingPercent), allowance - used, accuracy: 0.000001
            )
            XCTAssertEqual(projection.todayReferenceEndsAt, date("2026-10-04T16:00:00Z"))
            XCTAssertEqual(projection.todayReferenceTimeZone, "Asia/Shanghai")
        }
    }

    func testReferenceBoundaryFollowsResetAndDoesNotChangeWithTimeZone() throws {
        let window = UsageWindow(
            usedPercent: 9, windowDurationMins: 10080, resetsAt: date("2026-10-08T16:00:00Z"))
        let before = UsageProjection.calculate(
            window: window, now: date("2026-10-04T15:59:59Z"), calendar: calendar("Asia/Shanghai"))
        let after = UsageProjection.calculate(
            window: window, now: date("2026-10-04T16:00:00Z"), calendar: calendar("Asia/Shanghai"))
        XCTAssertEqual(
            try XCTUnwrap(after.todayReferenceBudgetPercent) - XCTUnwrap(before.todayReferenceBudgetPercent),
            100.0 / 7, accuracy: 0.000001)
        let utc = UsageProjection.calculate(
            window: window, now: date("2026-10-04T16:00:00Z"), calendar: calendar("UTC"))
        XCTAssertEqual(utc.todayReferenceEndsAt, after.todayReferenceEndsAt)
        XCTAssertEqual(utc.todayReferenceBudgetPercent, after.todayReferenceBudgetPercent)
    }

    func testFirstAndLastReferenceDaysAreFullDaysAndExpireAtReset() throws {
        let reset = date("2026-10-09T04:00:00Z")
        let window = UsageWindow(usedPercent: 5, windowDurationMins: 10080, resetsAt: reset)
        let calendar = calendar("Asia/Shanghai")
        let start = reset.addingTimeInterval(-7 * 86400)
        let first = UsageProjection.calculate(window: window, now: start, calendar: calendar)
        XCTAssertEqual(try XCTUnwrap(first.todayReferenceBudgetPercent), 100.0 / 7, accuracy: 0.000001)
        XCTAssertEqual(first.todayReferenceEndsAt, start.addingTimeInterval(86400))
        let last = UsageProjection.calculate(
            window: window, now: reset.addingTimeInterval(-1), calendar: calendar)
        XCTAssertEqual(last.todayReferenceBudgetPercent, 100)
        XCTAssertEqual(last.todayReferenceRemainingPercent, 95)
        XCTAssertEqual(last.todayReferenceEndsAt, reset)
        for instant in [start.addingTimeInterval(-1), reset, reset.addingTimeInterval(1)] {
            XCTAssertNil(
                UsageProjection.calculate(window: window, now: instant, calendar: calendar)
                    .todayReferenceRemainingPercent)
        }
        XCTAssertNil(UsageProjection.calculate(window: nil).todayReferenceRemainingPercent)
    }

    func testInvalidUsageAndLegacyProjectionDoNotInventDailyAllowance() throws {
        let reset = date("2026-10-09T04:00:00Z")
        for used in [-1.0, .nan, .infinity] {
            let window = UsageWindow(usedPercent: used, windowDurationMins: 10080, resetsAt: reset)
            XCTAssertNil(
                UsageProjection.calculate(window: window, now: reset.addingTimeInterval(-86400))
                    .todayReferenceRemainingPercent)
        }
        let legacy = Data(#"{"greenPercent":9,"overBudgetPercent":0,"status":"synthetic"}"#.utf8)
        XCTAssertNil(
            try HuantaiJSON.decoder().decode(UsageProjection.self, from: legacy)
                .todayReferenceRemainingPercent)
    }

    func testMiddayResetMatchesScreenshotAndCrossingMidnightDoesNotGrantMoreQuota() throws {
        let reset = date("2026-10-20T04:58:00Z")
        let window = UsageWindow(usedPercent: 1, windowDurationMins: 10080, resetsAt: reset)
        let endOfFirstDay = date("2026-10-14T04:58:00Z")
        for instant in ["2026-10-13T04:58:00Z", "2026-10-13T16:00:00Z", "2026-10-14T04:57:59Z"] {
            for zone in ["Asia/Shanghai", "UTC", "America/Los_Angeles"] {
                let result = UsageProjection.calculate(
                    window: window, now: date(instant), calendar: calendar(zone))
                XCTAssertEqual(
                    try XCTUnwrap(result.todayReferenceBudgetPercent), 100.0 / 7, accuracy: 0.000001)
                XCTAssertEqual(
                    try XCTUnwrap(result.todayReferenceRemainingPercent), 100.0 / 7 - 1, accuracy: 0.000001)
                XCTAssertEqual(
                    try XCTUnwrap(result.todayReferenceAllowancePercent), 100.0 / 7, accuracy: 0.000001)
                XCTAssertEqual(result.todayReferenceEndsAt, endOfFirstDay)
            }
        }
        let next = UsageProjection.calculate(window: window, now: endOfFirstDay)
        XCTAssertEqual(try XCTUnwrap(next.todayReferenceRemainingPercent), 200.0 / 7 - 1, accuracy: 0.000001)
        XCTAssertEqual(next.todayReferenceEndsAt, endOfFirstDay.addingTimeInterval(86400))
    }

    func testNewOfficialWindowDoesNotCarryOldUsageOrReferenceAllowance() throws {
        let reset = date("2026-10-13T04:58:00Z")
        let old = UsageWindow(usedPercent: 95, windowDurationMins: 10080, resetsAt: reset)
        let previous = UsageProjection.calculate(window: old, now: reset.addingTimeInterval(-1))
        XCTAssertEqual(previous.todayReferenceRemainingPercent, 5)
        XCTAssertNil(UsageProjection.calculate(window: old, now: reset).todayReferenceRemainingPercent)
        let fresh = UsageWindow(
            usedPercent: 1, windowDurationMins: 10080, resetsAt: reset.addingTimeInterval(7 * 86400))
        let result = UsageProjection.calculate(window: fresh, now: reset)
        XCTAssertEqual(
            try XCTUnwrap(result.todayReferenceRemainingPercent), 100.0 / 7 - 1, accuracy: 0.000001)
        XCTAssertEqual(result.todayReferenceEndsAt, reset.addingTimeInterval(86400))
    }

    func testDaylightSavingChangeKeepsReferenceDaysAtTwentyFourHours() throws {
        let start = date("2026-10-31T19:00:00Z")
        let window = UsageWindow(
            usedPercent: 0, windowDurationMins: 10080, resetsAt: start.addingTimeInterval(7 * 86400))
        let zone = calendar("America/Los_Angeles")
        let before = UsageProjection.calculate(
            window: window, now: start.addingTimeInterval(86400 - 1), calendar: zone)
        let after = UsageProjection.calculate(
            window: window, now: start.addingTimeInterval(86400), calendar: zone)
        XCTAssertEqual(before.todayReferenceEndsAt, start.addingTimeInterval(86400))
        XCTAssertEqual(after.todayReferenceEndsAt, start.addingTimeInterval(2 * 86400))
        XCTAssertEqual(try XCTUnwrap(after.todayReferenceBudgetPercent), 200.0 / 7, accuracy: 0.000001)
    }
}
