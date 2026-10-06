import CSQLite
import Foundation
import XCTest

@testable import HuantaiCore

final class ScanPerformanceEvidenceTests: XCTestCase {
    /// Record timing evidence without a machine-dependent CI threshold; byte counts enforce incrementality.
    func test303SessionWarmAndSingleAppendScans() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "huantai-perf-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let codex = root.appendingPathComponent("codex")
        let logs = codex.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        var database: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open(codex.appendingPathComponent("state_5.sqlite").path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(
            sqlite3_exec(
                database, "CREATE TABLE threads (id TEXT,title TEXT,cwd TEXT,source TEXT,rollout_path TEXT)",
                nil, nil, nil), SQLITE_OK)
        let initial =
            "{\"timestamp\":\"2026-01-01T00:00:00Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"phase\":\"final_answer\"}}\n"
        let ignored =
            "{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\",\"arguments\":\"SYNTHETIC_BODY\"}}\n"
        for index in 0..<303 {
            let id = String(format: "01234567-89ab-cdef-0123-%012d", index)
            let file = logs.appendingPathComponent("\(index).jsonl")
            try Data((initial + (index == 0 ? String(repeating: ignored, count: 20000) : "")).utf8).write(
                to: file)
            let path = file.path.replacingOccurrences(of: "'", with: "''")
            XCTAssertEqual(
                sqlite3_exec(
                    database,
                    "INSERT INTO threads VALUES ('\(id)','合成会话','/fixture','cli','\(path)')", nil, nil, nil),
                SQLITE_OK)
        }
        let store = SessionStore(
            dataDirectory: root.appendingPathComponent("state"), codexDirectory: codex,
            botmuxDirectory: root.appendingPathComponent("empty-botmux"))
        let coldStart = ProcessInfo.processInfo.systemUptime
        let cold = try store.refresh()
        let coldMilliseconds = (ProcessInfo.processInfo.systemUptime - coldStart) * 1000
        var unchanged: [Double] = []
        var appended: [Double] = []
        for _ in 0..<20 {
            let start = ProcessInfo.processInfo.systemUptime
            let snapshot = try store.refresh()
            unchanged.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            XCTAssertEqual(snapshot.scan?.bytesRead, 0)
            XCTAssertEqual(snapshot.scan?.unchangedFiles, 303)
        }
        let line = Data(
            "{\"timestamp\":\"2026-01-03T00:00:00Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"phase\":\"commentary\"}}\n"
                .utf8)
        for _ in 0..<20 {
            let handle = try FileHandle(forWritingTo: logs.appendingPathComponent("0.jsonl"))
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.close()
            let start = ProcessInfo.processInfo.systemUptime
            let snapshot = try store.refresh()
            appended.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            XCTAssertEqual(snapshot.scan?.appendedFiles, 1)
            XCTAssertEqual(snapshot.scan?.fullReadFiles, 0)
            XCTAssertEqual(snapshot.scan?.bytesRead, UInt64(line.count))
        }
        if let output = ProcessInfo.processInfo.environment["HUANTAI_SCAN_PERFORMANCE_OUTPUT"] {
            func statistics(_ samples: [Double]) -> [String: Any] {
                let sorted = samples.sorted()
                return [
                    "sample_count": samples.count, "samples_ms": samples,
                    "p50_ms": sorted[sorted.count / 2],
                    "p95_ms": sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1],
                ]
            }
            let result: [String: Any] = [
                "fixture": "303 synthetic sessions, one long log; same scanner and persistence",
                "cold_ms": coldMilliseconds, "cold_bytes_read": cold.scan?.bytesRead ?? 0,
                "unchanged": statistics(unchanged), "single_file_append": statistics(appended),
                "bytes_per_append": line.count,
                "unchanged_bytes_read": 0, "full_reads_after_initial": 0,
            ]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: output), options: .atomic)
        }
    }
}
