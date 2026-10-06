import Foundation
import HuantaiCore
import XCTest

@testable import HuantaiWeb

final class LocalWebServerTests: XCTestCase {
    func testSharedEnvelopeCarriesDailyReferenceAndSignedOverage() throws {
        let now = Date()
        let reset = now.addingTimeInterval(3 * 86400)
        for used in [0.0, 100] {
            let window = UsageWindow(usedPercent: used, windowDurationMins: 10080, resetsAt: reset)
            let value = IndexSnapshot(
                sessions: [], usage: UsageSummary(weekly: window), sources: [], updatedAt: now)
            struct Envelope: Decodable { let usageProjection: UsageProjection }
            let decoded = try HuantaiJSON.decoder().decode(
                Envelope.self, from: WebSnapshotEncoder.encode(value, now: now))
            let today = try XCTUnwrap(decoded.usageProjection.todayReferenceRemainingPercent)
            XCTAssertEqual(today < 0, used == 100)
            XCTAssertNotNil(decoded.usageProjection.todayReferenceEndsAt)
            XCTAssertNotNil(decoded.usageProjection.todayReferenceTimeZone)
        }
    }

    func testWebSnapshotPreservesReplyOrderWithinTheSameSecond() throws {
        let early = Date(timeIntervalSince1970: 1_800_000_000.123)
        let late = Date(timeIntervalSince1970: 1_800_000_000.789)
        let snapshot = IndexSnapshot(
            sessions: [
                SessionRecord(
                    id: "a-early", title: "较早回复", cwd: "/fixture", source: "Codex",
                    machine: "测试", lastAIReplyAt: early, isCompleted: true),
                SessionRecord(
                    id: "z-late", title: "较晚回复", cwd: "/fixture", source: "Codex",
                    machine: "测试", lastAIReplyAt: late),
            ],
            usage: UsageSummary(), sources: [], updatedAt: late)
        let data = try WebSnapshotEncoder.encode(snapshot, now: late)
        struct Envelope: Decodable { let snapshot: IndexSnapshot }
        let decoded = try HuantaiJSON.decoder().decode(Envelope.self, from: data).snapshot
        XCTAssertEqual(decoded.sessions.map(\.id), ["z-late", "a-early"])
        XCTAssertTrue(
            decoded.sessions[1].isCompleted, "API must retain completed records for the recovery filter")
        XCTAssertEqual(decoded.filteredSessions().map(\.id), ["z-late"])
        XCTAssertEqual(
            try XCTUnwrap(decoded.sessions[0].lastAIReplyAt).timeIntervalSince1970,
            late.timeIntervalSince1970, accuracy: 0.0001)
        XCTAssertEqual(
            try XCTUnwrap(decoded.sessions[1].lastAIReplyAt).timeIntervalSince1970,
            early.timeIntervalSince1970, accuracy: 0.0001)
        let encoded = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(encoded.contains(".789Z"))
        XCTAssertTrue(encoded.contains(".123Z"))
    }

    func testLoopbackServerReturnsIsolatedFixtureAndRejectsForeignOrigin() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "huantai-web-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(
            dataDirectory: directory.appendingPathComponent("data"),
            codexDirectory: directory.appendingPathComponent("fixture-codex"),
            botmuxDirectory: directory.appendingPathComponent("fixture-botmux"),
            deepSeekHarnessDirectory: directory.appendingPathComponent("fixture-dsh"))
        let server = LocalWebServer(store: store, port: UInt16.random(in: 25000...30000))
        try server.start()
        defer { server.stop() }
        XCTAssertEqual(server.url.host, "127.0.0.1")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let client = URLSession(configuration: configuration)
        defer { client.invalidateAndCancel() }
        let responseReady = expectation(description: "Fixture snapshot")
        let url = server.url.appendingPathComponent("api/snapshot")
        client.dataTask(with: url) { data, response, error in
            XCTAssertNil(error)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            if let data, let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let snapshot = payload["snapshot"] as? [String: Any],
                let sessions = snapshot["sessions"] as? [Any],
                let usage = snapshot["usage"] as? [String: Any]
            {
                XCTAssertTrue(sessions.isEmpty)
                XCTAssertEqual(usage["status"] as? String, "未连接用量来源")
                XCTAssertNotNil(payload["usageProjection"])
            } else {
                XCTFail("Expected bounded snapshot JSON")
            }
            responseReady.fulfill()
        }.resume()
        wait(for: [responseReady], timeout: 6)
        let denied = expectation(description: "Cross-origin denied")
        var request = URLRequest(url: url)
        request.setValue("https://external.example", forHTTPHeaderField: "Origin")
        client.dataTask(with: request) { data, response, error in
            XCTAssertNil(error)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 403)
            XCTAssertFalse(String(decoding: data ?? Data(), as: UTF8.self).contains("sources"))
            denied.fulfill()
        }.resume()
        wait(for: [denied], timeout: 6)
    }
}
