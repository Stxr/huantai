import CSQLite
import Foundation
import XCTest

@testable import HuantaiCore

final class DeepSeekHarnessTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var store: SessionStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "huantai-dsh-" + UUID().uuidString)
        home = root.appendingPathComponent("dsh")
        store = SessionStore(
            dataDirectory: root.appendingPathComponent("state"),
            codexDirectory: root.appendingPathComponent("codex"),
            botmuxDirectory: root.appendingPathComponent("botmux"), deepSeekHarnessDirectory: home)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    @discardableResult
    private func artifact(_ id: String = "session-fixture", version: Int = 4, events: [[String: Any]] = [])
        throws -> URL
    {
        let directory = home.appendingPathComponent("sessions/project/" + id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(
            version == 0 ? "session.jsonl" : "session.v\(version).jsonl")
        let header: [String: Any] = [
            "type": "session", "id": id, "version": version, "cwd": "/fixture/project", "createdAt": 1000,
        ]
        let lines = try ([header] + events).map { try JSONSerialization.data(withJSONObject: $0) }
        var data = Data()
        for line in lines {
            data.append(line)
            data.append(10)
        }
        try data.write(to: url)
        return url
    }

    private func reply(_ text: String, time: Double, type: String = "text") -> [String: Any] {
        [
            "type": "assistant/message", "time": time,
            "data": ["message": ["role": "assistant", "content": [["type": type, "text": text]]]],
        ]
    }

    func testDefaultsAndLegacyConfigurationEnableBothSources() throws {
        let old = try JSONDecoder().decode(StoreConfiguration.self, from: Data("{\"remoteTargets\":[]}".utf8))
        XCTAssertTrue(old.codexEnabled)
        XCTAssertTrue(old.deepSeekHarnessEnabled)
        XCTAssertTrue(try store.configuration().deepSeekHarnessEnabled)
        try artifact(events: [reply("真实可见回复", time: 2000)])
        let snapshot = try store.refresh()
        XCTAssertEqual(snapshot.sessions.count, 1)
        XCTAssertEqual(snapshot.sessions[0].source, "DeepSeek Harness")
        XCTAssertEqual(
            snapshot.sources.first(where: { $0.id == "deepseek-harness" })?.status, "已连接（只读）；1 个会话")
    }

    func testTitleAndReplyUseLoggedEventsWithoutPromptReasoningOrMTime() throws {
        let url = try artifact(events: [
            ["type": "session/title", "data": ["title": "官方会话标题"]],
            reply("第一条回复", time: 2000), reply("新的可见回复", time: 3000),
            reply("PRIVATE_REASONING", time: 9000, type: "reasoning"),
            ["type": "user/message", "time": 10000, "data": ["content": "PRIVATE_PROMPT"]],
            ["type": "tool/result", "time": 11000, "data": ["message": ["content": "PRIVATE_TOOL_RESULT"]]],
        ])
        let original = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        let snapshot = try store.refresh()
        let session = try XCTUnwrap(snapshot.sessions.first)
        XCTAssertEqual(session.id, "dsh:session-fixture")
        XCTAssertEqual(session.title, "官方会话标题")
        XCTAssertEqual(session.lastAIReplyAt, Date(timeIntervalSince1970: 3))
        XCTAssertEqual(session.lastAIReplyPreview, "新的可见回复")
        XCTAssertEqual(session.openURL, SourceOpening.deepSeekHarnessURL)
        XCTAssertNil(session.openUnavailableReason)
        XCTAssertEqual(try store.snapshot().sessions[0].openURL, SourceOpening.deepSeekHarnessURL)
        XCTAssertEqual(try Data(contentsOf: url), original)
        let publicIndex = try String(
            contentsOf: store.dataDirectory.appendingPathComponent("index.json"), encoding: .utf8)
        XCTAssertFalse(publicIndex.contains("PRIVATE_"))
    }

    func testWarmScanSkipsBodiesAndNewGenerationReplacesOldWithoutDuplicate() throws {
        try artifact(version: 0, events: [reply("旧格式", time: 2000)])
        XCTAssertEqual(try store.refresh().sessions.count, 1)
        let warm = try store.refresh()
        XCTAssertEqual(warm.scan?.bytesRead, 0)
        XCTAssertEqual(warm.scan?.unchangedFiles, 1)
        try artifact(version: 4, events: [reply("新格式", time: 4000)])
        let changed = try store.refresh()
        XCTAssertEqual(changed.sessions.count, 1)
        XCTAssertEqual(changed.sessions[0].lastAIReplyPreview, "新格式")
        XCTAssertEqual(changed.scan?.fullReadFiles, 1)
        try artifact(version: 4, events: [reply("又一条回复", time: 6000)])
        XCTAssertEqual(try store.refresh().sessions[0].lastAIReplyAt, Date(timeIntervalSince1970: 6))
    }

    func testApplicationRouteRejectsSessionParametersAndUpgradesOldCachedRecords() throws {
        for route in ["dsh://open", "dsh://open/", "DSH://open"] {
            XCTAssertEqual(SessionStore.validatedOpenURL(route), SourceOpening.deepSeekHarnessURL)
        }
        for route in [
            "dsh://open?session=fixture", "dsh://open/session-fixture", "dsh://open#fixture",
            "dsh://user:password@open", "dsh://open:123", "dsh://other",
        ] {
            XCTAssertNil(SessionStore.validatedOpenURL(route))
        }
        try artifact()
        var old = try store.refresh()
        old.sessions[0].openURL = nil
        old.sessions[0].openUnavailableReason = "官方客户端尚无精确跳转入口"
        try HuantaiJSON.encoder().encode(old).write(
            to: store.dataDirectory.appendingPathComponent("index.json"))
        try FileManager.default.removeItem(at: home)
        let reloaded = SessionStore(
            dataDirectory: store.dataDirectory, codexDirectory: store.codexDirectory,
            botmuxDirectory: store.botmuxDirectory, deepSeekHarnessDirectory: home)
        XCTAssertEqual(try reloaded.snapshot().sessions[0].openURL, SourceOpening.deepSeekHarnessURL)
        XCTAssertNil(try reloaded.snapshot().sessions[0].openUnavailableReason)
        XCTAssertEqual(try reloaded.refresh().sessions[0].openURL, SourceOpening.deepSeekHarnessURL)
    }

    func testOfficialConcatenatedZstdFramesReadAllMetadataAndThenCache() throws {
        let directory = home.appendingPathComponent("sessions/project/session-compressed")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoded =
            "KLUv/SBSVQIA9AN7InR5cGUiOiJzZXNzaW9uIiwidmVyOjQsImlkLWNvbXByZXNzZWQiLCJjdy9maXh0dXJlL3Byb2plY3QifQoDAEBYPrdoW5ootS/9IDnJAQB7InR5cGUiOiJzZXNzaW9uL3RpdGxlIiwiZGF0YSI6eyJ0aXRsZSI6IuWOi+e8qeS8muivnSJ9fQootS/9IIyNAwDkBXsidHlwZSI6ImFzc2lzdGFudC9tZXNzYWdlIiwidGltZSI6MTc5MTIwLCJkYXRhIjp7Ijp7InJvbCIsImNvbnRlbnQiOlt0ZXg6IuWOi+e8qeWbnuWkjSJ9XX19fQoGACoCesJQYvENfIpSBCUDZQ=="
        try XCTUnwrap(Data(base64Encoded: encoded)).write(
            to: directory.appendingPathComponent("session.v4.jsonl.zstd"))
        let snapshot = try store.refresh()
        XCTAssertEqual(snapshot.sessions.first?.title, "压缩会话")
        XCTAssertEqual(snapshot.sessions.first?.lastAIReplyPreview, "压缩回复")
        XCTAssertEqual(snapshot.sessions.first?.lastAIReplyAt, Date(timeIntervalSince1970: 1_791_200_000))
        XCTAssertEqual(try store.refresh().scan?.bytesRead, 0)
    }

    func testDisableAndDirectorySettingsPersistAndKeepPreferences() throws {
        try artifact(events: [reply("合成回复", time: 2000)])
        let session = try XCTUnwrap(store.refresh().sessions.first)
        try store.setFavorite(id: session.id, value: true)
        try store.setCompleted(id: session.id, value: true)
        try store.setSessionSource(.deepSeekHarness, enabled: false)
        try store.setSessionSource(.codex, enabled: false)
        XCTAssertTrue(try store.refresh().sessions.isEmpty)
        XCTAssertEqual(
            try store.snapshot().sources.first(where: { $0.id == "deepseek-harness" })?.status, "已关闭")
        let reloaded = SessionStore(
            dataDirectory: store.dataDirectory, codexDirectory: store.codexDirectory,
            botmuxDirectory: store.botmuxDirectory, deepSeekHarnessDirectory: home)
        XCTAssertFalse(try reloaded.configuration().deepSeekHarnessEnabled)
        XCTAssertFalse(try reloaded.configuration().codexEnabled)
        try reloaded.setSessionSource(.deepSeekHarness, enabled: true)
        let restored = try XCTUnwrap(reloaded.refresh().sessions.first)
        XCTAssertTrue(restored.isFavorite)
        XCTAssertTrue(restored.isCompleted)
        let alternate = root.appendingPathComponent("alternate")
        try reloaded.setSessionDirectory(.deepSeekHarness, path: alternate.path)
        XCTAssertEqual(try reloaded.configuration().deepSeekHarnessHome, alternate.path)
        XCTAssertTrue(try reloaded.refresh().sessions.isEmpty)
        try reloaded.setSessionDirectory(.deepSeekHarness, path: nil)
        XCTAssertNil(try reloaded.configuration().deepSeekHarnessHome)
        XCTAssertEqual(try reloaded.refresh().sessions.count, 1)
        XCTAssertThrowsError(try reloaded.setSessionDirectory(.codex, path: "relative/path"))
        XCTAssertNil(try reloaded.configuration().codexHome)
    }

    func testUnknownGenerationAndWrongIdentityDoNotReuseOlderArtifacts() throws {
        try artifact("session-future", version: 0, events: [reply("已被替代", time: 2000)])
        try artifact("session-future", version: 99, events: [reply("未知格式", time: 3000)])
        let wrong = try artifact("session-wrong")
        try Data("{\"type\":\"session\",\"version\":4,\"id\":\"different\"}\n".utf8).write(to: wrong)
        try artifact("session-good")
        let snapshot = try store.refresh()
        XCTAssertEqual(snapshot.sessions.map(\.id), ["dsh:session-good"])
        XCTAssertNil(snapshot.sessions[0].lastAIReplyAt)
        XCTAssertTrue(
            snapshot.sources.first(where: { $0.id == "deepseek-harness" })?.status.contains("2 个记录") == true)
    }

    func testSymlinkArtifactsAreSkippedAndMissingSourceKeepsPriorCache() throws {
        let url = try artifact(events: [reply("合成回复", time: 2000)])
        let linked = home.appendingPathComponent("sessions/project/session-linked")
        try FileManager.default.createSymbolicLink(
            at: linked, withDestinationURL: url.deletingLastPathComponent())
        XCTAssertEqual(try store.refresh().sessions.count, 1)
        try FileManager.default.moveItem(
            at: home.appendingPathComponent("sessions"), to: home.appendingPathComponent("hidden-sessions"))
        let cached = try store.refresh()
        XCTAssertEqual(cached.sessions.count, 1)
        XCTAssertTrue(
            cached.sources.first(where: { $0.id == "deepseek-harness" })?.status.contains("上次缓存") == true)
        try store.setSessionSource(.deepSeekHarness, enabled: false)
        XCTAssertTrue(try store.refresh().sessions.isEmpty)
    }

    func testCodexAndHarnessCoexistWithDistinctIDsAndIndependentSwitches() throws {
        let id = "01234567-89ab-cdef-0123-456789abcdef"
        try artifact(id, events: [reply("Harness 回复", time: 2000)])
        let codex = store.codexDirectory
        let rollout = codex.appendingPathComponent("sessions/fixture.jsonl")
        try FileManager.default.createDirectory(
            at: rollout.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(
            "{\"type\":\"response_item\",\"timestamp\":\"1970-01-01T00:00:10Z\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"text\":\"Codex 回复\"}]}}\n"
                .utf8
        ).write(to: rollout)
        var database: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open(codex.appendingPathComponent("state_5.sqlite").path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        let sql =
            "CREATE TABLE threads(id TEXT,title TEXT,cwd TEXT,source TEXT,rollout_path TEXT); INSERT INTO threads VALUES('\(id)','Codex 会话','/fixture','cli','\(rollout.path)');"
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
        let both = try store.refresh()
        XCTAssertEqual(both.sessions.map(\.id), [id, "dsh:" + id])
        XCTAssertEqual(both.sessions.map(\.source), ["Codex", "DeepSeek Harness"])
        try store.setCompleted(id: "dsh:" + id, value: true)
        XCTAssertFalse(try store.snapshot().sessions.first(where: { $0.id == id })!.isCompleted)
        try store.setSessionSource(.codex, enabled: false)
        XCTAssertEqual(try store.refresh().sessions.map(\.id), ["dsh:" + id])
        try store.setSessionSource(.codex, enabled: true)
        XCTAssertEqual(try store.refresh().sessions.count, 2)
        try store.setSessionSource(.deepSeekHarness, enabled: false)
        XCTAssertEqual(try store.refresh().sessions.map(\.id), [id])
    }
}
