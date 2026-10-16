import HuantaiCore
import XCTest

@testable import HuantaiApp

final class ResetCreditsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    func testWarningStartsAtThreeDaysAndUsesEarliestAvailableExpiry() {
        let deadline = now.addingTimeInterval(3 * 86400)
        var usage = UsageSummary(
            resetCount: 2,
            resetCredits: [
                ResetCreditExpiry(expiresAt: deadline.addingTimeInterval(86400)),
                ResetCreditExpiry(expiresAt: deadline.addingTimeInterval(1)),
            ])
        XCTAssertFalse(ResetCreditsBadge.isExpiringSoon(usage, now: now))
        usage.resetCredits?[1].expiresAt = deadline
        XCTAssertTrue(ResetCreditsBadge.isExpiringSoon(usage, now: now))
        usage.resetCredits?[1].expiresAt = now.addingTimeInterval(1)
        XCTAssertTrue(ResetCreditsBadge.isExpiringSoon(usage, now: now))
    }

    func testExpiredUnknownAndNonExpiringCreditsDoNotWarn() {
        let usage = UsageSummary(
            resetCount: 4,
            resetCredits: [
                ResetCreditExpiry(expiresAt: now),
                ResetCreditExpiry(expiresAt: now.addingTimeInterval(-1)),
                ResetCreditExpiry(),
                ResetCreditExpiry(expiresAt: now.addingTimeInterval(60), expirationKnown: false),
            ])
        XCTAssertFalse(ResetCreditsBadge.isExpiringSoon(usage, now: now))
        XCTAssertFalse(ResetCreditsBadge.isExpiringSoon(UsageSummary(resetCount: 2), now: now))
    }

    func testUnavailableCreditsDoNotWarn() {
        let credits = [ResetCreditExpiry(expiresAt: now.addingTimeInterval(60))]
        XCTAssertFalse(ResetCreditsBadge.isExpiringSoon(UsageSummary(resetCredits: credits), now: now))
        XCTAssertFalse(
            ResetCreditsBadge.isExpiringSoon(UsageSummary(resetCount: 0, resetCredits: credits), now: now))
        let usage = UsageSummary(resetCount: 1, resetCredits: [ResetCreditExpiry()] + credits)
        XCTAssertFalse(ResetCreditsBadge.isExpiringSoon(usage, now: now))
    }
}
