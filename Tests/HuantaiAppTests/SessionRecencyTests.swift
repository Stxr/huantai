import HuantaiCore
import XCTest

@testable import HuantaiApp

final class SessionRecencyTests: XCTestCase {
    func testRollingCutoffsIncludeBoundaryAndExcludeOlderOrMissingReplies() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        var session = SessionRecord(id: "fixture", title: "消息", cwd: "/", source: "Codex", machine: "本机")
        XCTAssertTrue(SessionRecency.all.includes(session, now: now))
        for option in SessionRecency.allCases where option != .all {
            XCTAssertFalse(option.includes(session, now: now))
            let cutoff = now.addingTimeInterval(-Double(option.days!) * 86400)
            session.lastAIReplyAt = cutoff
            XCTAssertTrue(option.includes(session, now: now))
            session.lastAIReplyAt = cutoff.addingTimeInterval(-1)
            XCTAssertFalse(option.includes(session, now: now))
            session.lastAIReplyAt = nil
        }
    }
}
