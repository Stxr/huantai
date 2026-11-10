import Foundation
import XCTest
@testable import HuantaiCore

final class BotmuxSentMessageTests: XCTestCase {
    private let body = "原表的端范围写得太粗了\n" + String(repeating: "正文", count: 1024) + "末尾关键词"

    private func event(command: [String]? = nil, status: String = "completed", exit: Int = 0, acknowledged: Bool = true) -> [String: Any] {
        ["type": "event_msg", "payload": ["type": "item_completed", "item": [
            "type": "CommandExecution", "status": status, "exit_code": exit,
            "command": command ?? ["/bin/bash", "-lc", "botmux send --response-kind final --mention-back <<'EOF'\n" + body + "\nEOF"],
            "aggregated_output": acknowledged ? "已发送\n{\"success\":true,\"messageId\":\"om_fixture\"}\n" : "{\"success\":false}",
        ]]]
    }

    func testAcknowledgedBotmuxAnswerIsSearchableInFull() throws {
        let data = try JSONSerialization.data(withJSONObject: event())
        XCTAssertTrue(SessionMessageSearch.matches("原表的端范围写得太粗了", line: data))
        XCTAssertTrue(SessionMessageSearch.matches("末尾关键词", line: data))
        XCTAssertFalse(SessionMessageSearch.matches("--mention-back", line: data))
        let direct = event(command: ["/usr/local/bin/botmux", "send", "--text", body])
        XCTAssertTrue(SessionMessageSearch.matches("末尾关键词", line: try JSONSerialization.data(withJSONObject: direct)))
    }

    func testFailedAndUnrelatedToolCallsRemainExcluded() throws {
        for item in [event(exit: 1), event(status: "inProgress"), event(acknowledged: false),
                     event(command: ["/bin/bash", "-lc", "echo botmux send <<'EOF'\n" + body + "\nEOF"]),
                     event(command: ["/bin/bash", "-lc", "botmux send --text ok; cat <<'EOF'\n" + body + "\nEOF"])] {
            XCTAssertFalse(SessionMessageSearch.matches("原表的端范围写得太粗了", line: try JSONSerialization.data(withJSONObject: item)))
        }
    }

    func testRemoteExtractorMatchesLocalAcceptanceRules() throws {
        let events = [event(), event(exit: 1), event(acknowledged: false),
                      event(command: ["botmux", "send", "--text", body]),
                      event(command: ["/bin/bash", "-lc", "echo botmux send <<'EOF'\n" + body + "\nEOF"])]
        let encoded = try JSONSerialization.data(withJSONObject: events).base64EncodedString()
        let program = "import json, base64\n" + BotmuxSearchProgram.script
            + "\nevents=json.loads(base64.b64decode('\(encoded)'))\nprint(json.dumps([botmux_sent_text(e['payload']) for e in events]))\n"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("test.py")
        try Data(program.utf8).write(to: source)
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [source.path]
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let values = try JSONDecoder().decode([String?].self, from: output)
        XCTAssertEqual(values, [body, nil, nil, body, nil])
    }
}
