import CSQLite
import Foundation
import XCTest

@testable import HuantaiCore

final class CoreTests: XCTestCase {
    private var root: URL!
    private var codex: URL!
    private var index: URL!
    private var botmux: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "huantai-tests-" + UUID().uuidString)
        codex = root.appendingPathComponent("codex")
        index = root.appendingPathComponent("index")
        botmux = root.appendingPathComponent("botmux")
        try FileManager.default.createDirectory(
            at: codex.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: codex.appendingPathComponent("archived_sessions"), withIntermediateDirectories: true)
        try makeDatabase(
            codex.appendingPathComponent("state_5.sqlite"),
            statements: [
                "CREATE TABLE threads (id TEXT PRIMARY KEY,title TEXT,cwd TEXT,source TEXT,rollout_path TEXT,first_user_message TEXT)"
            ])
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func store() -> SessionStore {
        SessionStore(
            dataDirectory: index, codexDirectory: codex, botmuxDirectory: botmux,
            deepSeekHarnessDirectory: root.appendingPathComponent("dsh"))
    }
    private func makeDatabase(_ url: URL, statements: [String]) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        for statement in statements { XCTAssertEqual(sqlite3_exec(db, statement, nil, nil, nil), SQLITE_OK) }
    }
    @discardableResult
    private func addThread(
        _ id: String, title: String = "合成项目", cwd: String = "/synthetic/project",
        source: String = "cli", events: [String] = [], customPath: URL? = nil
    ) throws -> URL {
        let path = customPath ?? codex.appendingPathComponent("sessions/" + id + ".jsonl")
        if customPath == nil { try Data(events.joined(separator: "\n").appending("\n").utf8).write(to: path) }
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "''") + "'" }
        let values = [id, title, cwd, source, path.path, "SYNTHETIC_PRIVATE_INPUT_MUST_NOT_BE_INDEXED"].map(
            quote
        ).joined(separator: ",")
        try makeDatabase(
            codex.appendingPathComponent("state_5.sqlite"),
            statements: ["INSERT INTO threads VALUES (" + values + ")"])
        return path
    }
    private func message(_ stamp: String, role: String = "assistant", phase: String? = "final_answer")
        -> String
    {
        let phaseJSON = phase.map { ",\"phase\":\"\($0)\"" } ?? ""
        return
            "{\"timestamp\":\"\(stamp)\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"\(role)\"\(phaseJSON),\"content\":[{\"text\":\"SYNTHETIC_VISIBLE_REPLY\"}]}}"
    }
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    func testVisibleAIReplyIncludesProgressAndIgnoresUserAnalysisAndMTime() throws {
        let path = try addThread(
            "one",
            events: [
                message("2026-01-01T00:00:00Z"),
                message("2026-01-02T00:00:00Z", role: "user"),
                message("2026-01-03T00:00:00Z", phase: "commentary"),
                message("2026-01-04T00:00:00Z", phase: "analysis"),
            ])
        try FileManager.default.setAttributes(
            [.modificationDate: date("2026-09-01T00:00:00Z")], ofItemAtPath: path.path)
        let snapshot = try store().refresh()
        XCTAssertEqual(snapshot.sessions.first?.lastAIReplyAt, date("2026-01-03T00:00:00Z"))
        let persisted = try String(contentsOf: index.appendingPathComponent("index.json"), encoding: .utf8)
        XCTAssertFalse(persisted.contains("SYNTHETIC_PRIVATE_INPUT"))
        XCTAssertTrue(persisted.contains("SYNTHETIC_VISIBLE_REPLY"))
    }

    func testReplyPreviewTracksVisibleMessagesAcrossIncrementalRefreshAndReplacement() throws {
        func event(_ stamp: String, _ role: String, _ phase: String, _ text: String) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: [
                "timestamp": stamp, "type": "response_item",
                "payload": [
                    "type": "message", "role": role, "phase": phase,
                    "content": [["type": "output_text", "text": text]],
                ],
            ])
            return String(decoding: data, as: UTF8.self)
        }
        let path = try addThread(
            "preview",
            events: [
                event("2026-01-01T00:00:00Z", "assistant", "final_answer", "已完成。\n  可以使用。"),
                event("2026-01-02T00:00:00Z", "assistant", "analysis", "PRIVATE_ANALYSIS"),
                event("2026-01-03T00:00:00Z", "user", "final_answer", "PRIVATE_USER"),
            ])
        let reader = store()
        XCTAssertEqual(try reader.refresh().sessions.first?.lastAIReplyPreview, "已完成。 可以使用。")
        XCTAssertEqual(try reader.refresh().sessions.first?.lastAIReplyPreview, "已完成。 可以使用。")
        let append =
            try event(
                "2026-01-04T00:00:00Z", "assistant", "commentary",
                String(repeating: "新", count: 500)) + "\n"
        let handle = try FileHandle(forWritingTo: path)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(append.utf8))
        try handle.close()
        XCTAssertEqual(
            try reader.refresh().sessions.first?.lastAIReplyPreview,
            String(repeating: "新", count: 320))
        let completion = """
            {"timestamp":"2026-01-05T00:00:00Z","type":"event_msg","payload":{"type":"task_complete","last_agent_message":"最终结果"}}

            """
        let finalHandle = try FileHandle(forWritingTo: path)
        try finalHandle.seekToEnd()
        try finalHandle.write(contentsOf: Data(completion.utf8))
        try finalHandle.close()
        XCTAssertEqual(try reader.refresh().sessions.first?.lastAIReplyPreview, "最终结果")
        let persisted = try String(contentsOf: index.appendingPathComponent("index.json"), encoding: .utf8)
        XCTAssertFalse(persisted.contains("PRIVATE_ANALYSIS"))
        XCTAssertFalse(persisted.contains("PRIVATE_USER"))
        try Data((try event("2026-01-06T00:00:00Z", "user", "final_answer", "PRIVATE_USER") + "\n").utf8)
            .write(to: path, options: .atomic)
        XCTAssertNil(try reader.refresh().sessions.first?.lastAIReplyPreview)
    }

    func testLegacyFinalAndTaskCompletionTimestamp() throws {
        let path = try addThread(
            "one",
            events: [
                message("2026-01-01T00:00:00Z", phase: nil),
                "{\"timestamp\":\"2026-01-04T00:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"completed_at\":\"2026-01-02T00:00:00Z\",\"last_agent_message\":\"SYNTHETIC_ONLY\"}}",
            ])
        XCTAssertEqual(try RolloutReplyScanner.lastAIReply(in: path), date("2026-01-02T00:00:00Z"))
    }

    func testCompletionWithoutFinalAgentMessageDoesNotAdvanceReplyTime() throws {
        let path = try addThread(
            "one",
            events: [
                message("2026-01-01T00:00:00Z"),
                "{\"timestamp\":\"2026-01-05T00:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"completed_at\":\"2026-01-05T00:00:00Z\"}}",
                "{\"timestamp\":\"2026-01-06T00:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"last_agent_message\":\" \"}}",
            ])
        XCTAssertEqual(try RolloutReplyScanner.lastAIReply(in: path), date("2026-01-01T00:00:00Z"))
    }

    func testStableSortNilRepliesLastAndSearchOnlyTitleAndCwd() throws {
        try addThread("z", title: "地图", events: [message("2026-01-01T00:00:00Z")])
        try addThread("a", cwd: "/synthetic/camera", events: [message("2026-01-01T00:00:00Z")])
        try addThread("b", events: [message("2026-01-02T00:00:00Z")])
        try addThread("n", events: [message("2026-01-05T00:00:00Z", role: "user")])
        let snapshot = try store().refresh()
        XCTAssertEqual(snapshot.sessions.map(\.id), ["b", "a", "z", "n"])
        XCTAssertEqual(snapshot.filteredSessions(query: "CAMERA").map(\.id), ["a"])
        XCTAssertEqual(snapshot.filteredSessions(query: "地图").map(\.id), ["z"])
        XCTAssertTrue(snapshot.filteredSessions(query: "SYNTHETIC_BODY").isEmpty)
    }

    func testFavoritesPersistAcrossStoresAndRefresh() throws {
        try addThread("one")
        try addThread("two")
        let first = store()
        _ = try first.refresh()
        try first.setFavorite(id: "one", value: true)
        try store().setFavorite(id: "two", value: true)
        XCTAssertEqual(try first.snapshot().filteredSessions(favoritesOnly: true).map(\.id), ["one", "two"])
        XCTAssertTrue(try store().refresh().sessions.allSatisfy(\.isFavorite))
        try first.setFavorite(id: "one", value: false)
        XCTAssertEqual(try store().snapshot().filteredSessions(favoritesOnly: true).map(\.id), ["two"])
    }

    func testCompletedStatusPersistsAcrossStoresRefreshAndRestoreWithoutChangingFavoritesOrRollouts() throws {
        let path = try addThread("one", events: [message("2026-01-02T00:00:00Z")])
        try addThread("two", events: [message("2026-01-01T00:00:00Z")])
        let original = try Data(contentsOf: path)
        let first = store()
        _ = try first.refresh()
        try first.setFavorite(id: "one", value: true)
        try store().setCompleted(id: "one", value: true)
        XCTAssertEqual(try first.snapshot().filteredSessions().map(\.id), ["two"])
        let completed = try XCTUnwrap(first.snapshot().sessions.first { $0.id == "one" })
        XCTAssertTrue(completed.isCompleted)
        XCTAssertTrue(completed.isFavorite)
        XCTAssertEqual(completed.lastAIReplyAt, date("2026-01-02T00:00:00Z"))
        let refreshed = try store().refresh()
        XCTAssertTrue(refreshed.sessions.first?.isCompleted == true)
        XCTAssertEqual(refreshed.scan?.bytesRead, 0)
        XCTAssertEqual(refreshed.filteredSessions(includeCompleted: true).count, 2)
        try first.setCompleted(id: "one", value: false)
        XCTAssertEqual(try store().snapshot().filteredSessions().map(\.id), ["one", "two"])
        XCTAssertTrue(try store().snapshot().sessions.first!.isFavorite)
        XCTAssertEqual(try Data(contentsOf: path), original)
        XCTAssertThrowsError(try first.setCompleted(id: "missing", value: true))
    }

    func testLegacyIndexAndPreferencesDecodeAsUnfinishedAndKeepFavoriteAndMapping() throws {
        try addThread("one")
        let current = store()
        _ = try current.refresh()
        let mapping = "lark://applink.feishu.cn/client/chat/open?openChatId=oc_fixture"
        let oldPreferences: [String: Any] = ["favorites": ["one"], "openMappings": ["one": mapping]]
        try JSONSerialization.data(withJSONObject: oldPreferences).write(
            to: index.appendingPathComponent("preferences.json"))
        var old = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: index.appendingPathComponent("index.json")))
                as? [String: Any])
        var records = try XCTUnwrap(old["sessions"] as? [[String: Any]])
        for item in records.indices { records[item].removeValue(forKey: "isCompleted") }
        old["sessions"] = records
        try JSONSerialization.data(withJSONObject: old).write(to: index.appendingPathComponent("index.json"))
        let decoded = try XCTUnwrap(store().snapshot().sessions.first)
        XCTAssertFalse(decoded.isCompleted)
        XCTAssertTrue(decoded.isFavorite)
        XCTAssertEqual(decoded.openURL, mapping)
        try store().setCompleted(id: "one", value: true)
        let saved = try XCTUnwrap(store().snapshot().sessions.first)
        XCTAssertTrue(saved.isCompleted)
        XCTAssertTrue(saved.isFavorite)
        XCTAssertEqual(saved.openURL, mapping)
    }

    func testRolloutTraversalAndSymlinkCannotEscapeAllowedRoots() throws {
        let outside = root.appendingPathComponent("outside.jsonl")
        try Data(message("2026-01-01T00:00:00Z").appending("\n").utf8).write(to: outside)
        let symlink = codex.appendingPathComponent("sessions/linked.jsonl")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
        try addThread("outside", customPath: outside)
        try addThread("symlink", customPath: symlink)
        let snapshot = try store().refresh()
        XCTAssertEqual(snapshot.sessions.count, 2)
        XCTAssertTrue(snapshot.sessions.allSatisfy { $0.lastAIReplyAt == nil })
        XCTAssertTrue(snapshot.sources[0].status.contains("2 个"))
    }

    func testSessionRootSymlinkCannotAuthorizeOutsideContent() throws {
        let outside = root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let rollout = outside.appendingPathComponent("one.jsonl")
        try Data(message("2026-01-01T00:00:00Z").utf8).write(to: rollout)
        try FileManager.default.removeItem(at: codex.appendingPathComponent("sessions"))
        try FileManager.default.createSymbolicLink(
            at: codex.appendingPathComponent("sessions"), withDestinationURL: outside)
        try addThread("one", customPath: codex.appendingPathComponent("sessions/one.jsonl"))
        XCTAssertNil(try store().refresh().sessions.first?.lastAIReplyAt)
    }

    func testIncrementalCacheRescansAppendedFinalReply() throws {
        let path = try addThread("one", events: [message("2026-01-01T00:00:00Z")])
        let first = try store().refresh()
        let handle = try FileHandle(forWritingTo: path)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(message("2026-01-02T00:00:00Z").utf8))
        try handle.close()
        XCTAssertEqual(first.sessions.first?.lastAIReplyAt, date("2026-01-01T00:00:00Z"))
        XCTAssertEqual(try store().refresh().sessions.first?.lastAIReplyAt, date("2026-01-02T00:00:00Z"))
    }

    func testWarmScanReadsNoBodiesAndAppendReadsOnlyNewBytesWhileReordering() throws {
        let ignored =
            "{\"timestamp\":\"2026-01-01T00:00:00Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\"}}"
        let path = try addThread(
            "a", events: [message("2026-01-01T00:00:00Z")] + Array(repeating: ignored, count: 2000))
        try addThread("b", events: [message("2026-01-02T00:00:00Z")])
        let instance = store()
        let initial = try instance.refresh()
        XCTAssertEqual(initial.sessions.map(\.id), ["b", "a"])
        XCTAssertEqual(initial.scan?.fullReadFiles, 2)
        let cachePath = index.appendingPathComponent("reply-cache.json")
        let cacheModified =
            try FileManager.default.attributesOfItem(atPath: cachePath.path)[.modificationDate] as? Date
        let warm = try instance.refresh()
        XCTAssertEqual(warm.scan?.unchangedFiles, 2)
        XCTAssertEqual(warm.scan?.bytesRead, 0)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: cachePath.path)[.modificationDate] as? Date,
            cacheModified)
        let appended = Data((message("2026-01-03T00:00:00Z", phase: "commentary") + "\n").utf8)
        let handle = try FileHandle(forWritingTo: path)
        try handle.seekToEnd()
        try handle.write(contentsOf: appended)
        try handle.close()
        let changed = try instance.refresh()
        XCTAssertEqual(changed.sessions.map(\.id), ["a", "b"])
        XCTAssertEqual(changed.sessions[0].lastAIReplyAt, date("2026-01-03T00:00:00Z"))
        XCTAssertEqual(changed.scan?.appendedFiles, 1)
        XCTAssertEqual(changed.scan?.fullReadFiles, 0)
        XCTAssertEqual(changed.scan?.bytesRead, UInt64(appended.count))
        XCTAssertEqual(try store().refresh().scan?.bytesRead, 0)
    }

    func testPartialAppendedJSONIsReplayedWhenCompleted() throws {
        let path = try addThread("a", events: [message("2026-01-01T00:00:00Z")])
        let instance = store()
        _ = try instance.refresh()
        let line = Data((message("2026-01-03T00:00:00Z", phase: "commentary") + "\n").utf8)
        let split = line.count / 2
        let handle = try FileHandle(forWritingTo: path)
        try handle.seekToEnd()
        try handle.write(contentsOf: line.prefix(split))
        XCTAssertEqual(try instance.refresh().sessions[0].lastAIReplyAt, date("2026-01-01T00:00:00Z"))
        try handle.write(contentsOf: line.dropFirst(split))
        try handle.close()
        let completed = try instance.refresh()
        XCTAssertEqual(completed.sessions[0].lastAIReplyAt, date("2026-01-03T00:00:00Z"))
        XCTAssertEqual(completed.scan?.appendedFiles, 1)
        XCTAssertEqual(completed.scan?.bytesRead, UInt64(line.count))
    }

    func testReplacedAndTruncatedLogsDiscardOldCursorAndReply() throws {
        let path = try addThread("a", events: [message("2026-01-05T00:00:00Z")])
        let instance = store()
        _ = try instance.refresh()
        try Data((message("2026-01-02T00:00:00Z") + "\n").utf8).write(to: path, options: .atomic)
        let replaced = try instance.refresh()
        XCTAssertEqual(replaced.scan?.fullReadFiles, 1)
        XCTAssertEqual(replaced.sessions[0].lastAIReplyAt, date("2026-01-02T00:00:00Z"))
        let short =
            "{\"timestamp\":\"2026-01-01T00:00:00Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\"}}\n"
        try Data(short.utf8).write(to: path)
        let truncated = try instance.refresh()
        XCTAssertEqual(truncated.scan?.fullReadFiles, 1)
        XCTAssertEqual(truncated.sessions[0].lastAIReplyAt, date("2026-01-01T00:00:00Z"))
    }

    func testLegacyFinalOnlyCacheMigratesWithoutTrustingItsTimestamp() throws {
        try addThread(
            "a",
            events: [message("2026-01-01T00:00:00Z"), message("2026-01-03T00:00:00Z", phase: "commentary")])
        let instance = store()
        _ = try instance.refresh()
        let path = index.appendingPathComponent("reply-cache.json")
        var cache = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        cache["version"] = 1
        var entries = try XCTUnwrap(cache["entries"] as? [String: [String: Any]])
        entries["a"]?["lastAIReplyAt"] = "2026-01-01T00:00:00Z"
        cache["entries"] = entries
        try JSONSerialization.data(withJSONObject: cache).write(to: path, options: .atomic)
        let migrated = try instance.refresh()
        XCTAssertEqual(migrated.scan?.fullReadFiles, 1)
        XCTAssertEqual(migrated.sessions[0].lastAIReplyAt, date("2026-01-03T00:00:00Z"))
    }

    func testSameSecondReplyOrderSurvivesIndexAndReplyCacheReload() throws {
        // The ID tie breaker would invert this order if fractional seconds were discarded.
        try addThread("a-older", events: [message("2026-01-01T00:00:00.123Z")])
        try addThread("z-newer", events: [message("2026-01-01T00:00:00.789Z")])
        let initial = try store().refresh()
        XCTAssertEqual(initial.sessions.map(\.id), ["z-newer", "a-older"])
        let persisted = try String(contentsOf: index.appendingPathComponent("index.json"), encoding: .utf8)
        XCTAssertTrue(persisted.contains("00:00:00.123Z"))
        XCTAssertTrue(persisted.contains("00:00:00.789Z"))
        let reloaded = try store().snapshot()
        XCTAssertEqual(reloaded.filteredSessions().map(\.id), ["z-newer", "a-older"])
        let cachedRefresh = try store().refresh()
        XCTAssertEqual(cachedRefresh.sessions.map(\.id), ["z-newer", "a-older"])
        XCTAssertEqual(
            cachedRefresh.sessions[0].lastAIReplyAt!.timeIntervalSince1970,
            initial.sessions[0].lastAIReplyAt!.timeIntervalSince1970, accuracy: 0.001)
    }

    func testSharedJSONFractionalRoundTripAndLegacyWholeSecondCompatibility() throws {
        struct Value: Codable { var date: Date }
        let original = Value(date: date("2026-01-01T00:00:00Z").addingTimeInterval(0.123))
        let encoded = try HuantaiJSON.encoder().encode(original)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("00:00:00.123Z"))
        let decoded = try HuantaiJSON.decoder().decode(Value.self, from: encoded)
        XCTAssertEqual(
            decoded.date.timeIntervalSince1970, original.date.timeIntervalSince1970, accuracy: 0.001)
        let legacy = try HuantaiJSON.decoder().decode(
            Value.self,
            from: Data("{\"date\":\"2026-01-01T00:00:00Z\"}".utf8))
        XCTAssertEqual(legacy.date, date("2026-01-01T00:00:00Z"))
    }

    func testUnknownSourceHasNoGuessedURLAndConfiguredMappingPersists() throws {
        try addThread("one", source: "new-source")
        let snapshot = try store().refresh()
        XCTAssertEqual(snapshot.sessions.first?.source, "new-source")
        XCTAssertNil(snapshot.sessions.first?.openURL)
        XCTAssertThrowsError(try store().setOpenMapping(id: "one", url: "javascript:alert(1)"))
        XCTAssertThrowsError(
            try store().setOpenMapping(
                id: "one",
                url: "https://user:password@applink.feishu.cn/client/chat/open?openChatId=oc_synthetic"))
        try store().setOpenMapping(
            id: "one", url: "https://applink.feishu.cn/client/chat/open?openChatId=oc_synthetic")
        XCTAssertEqual(
            try store().snapshot().sessions.first?.openURL,
            "lark://applink.feishu.cn/client/chat/open?openChatId=oc_synthetic")
    }

    func testBotmuxVerifiedChatMappingDoesNotReplaceThreadWithChatOrCodex() throws {
        let ids = [
            "01234567-89ab-cdef-0123-456789abcde1", "01234567-89ab-cdef-0123-456789abcde2",
            "01234567-89ab-cdef-0123-456789abcde3",
        ]
        for id in ids { try addThread(id) }
        try makeDatabase(
            botmux.appendingPathComponent("synthetic/sessions.db"),
            statements: [
                "CREATE TABLE sessions (row TEXT)",
                "INSERT INTO sessions VALUES ('{\"cliSessionId\":\"\(ids[0])\",\"scope\":\"chat\",\"chatId\":\"oc_fixture\",\"lastUserPrompt\":\"SYNTHETIC_PRIVATE_BODY\"}')",
                "INSERT INTO sessions VALUES ('{\"cliSessionId\":\"\(ids[1])\",\"scope\":\"thread\",\"chatId\":\"oc_fixture\",\"rootMessageId\":\"om_fixture\"}')",
                "INSERT INTO sessions VALUES ('{\"cliSessionId\":\"\(ids[2])\",\"scope\":\"chat\",\"chatId\":\"headless_fixture\"}')",
            ])
        let snapshot = try store().refresh()
        let chat = try XCTUnwrap(snapshot.sessions.first { $0.id == ids[0] })
        XCTAssertEqual(chat.openURL, "lark://applink.feishu.cn/client/chat/open?openChatId=oc_fixture")
        XCTAssertEqual(try store().snapshot().sessions.first { $0.id == ids[0] }?.openURL, chat.openURL)
        XCTAssertNil(snapshot.sessions.first { $0.id == ids[1] }?.openURL)
        XCTAssertTrue(
            snapshot.sessions.first { $0.id == ids[1] }?.openUnavailableReason?.contains("话题") == true)
        XCTAssertNil(snapshot.sessions.first { $0.id == ids[2] }?.openURL)
        XCTAssertNil(
            SessionStore.validatedOpenURL("https://applink.feishu.cn/client/chat/open?chatId=oc_fixture"))
        XCTAssertNil(SourceOpening.feishuChatURL(chatID: "oc_fixture&prompt=bad"))
        let data = try String(contentsOf: index.appendingPathComponent("index.json"), encoding: .utf8)
        XCTAssertFalse(data.contains("SYNTHETIC_PRIVATE_BODY"))
        XCTAssertFalse(data.contains("om_fixture"))
    }

    func testFeishuNativeRouteNormalizesOldWebMappingsAndRejectsOtherActions() {
        let expected = "lark://applink.feishu.cn/client/chat/open?openChatId=oc_fixture"
        for scheme in ["https", "lark", "x-feishu"] {
            XCTAssertEqual(
                SessionStore.validatedOpenURL(
                    "\(scheme)://applink.feishu.cn/client/chat/open?openChatId=oc_fixture"),
                expected)
        }
        for value in [
            expected + "&rootMessageId=om_fixture", expected + "#fragment",
            "lark://user:password@applink.feishu.cn/client/chat/open?openChatId=oc_fixture",
            "lark://applink.feishu.cn:123/client/chat/open?openChatId=oc_fixture",
            "lark://other.feishu.cn/client/chat/open?openChatId=oc_fixture",
            "lark://applink.feishu.cn/client/chat/create?openChatId=oc_fixture",
            "https://example.com/", "lark://applink.feishu.cn/client/chat/open?openChatId=om_fixture",
        ] { XCTAssertNil(SessionStore.validatedOpenURL(value)) }
    }

    func testBotmuxPreciseThreadUsesLarkThreadIDAndTracksMetadataChanges() throws {
        let ids = (1...4).map { "01234567-89ab-cdef-0123-456789abcdf\($0)" }
        for id in ids { try addThread(id) }
        let database = botmux.appendingPathComponent("synthetic/sessions.db")
        try makeDatabase(
            database,
            statements: [
                "CREATE TABLE sessions (row TEXT)",
                "INSERT INTO sessions VALUES ('{\"cliSessionId\":\"\(ids[0])\",\"scope\":\"thread\",\"chatId\":\"oc_fixture\",\"larkThreadId\":\"omt_fixture-1\",\"rootMessageId\":\"om_private\",\"lastUserPrompt\":\"PRIVATE_BODY\"}')",
                "INSERT INTO sessions VALUES ('{\"cliSessionId\":\"\(ids[1])\",\"scope\":\"thread\",\"chatId\":\"oc_fixture\",\"larkThreadId\":\"om_wrongtype\"}')",
                "INSERT INTO sessions VALUES ('{\"cliSessionId\":\"\(ids[2])\",\"scope\":\"thread\",\"chatId\":\"headless_fixture\",\"larkThreadId\":\"omt_fixture\"}')",
                "INSERT INTO sessions VALUES ('{\"cliSessionId\":\"\(ids[3])\",\"scope\":\"chat\",\"chatId\":\"oc_fixture\",\"larkThreadId\":\"omt_unused\"}')",
            ])
        let reader = store()
        let snapshot = try reader.refresh()
        let thread = try XCTUnwrap(snapshot.sessions.first { $0.id == ids[0] })
        XCTAssertEqual(
            thread.openURL,
            "lark://applink.feishu.cn/client/thread/open?open_chat_id=oc_fixture&open_thread_id=omt_fixture-1&openchatid=oc_fixture&openthreadid=omt_fixture-1&thread_position=-1"
        )
        XCTAssertEqual(thread.source, "Botmux")
        XCTAssertNil(thread.openUnavailableReason)
        XCTAssertEqual(try store().snapshot().sessions.first { $0.id == ids[0] }?.openURL, thread.openURL)
        XCTAssertNil(snapshot.sessions.first { $0.id == ids[1] }?.openURL)
        XCTAssertTrue(
            snapshot.sessions.first { $0.id == ids[1] }?.openUnavailableReason?.contains("omt_") == true)
        XCTAssertNil(snapshot.sessions.first { $0.id == ids[2] }?.openURL)
        XCTAssertEqual(
            snapshot.sessions.first { $0.id == ids[3] }?.openURL,
            "lark://applink.feishu.cn/client/chat/open?openChatId=oc_fixture")
        let persisted = try String(contentsOf: index.appendingPathComponent("index.json"), encoding: .utf8)
        XCTAssertFalse(persisted.contains("om_private"))
        XCTAssertFalse(persisted.contains("PRIVATE_BODY"))
        try makeDatabase(
            database,
            statements: [
                "UPDATE sessions SET row = json_set(row, '$.larkThreadId', 'omt_updated') WHERE json_extract(row, '$.cliSessionId') = '\(ids[0])'"
            ])
        XCTAssertEqual(
            try reader.refresh().sessions.first { $0.id == ids[0] }?.openURL,
            SourceOpening.feishuThreadURL(chatID: "oc_fixture", threadID: "omt_updated"))
    }

    func testFeishuThreadRouteNormalizesBotmuxLinksAndRejectsConflictingTargets() throws {
        let expected = try XCTUnwrap(
            SourceOpening.feishuThreadURL(chatID: "oc_fixture", threadID: "omt_fixture-1"))
        for scheme in ["https", "lark", "x-feishu"] {
            XCTAssertEqual(
                SessionStore.validatedOpenURL(expected.replacingOccurrences(of: "lark:", with: scheme + ":")),
                expected)
        }
        for value in [
            expected + "&open_thread_id=omt_other", expected + "&prompt=send", expected + "#fragment",
            expected.replacingOccurrences(of: "openchatid=oc_fixture", with: "openchatid=oc_other"),
            expected.replacingOccurrences(of: "openthreadid=omt_fixture-1", with: "openthreadid=omt_other"),
            expected.replacingOccurrences(of: "omt_fixture-1", with: "om_wrongtype"),
            expected.replacingOccurrences(of: "&thread_position=-1", with: ""),
            expected.replacingOccurrences(of: "thread_position=-1", with: "thread_position=0"),
            expected.replacingOccurrences(
                of: "&openthreadid=omt_fixture-1", with: "&open_thread_id=omt_fixture-1"),
            expected.replacingOccurrences(of: "oc_fixture", with: "oc_fixture%26prompt%3Dbad"),
            expected.replacingOccurrences(of: "applink.feishu.cn", with: "other.feishu.cn"),
            expected.replacingOccurrences(of: "//applink", with: "//user:password@applink"),
            expected.replacingOccurrences(of: "feishu.cn/", with: "feishu.cn:123/"),
        ] { XCTAssertNil(SessionStore.validatedOpenURL(value), value) }
        XCTAssertNil(SourceOpening.feishuThreadURL(chatID: "oc_fixture", threadID: "omt_a&bad=1"))
        XCTAssertNil(SourceOpening.feishuThreadURL(chatID: "oc_fixture", threadID: "omt_"))
        XCTAssertNil(
            SourceOpening.feishuThreadURL(
                chatID: "oc_fixture", threadID: "omt_" + String(repeating: "a", count: 128)))
    }

    func testWeeklyResetCountdownTicksAcrossBoundariesAndDoesNotInventMissingReset() {
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        let cases: [(TimeInterval, String)] = [
            (90061, "重置 1天 01:01:01"), (86400, "重置 1天 00:00:00"),
            (86399, "重置 23:59:59"), (3600, "重置 01:00:00"),
            (60, "重置 00:01:00"), (0.1, "重置 00:00:01"),
            (0, "等待额度刷新"), (-1, "等待额度刷新"),
        ]
        for (remaining, expected) in cases {
            XCTAssertEqual(
                UsageResetCountdown.text(resetsAt: reset, now: reset.addingTimeInterval(-remaining)), expected
            )
        }
        XCTAssertEqual(UsageResetCountdown.text(resetsAt: nil), "重置时间未连接")
        XCTAssertEqual(UsageResetCountdown.text(resetsAt: Date(timeIntervalSince1970: .nan)), "重置时间未连接")
    }

    func testCodexRouteUsesOnlyValidUUIDAndPersistsAcrossReaders() throws {
        let id = "01234567-89ab-cdef-0123-456789abcdef"
        try addThread(id)
        let expected = "codex://threads/" + id
        XCTAssertEqual(try store().refresh().sessions.first?.openURL, expected)
        XCTAssertEqual(try store().snapshot().sessions.first?.openURL, expected)
        XCTAssertNil(SourceOpening.codexURL(sessionID: "not-a-thread"))
        XCTAssertNil(SessionStore.validatedOpenURL("codex://threads/not-a-thread"))
        XCTAssertNil(SessionStore.validatedOpenURL(expected + "?prompt=send"))
        XCTAssertNil(SessionStore.validatedOpenURL("codex://other/" + id))
        XCTAssertNil(SessionStore.validatedOpenURL("codex://user:password@threads/" + id))
    }

    func testTemporaryIndexFailurePreservesExplicitlyLabeledCachedSessions() throws {
        try addThread("one")
        _ = try store().refresh()
        try FileManager.default.moveItem(
            at: codex.appendingPathComponent("state_5.sqlite"),
            to: codex.appendingPathComponent("temporarily-unavailable.sqlite"))
        let cached = try store().refresh()
        XCTAssertEqual(cached.sessions.map(\.id), ["one"])
        XCTAssertTrue(cached.sources.first?.status.contains("上次缓存") == true)
    }

    func testTransportWrappersAndLongPromptsNeverBecomeDisplayTitles() throws {
        let rejected = [
            "<botmux_routing>SYNTHETIC_PRIVATE_WRAPPER</botmux_routing>",
            "<session_id>SYNTHETIC_PRIVATE_WRAPPER</session_id>",
            "<user_message>SYNTHETIC_PRIVATE_WRAPPER</user_message>",
            "<codex_delegation>SYNTHETIC_PRIVATE_WRAPPER</codex_delegation>",
            "# AGENTS.md instructions SYNTHETIC_PRIVATE_WRAPPER",
            String(repeating: "SYNTHETIC_LONG_PRIVATE_PROMPT ", count: 10),
        ]
        for (position, title) in rejected.enumerated() {
            try addThread("rejected-" + String(position), title: title)
        }
        try addThread("short", title: "  整理地图界面  ")
        let snapshot = try store().refresh()
        for session in snapshot.sessions where session.id.hasPrefix("rejected") {
            XCTAssertEqual(session.title, "未命名会话 · rejected")
        }
        XCTAssertEqual(snapshot.sessions.first { $0.id == "short" }?.title, "整理地图界面")
        let persisted = try String(contentsOf: index.appendingPathComponent("index.json"), encoding: .utf8)
        XCTAssertFalse(persisted.contains("SYNTHETIC_PRIVATE_WRAPPER"))
        XCTAssertFalse(persisted.contains("SYNTHETIC_LONG_PRIVATE_PROMPT"))
    }

    func testCodexDisplayIndexOverridesPromptAndRefreshesRenamesWithoutRolloutChanges() throws {
        try addThread("named", title: String(repeating: "private prompt ", count: 30))
        try addThread("fallback", title: "数据库短标题")
        let titles = codex.appendingPathComponent("session_index.jsonl")
        let initial = """
            {"id":"named","thread_name":"正式会话标题"}
            {"id":"fallback","thread_name":"<instructions>private</instructions>"}
            malformed

            """
        try Data(initial.utf8).write(to: titles)
        let reader = store()
        let first = try reader.refresh()
        XCTAssertEqual(first.sessions.first { $0.id == "named" }?.title, "正式会话标题")
        XCTAssertEqual(first.sessions.first { $0.id == "fallback" }?.title, "数据库短标题")
        let appended =
            initial + """
                {"id":"named","thread_name":"重命名后的标题"}
                {"id":"named","thread_name":
                """
        try Data(appended.utf8).write(to: titles)
        XCTAssertEqual(
            try reader.refresh().sessions.first { $0.id == "named" }?.title, "重命名后的标题")
        let persisted = try String(contentsOf: index.appendingPathComponent("index.json"), encoding: .utf8)
        XCTAssertFalse(persisted.contains("private prompt"))
    }

    func testCodexTitleIndexDoesNotFollowSymlinks() throws {
        try addThread("named", title: "本地短标题")
        let outside = root.appendingPathComponent("outside.jsonl")
        try Data(#"{"id":"named","thread_name":"外部标题"}"#.appending("\n").utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: codex.appendingPathComponent("session_index.jsonl"), withDestinationURL: outside)
        XCTAssertEqual(try store().refresh().sessions.first?.title, "本地短标题")
    }

    func testBotmuxPrefersShortTitleAndFallsBackToNativeTitleWithoutPromptFields() throws {
        try addThread("one", title: "<user_message>SYNTHETIC_PRIVATE_WRAPPER</user_message>")
        try addThread("two", title: String(repeating: "SYNTHETIC_LONG_PRIVATE_PROMPT ", count: 10))
        try addThread("three", title: "原生短标题")
        try makeDatabase(
            botmux.appendingPathComponent("cli-test/sessions.db"),
            statements: [
                "CREATE TABLE sessions(session_id TEXT,row TEXT)",
                "INSERT INTO sessions VALUES('a', '{\"cliSessionId\":\"one\",\"title\":\"飞书短标题\",\"nativeSessionTitle\":\"另一短标题\",\"lastUserPrompt\":\"SYNTHETIC_PRIVATE_WRAPPER\"}')",
                "INSERT INTO sessions VALUES('b', '{\"cliSessionId\":\"two\",\"title\":\"<botmux_route>SYNTHETIC_PRIVATE_WRAPPER</botmux_route>\",\"nativeSessionTitle\":\"原生恢复标题\"}')",
                "INSERT INTO sessions VALUES('c', '{\"cliSessionId\":\"three\",\"title\":\"<user_message>SYNTHETIC_PRIVATE_WRAPPER</user_message>\",\"nativeSessionTitle\":\"<session_id>SYNTHETIC_PRIVATE_WRAPPER</session_id>\"}')",
            ])
        let snapshot = try store().refresh()
        XCTAssertEqual(snapshot.sessions.first { $0.id == "one" }?.title, "飞书短标题")
        XCTAssertEqual(snapshot.sessions.first { $0.id == "two" }?.title, "原生恢复标题")
        XCTAssertEqual(snapshot.sessions.first { $0.id == "three" }?.title, "原生短标题")
        let persisted = try String(contentsOf: index.appendingPathComponent("index.json"), encoding: .utf8)
        XCTAssertFalse(persisted.contains("SYNTHETIC_PRIVATE_WRAPPER"))
        XCTAssertFalse(persisted.contains("SYNTHETIC_LONG_PRIVATE_PROMPT"))
    }

    func testSnapshotSanitizesAndRewritesLegacyWrappedTitles() throws {
        try addThread("legacy")
        var snapshot = try store().refresh()
        snapshot.sessions[0].title = "<user_message>SYNTHETIC_LEGACY_PRIVATE_PROMPT</user_message>"
        try HuantaiJSON.encoder().encode(snapshot).write(to: index.appendingPathComponent("index.json"))
        let restored = try store().snapshot()
        XCTAssertEqual(restored.sessions[0].title, "未命名会话 · legacy")
        let persisted = try String(contentsOf: index.appendingPathComponent("index.json"), encoding: .utf8)
        XCTAssertFalse(persisted.contains("SYNTHETIC_LEGACY_PRIVATE_PROMPT"))
    }

    func testStructuredSourceLabelsDoNotPersistInternalIdentifiers() throws {
        try addThread(
            "child",
            source: "{\"subagent\":{\"thread_spawn\":{\"parent_thread_id\":\"SYNTHETIC_INTERNAL_PARENT\"}}}")
        try addThread("other", source: "{\"other\":{\"parent_thread_id\":\"SYNTHETIC_INTERNAL_PARENT\"}}")
        try addThread("plain", source: String(repeating: "未知", count: 30))
        let snapshot = try store().refresh()
        XCTAssertEqual(snapshot.sessions.first { $0.id == "child" }?.source, "Codex 子会话")
        XCTAssertEqual(snapshot.sessions.first { $0.id == "other" }?.source, "其他来源")
        XCTAssertEqual(snapshot.sessions.first { $0.id == "plain" }?.source.count, 32)
        let persisted = try String(contentsOf: index.appendingPathComponent("index.json"), encoding: .utf8)
        XCTAssertFalse(persisted.contains("SYNTHETIC_INTERNAL_PARENT"))
        XCTAssertFalse(persisted.contains("thread_spawn"))
    }

    func testBotmuxJoinsNativeIDOnlyAndDoesNotUseDispatchTimestamp() throws {
        try addThread("one", events: [message("2026-01-01T00:00:00Z")])
        try makeDatabase(
            botmux.appendingPathComponent("cli-test/sessions.db"),
            statements: [
                "CREATE TABLE sessions(session_id TEXT,row TEXT)",
                "INSERT INTO sessions VALUES('bot', '{\"cliSessionId\":\"one\",\"lastMessageAt\":9999999999,\"lastUserPrompt\":\"SYNTHETIC_BODY\"}')",
            ])
        let snapshot = try store().refresh()
        XCTAssertEqual(snapshot.sessions.count, 1)
        XCTAssertEqual(snapshot.sessions.first?.id, "one")
        XCTAssertEqual(snapshot.sessions.first?.source, "Botmux")
        XCTAssertEqual(snapshot.sessions.first?.lastAIReplyAt, date("2026-01-01T00:00:00Z"))
        XCTAssertNil(snapshot.sessions.first?.openURL)
    }

    func testUnconfiguredSourceDoesNotConnectAndExplicitRemoteReportsFailure() throws {
        try FileManager.default.removeItem(at: codex.appendingPathComponent("state_5.sqlite"))
        let instance = store()
        instance.remoteScanner = RemoteCodexScanner { _ in throw HuantaiError.sourceUnavailable("测试断线") }
        try instance.setRemoteTarget(RemoteTarget(id: "remote", name: "测试远端", host: "nobody@invalid.example"))
        let snapshot = try instance.refresh()
        XCTAssertTrue(snapshot.sessions.isEmpty)
        XCTAssertTrue(snapshot.sources[0].status.contains("未连接"))
        XCTAssertTrue(snapshot.sources[1].status.contains("未连接"))
        XCTAssertThrowsError(
            try instance.setRemoteTarget(
                RemoteTarget(id: "unsafe", name: "unsafe", host: "host;touch /tmp/unwanted")))
    }

    func testOfficialUsageImportUsesDurationAndUnixSecondsAndNullIsNotZero() throws {
        let payload = Data(
            """
            {"result":{"rateLimits":{"primary":{"usedPercent":99,"windowDurationMins":300,"resetsAt":1791240000},"secondary":null},"rateLimitsByLimitId":{"codex":{"primary":null,"secondary":{"usedPercent":48,"windowDurationMins":10080,"resetsAt":1791240000}}},"rateLimitResetCredits":{"availableCount":"2","credits":[]},"accountId":"SYNTHETIC_ACCOUNT_DO_NOT_PERSIST"}}
            """.utf8)
        let result = try UsageSnapshotImporter.decode(payload, importedAt: date("2026-01-01T00:00:00Z"))
        XCTAssertEqual(result.weekly?.usedPercent, 48)
        XCTAssertEqual(result.weekly?.windowDurationMins, 10080)
        XCTAssertEqual(result.weekly?.resetsAt.timeIntervalSince1970, 1_791_240_000)
        XCTAssertEqual(result.resetCount, 2)
        XCTAssertThrowsError(
            try UsageSnapshotImporter.decode(
                Data(
                    "{\"rateLimits\":{\"primary\":null,\"secondary\":null},\"rateLimitResetCredits\":null}"
                        .utf8)))
        let unknown = UsageSummary()
        XCTAssertNil(unknown.weekly)
        XCTAssertNil(unknown.resetCount)
    }

    func testBudgetAndForecastHaveDefinedUnitsAndStaleWindowsNoMarkers() {
        let reset = date("2026-01-08T00:00:00Z")
        let window = UsageWindow(usedPercent: 48, windowDurationMins: 10080, resetsAt: reset)
        let projection = UsageProjection.calculate(window: window, now: date("2026-01-04T00:00:00Z"))
        XCTAssertEqual(projection.referenceBudgetPercent!, 100 * 3 / 7, accuracy: 0.001)
        XCTAssertNil(projection.estimatedEndPercent)
        XCTAssertEqual(projection.greenPercent + projection.overBudgetPercent, 48, accuracy: 0.001)
        XCTAssertGreaterThan(projection.overBudgetPercent, 0)
        XCTAssertNil(UsageProjection.calculate(window: window, now: reset).referenceBudgetPercent)
        XCTAssertNil(UsageProjection.calculate(window: nil).estimatedEndPercent)
        XCTAssertNil(
            UsageProjection.calculate(window: window, now: date("2026-01-01T00:00:00Z")).estimatedEndPercent)
    }
}
