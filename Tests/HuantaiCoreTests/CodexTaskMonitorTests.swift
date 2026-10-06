import Foundation
import XCTest

@testable import HuantaiCore

final class CodexTaskMonitorTests: XCTestCase {
    private func fixture() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "huantai-hooks-" + UUID().uuidString)
        let folder = root.appendingPathComponent("sessions/2026/10/06")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (root, folder.appendingPathComponent("rollout-fixture.jsonl"))
    }

    private func append(_ payload: [String: Any], to file: URL, date: Date = Date()) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var data = try JSONSerialization.data(withJSONObject: [
            "type": "event_msg", "timestamp": formatter.string(from: date), "payload": payload,
        ])
        data.append(10)
        if !FileManager.default.fileExists(atPath: file.path) { try Data().write(to: file) }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    func testNoHistoricalReplayAndExactlyOneStartAndTerminalNotificationPerTurn() throws {
        let (root, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try append(
            ["type": "task_started", "turn_id": "old"], to: file, date: Date().addingTimeInterval(-60))
        try append(
            ["type": "task_complete", "turn_id": "old"], to: file, date: Date().addingTimeInterval(-59))
        let monitor = CodexTaskMonitor(root: root, enabledAt: Date().addingTimeInterval(-1))
        XCTAssertTrue(monitor.poll().isEmpty)
        try append(["type": "task_started", "turn_id": "new"], to: file)
        try append(["type": "task_started", "turn_id": "new"], to: file)
        try append(["type": "task_complete", "turn_id": "new"], to: file)
        try append(["type": "task_complete", "turn_id": "new"], to: file)
        XCTAssertEqual(monitor.poll().map(\.state), [.started, .completed])
        XCTAssertTrue(monitor.poll().isEmpty)
    }

    func testTerminalErrorsInferActiveTurnButRetryToolFailureAndInterruptStaySilent() throws {
        let (root, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: file)
        let monitor = CodexTaskMonitor(root: root, enabledAt: Date().addingTimeInterval(-1))
        try append(["type": "task_started", "turn_id": "failed"], to: file)
        try append(["type": "exec_command_end", "exit_code": 1], to: file)
        try append(["type": "error", "will_retry": true], to: file)
        try append(["type": "error", "codex_error_info": "thread_rollback_failed"], to: file)
        try append(["type": "error", "codex_error_info": ["active_turn_not_steerable": [:]]], to: file)
        XCTAssertEqual(monitor.poll().map(\.state), [.started])
        try append(["type": "error", "codex_error_info": "usage_limit_exceeded"], to: file)
        try append(["type": "task_complete", "turn_id": "failed"], to: file)
        XCTAssertEqual(monitor.poll().map(\.state), [.failed])
        try append(["type": "task_started", "turn_id": "cancelled"], to: file)
        try append(["type": "turn_aborted", "turn_id": "cancelled", "reason": "interrupted"], to: file)
        XCTAssertEqual(monitor.poll().map(\.state), [.started])
    }

    func testSplitLinesNewResumedFileAndSymlinkBoundary() throws {
        let (root, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let monitor = CodexTaskMonitor(root: root, enabledAt: Date().addingTimeInterval(-1))
        try append(["type": "task_started", "turn_id": "resumed"], to: file)
        let data = try Data(contentsOf: file)
        try data.dropLast(10).write(to: file)
        monitor.includeTranscript(file)
        XCTAssertTrue(monitor.poll().isEmpty)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: data.suffix(10))
        try handle.close()
        XCTAssertEqual(monitor.poll().map(\.state), [.started])
        let outside = root.appendingPathComponent("outside.jsonl")
        try append(["type": "task_started", "turn_id": "outside"], to: outside)
        let link = file.deletingLastPathComponent().appendingPathComponent("symlink.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        monitor.includeTranscript(link)
        XCTAssertTrue(monitor.poll().isEmpty)
    }

    func testEnablingMidTurnRecoversTurnIDForTerminalErrorWithoutReplayingStart() throws {
        let (root, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try append(
            ["type": "task_started", "turn_id": "active"], to: file, date: Date().addingTimeInterval(-60))
        let monitor = CodexTaskMonitor(root: root, enabledAt: Date().addingTimeInterval(-1))
        try append(["type": "error", "codex_error_info": "unauthorized"], to: file)
        let events = monitor.poll()
        XCTAssertEqual(events.map(\.state), [.failed])
        XCTAssertEqual(events.first?.turnID, "active")
    }

    func testNativeFailedTaskCompleteWithErrorNeverPlaysSuccess() throws {
        let (root, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: file)
        let monitor = CodexTaskMonitor(root: root, enabledAt: Date().addingTimeInterval(-1))
        try append(["type": "task_started", "turn_id": "native-failed"], to: file)
        try append(
            [
                "type": "task_complete", "turn_id": "native-failed", "last_agent_message": NSNull(),
                "error": ["message": "Synthetic terminal failure", "codex_error_info": "bad_request"],
            ], to: file)
        XCTAssertEqual(monitor.poll().map(\.state), [.started, .failed])
        XCTAssertTrue(monitor.poll().isEmpty)
    }
}
