import XCTest
@testable import HuantaiApp

final class SessionToastLifetimeTests: XCTestCase {
    func testHoverPausesAndLeavingResumesRemainingTime() {
        var lifetime = SessionToastLifetime(duration: 1.5, now: 0, hovered: false)
        XCTAssertFalse(lifetime.advance(now: 0.5, hovered: false))
        XCTAssertFalse(lifetime.advance(now: 0.55, hovered: true))
        XCTAssertFalse(lifetime.advance(now: 60, hovered: true))
        XCTAssertEqual(lifetime.remaining, 1)
        XCTAssertFalse(lifetime.advance(now: 61, hovered: false))
        XCTAssertFalse(lifetime.advance(now: 61.9, hovered: false))
        XCTAssertTrue(lifetime.advance(now: 62, hovered: false))
    }

    func testInitiallyHoveredToastAndReplacementHaveIndependentLifetimes() {
        var lifetime = SessionToastLifetime(duration: 1.5, now: 10, hovered: true)
        XCTAssertFalse(lifetime.advance(now: 100, hovered: true))
        XCTAssertEqual(lifetime.remaining, 1.5)
        lifetime = SessionToastLifetime(duration: 1.5, now: 100, hovered: false)
        XCTAssertFalse(lifetime.advance(now: 101, hovered: false))
        XCTAssertTrue(lifetime.advance(now: 101.5, hovered: false))
    }
}
