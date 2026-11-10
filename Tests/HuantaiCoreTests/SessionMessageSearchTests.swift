import Foundation
import XCTest
@testable import HuantaiCore

final class SessionMessageSearchTests: XCTestCase {
    func testOnlyQuestionsAndFinalAnswersAreSearchable() throws {
        func message(_ role: String, _ phase: String) -> Data {
            Data("{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"\(role)\",\"phase\":\"\(phase)\",\"content\":[{\"text\":\"中文 NEEDLE\"}]}}".utf8)
        }
        XCTAssertTrue(SessionMessageSearch.matches("中文 needle", line: message("user", "")))
        XCTAssertTrue(SessionMessageSearch.matches("needle", line: message("assistant", "final_answer")))
        for (role, phase) in [("assistant", "analysis"), ("assistant", "commentary"), ("system", ""), ("developer", "")] {
            XCTAssertFalse(SessionMessageSearch.matches("needle", line: message(role, phase)))
        }
        XCTAssertFalse(SessionMessageSearch.matches("needle", line: Data(#"{"type":"response_item","payload":{"type":"function_call_output","output":"needle"}}"#.utf8)))
        XCTAssertTrue(SessionMessageSearch.matches("needle", line: Data(#"{"type":"event_msg","payload":{"type":"user_\u006dessage","message":"needle"}}"#.utf8)))
        XCTAssertTrue(SessionMessageSearch.matches("你好", line: Data(#"{"type":"event_msg","payload":{"type":"user_message","message":"\u4f60\u597d"}}"#.utf8)))
        XCTAssertTrue(SessionMessageSearch.matches("answer", line: Data(#"{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"answer"}}"#.utf8)))
        XCTAssertTrue(SessionMessageSearch.matches("question", line: Data(#"{"type":"user/message","data":{"content":"question"}}"#.utf8)))
        XCTAssertTrue(SessionMessageSearch.matches("answer", line: Data(#"{"type":"assistant/message","data":{"message":{"role":"assistant","content":[{"type":"text","text":"answer"}]}}}"#.utf8)))
    }

    func testFullHistoryBeyondTailWindowAndFinalLine() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let first = #"{"type":"event_msg","payload":{"type":"user_message","message":"early question"}}"#
        let last = #"{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"last answer"}}"#
        let filler = #"{"type":"response_item","payload":{"type":"function_call_output","output":""# + String(repeating: "x", count: 65536) + #""}}"#
        try Data((first + "\n" + String(repeating: filler + "\n", count: 130) + last).utf8).write(to: url)
        XCTAssertTrue(try SessionMessageSearch.contains("early question", in: url, isCancelled: { false }))
        XCTAssertTrue(try SessionMessageSearch.contains("last answer", in: url, isCancelled: { false }))
    }
}
