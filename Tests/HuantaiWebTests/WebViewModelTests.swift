import JavaScriptCore
import XCTest

@testable import HuantaiWeb

final class WebViewModelTests: XCTestCase {
    func testNativeThreadRoutePreservesExactTargetAndRejectsAmbiguousLinks() throws {
        let expected =
            "lark://applink.feishu.cn/client/thread/open?open_chat_id=oc_fixture&open_thread_id=omt_fixture-1&openchatid=oc_fixture&openthreadid=omt_fixture-1&thread_position=-1"
        var inputs: [String] = []
        var outputs: [String?] = []
        for scheme in ["https", "lark", "x-feishu"] {
            inputs.append(expected.replacingOccurrences(of: "lark:", with: scheme + ":"))
            outputs.append(expected)
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
        ] {
            inputs.append(value)
            outputs.append(nil)
        }
        let chat = "lark://applink.feishu.cn/client/chat/open?openChatId=oc_fixture"
        inputs.append(chat)
        outputs.append(chat)
        // JavaScriptCore has no browser URL API. Use an installed Node runtime's actual URL parser.
        guard
            let node = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"].first(where: {
                FileManager.default.isExecutableFile(atPath: $0)
            })
        else { throw XCTSkip("URL integration check needs an existing Node runtime; no installation") }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [
            "-e",
            WebAssets.modelJavascript
                + "\nconst input=JSON.parse(require('fs').readFileSync(0,'utf8'));process.stdout.write(JSON.stringify(input.map(HuantaiViewModel.validatedOpenURL)));",
        ]
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(inputs))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try JSONDecoder().decode([String?].self, from: data), outputs)
    }

    private func context() throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(WebAssets.modelJavascript)
        XCTAssertNil(context.exception)
        return context
    }

    private func call(_ name: String, in context: JSContext, arguments: [Any]) throws -> JSValue {
        let model = try XCTUnwrap(context.objectForKeyedSubscript("HuantaiViewModel"))
        let function = try XCTUnwrap(model.objectForKeyedSubscript(name))
        let result = try XCTUnwrap(function.call(withArguments: arguments))
        XCTAssertNil(context.exception)
        return result
    }

    private let fixtures: [[String: Any]] = [
        [
            "id": "a-early", "title": "修复菜单栏", "cwd": "/fixture/huantai", "source": "Botmux",
            "machine": "已配置远端", "lastAIReplyAt": "2026-10-05T12:00:00.123Z", "isFavorite": true,
        ],
        [
            "id": "z-late", "title": "整理 CLI", "cwd": "/fixture/cli", "source": "Codex",
            "machine": "本机", "lastAIReplyAt": "2026-10-05T12:00:00.789Z", "isFavorite": false,
        ],
        [
            "id": "no-reply", "title": "等待任务", "cwd": "/fixture/huantai", "source": "Codex",
            "machine": "已配置远端", "isFavorite": false,
        ],
    ]

    func testWeeklyResetCountdownTicksAndKeepsUnknownAndExpiredStatesExplicit() throws {
        let js = try context()
        let reset = "2026-10-08T12:00:00.000Z"
        let resetMilliseconds: Double = 1_791_460_800_000
        for (remaining, expected) in [
            (90061.0, "重置 1天 01:01:01"), (86400, "重置 1天 00:00:00"),
            (86399, "重置 23:59:59"), (0.1, "重置 00:00:01"),
            (0, "等待额度刷新"), (-1, "等待额度刷新"),
        ] {
            XCTAssertEqual(
                try call("resetCountdown", in: js, arguments: [reset, resetMilliseconds - remaining * 1000])
                    .toString(), expected)
        }
        XCTAssertEqual(try call("resetCountdown", in: js, arguments: [NSNull()]).toString(), "重置时间未连接")
        XCTAssertEqual(try call("resetCountdown", in: js, arguments: ["invalid-date"]).toString(), "重置时间未连接")
    }

    func testSourceMachineFavoriteAndQueryFiltersCombineWithoutMutatingIndex() throws {
        let js = try context()
        let filtered = try call(
            "filterSessions", in: js,
            arguments: [
                fixtures,
                [
                    "source": "Botmux", "machine": "已配置远端",
                    "favoritesOnly": true, "query": " HUANTAI ",
                ],
            ])
        let records = try XCTUnwrap(filtered.toArray() as? [[String: Any]])
        XCTAssertEqual(records.compactMap { $0["id"] as? String }, ["a-early"])
        let empty = try call(
            "filterSessions", in: js,
            arguments: [fixtures, ["source": "Botmux", "machine": "本机"]])
        XCTAssertTrue(try XCTUnwrap(empty.toArray()).isEmpty)
        XCTAssertEqual(fixtures.first?["id"] as? String, "a-early")
    }

    func testRecentAndFavoritePriorityKeepMillisecondOrderingAndMissingRepliesLast() throws {
        let js = try context()
        let recent = try call("filterSessions", in: js, arguments: [fixtures, ["sort": "recent"]])
        XCTAssertEqual(
            try XCTUnwrap(recent.toArray() as? [[String: Any]]).compactMap { $0["id"] as? String },
            ["z-late", "a-early", "no-reply"])
        let favorite = try call("filterSessions", in: js, arguments: [fixtures, ["sort": "favorite"]])
        XCTAssertEqual(
            try XCTUnwrap(favorite.toArray() as? [[String: Any]]).compactMap { $0["id"] as? String },
            ["a-early", "z-late", "no-reply"])
        let timestamp = try call("fullTimestamp", in: js, arguments: ["2026-10-05T12:00:00.789Z"])
        XCTAssertTrue(timestamp.toString().contains("2026-10-05T12:00:00.789Z"))
        XCTAssertEqual(try call("fullTimestamp", in: js, arguments: ["invalid-date"]).toString(), "暂无数据")
    }

    func testCompletedTasksAreHiddenByDefaultAndCanBeViewedAndRestoredIndependentlyOfFavorites() throws {
        let js = try context()
        var records = fixtures
        records[0]["isCompleted"] = true
        func ids(_ options: [String: Any]) throws -> [String] {
            try XCTUnwrap(
                call("filterSessions", in: js, arguments: [records, options]).toArray() as? [[String: Any]]
            )
            .compactMap { $0["id"] as? String }
        }
        XCTAssertEqual(try ids([:]), ["z-late", "no-reply"])
        XCTAssertTrue(try ids(["favoritesOnly": true]).isEmpty)
        XCTAssertEqual(try ids(["status": "completed", "favoritesOnly": true]), ["a-early"])
        XCTAssertEqual(try ids(["status": "all"]), ["z-late", "a-early", "no-reply"])
        records[0]["isCompleted"] = false
        XCTAssertEqual(try ids(["favoritesOnly": true]), ["a-early"])
    }

    func testFilterOptionsUseOnlyIndexedMetadataAndDeduplicate() throws {
        let js = try context()
        let values = try call("availableValues", in: js, arguments: [fixtures, "source"])
        XCTAssertEqual(Set(try XCTUnwrap(values.toArray() as? [String])), ["Codex", "Botmux"])
        let unknown = try call("availableValues", in: js, arguments: [[[String: Any]()], "machine"])
        XCTAssertEqual(unknown.toArray() as? [String], ["未知设备"])
    }

    func testUsageStatusKeepsOfflineSnapshotDistinctFromAccountAndCardConnection() throws {
        let js = try context()
        let disconnected = try call("usageConnectionRows", in: js, arguments: [[String: Any]()])
        let missing = try XCTUnwrap(disconnected.toArray() as? [[String]])
        XCTAssertTrue(missing.contains(["周用量来源", "未连接周用量来源"]))
        XCTAssertTrue(missing.contains(["窗口重置点", "未连接"]))
        let value: [String: Any] = [
            "weekly": [
                "usedPercent": 48, "windowDurationMins": 10080,
                "resetsAt": "2026-10-08T12:00:00.000Z",
            ],
            "resetCount": 2, "observedAt": "2026-10-05T12:00:00.123Z",
            "status": "离线快照（导入时间，非实时）",
        ]
        let imported = try call("usageConnectionRows", in: js, arguments: [value])
        let rows = Dictionary(
            uniqueKeysWithValues: try XCTUnwrap(imported.toArray() as? [[String]]).map { ($0[0], $0[1]) })
        XCTAssertEqual(rows["周用量来源"], "离线快照（导入时间，非实时）")
        XCTAssertTrue(try XCTUnwrap(rows["窗口重置点"]).contains("2026-10-08T12:00:00.000Z"))
        XCTAssertTrue(try XCTUnwrap(rows["快照导入时间"]).contains("2026-10-05T12:00:00.123Z"))
        XCTAssertEqual(rows["账户接口"], "未连接")
        XCTAssertEqual(rows["重置卡有效期"], "明细未提供")
    }

    func testLiveAccountRowsIdentifyReadTimeAndKeepCardsIndependent() throws {
        let js = try context()
        let result = try call(
            "usageConnectionRows", in: js,
            arguments: [
                [
                    "source": "codex-app-server", "status": "Codex app-server 实时读取",
                    "observedAt": "2026-10-05T12:00:00.123Z", "resetCount": 2,
                ]
            ])
        let rows = Dictionary(
            uniqueKeysWithValues: try XCTUnwrap(result.toArray() as? [[String]]).map { ($0[0], $0[1]) })
        XCTAssertEqual(rows["账户接口"], "Codex app-server（现有授权，只读）")
        XCTAssertTrue(try XCTUnwrap(rows["额度读取时间"]).contains("定时读取"))
        XCTAssertEqual(rows["可用重置次数"], "2 次（账户接口）")
        XCTAssertEqual(rows["重置卡有效期"], "明细未提供")
    }

    func testResetDateAndCardRowsKeepMissingMetadataAndCountIndependent() throws {
        let js = try context()
        XCTAssertEqual(
            try call("resetDate", in: js, arguments: ["2026-10-09T12:30:00"]).toString(), "10-9(周五)重置")
        XCTAssertEqual(try call("resetDate", in: js, arguments: [NSNull()]).toString(), "重置时间未连接")
        let usage: [String: Any] = [
            "resetCount": 5,
            "resetCredits": [
                ["expirationKnown": true, "expiresAt": "2026-10-09T12:30:45"],
                ["expirationKnown": true, "expiresAt": NSNull()],
                ["expirationKnown": false],
            ],
        ]
        XCTAssertEqual(
            try call("resetCreditRows", in: js, arguments: [usage]).toArray() as? [String],
            [
                "重置卡 5 张", "第1张 · 2026-10-09 12:30到期", "第2张 · 不过期", "第3张 · 有效期未知",
                "另有 2 张，明细暂未返回",
            ])
        XCTAssertEqual(
            try call("resetCreditRows", in: js, arguments: [["resetCount": 0]]).toArray() as? [String],
            ["重置卡 0 张"])
        XCTAssertEqual(
            try call("resetCreditRows", in: js, arguments: [["resetCount": 2]]).toArray() as? [String],
            ["重置卡 2 张", "有效期暂未返回"])
        XCTAssertEqual(
            try call("resetCreditRows", in: js, arguments: [[String: Any]()]).toArray() as? [String],
            ["重置卡未连接"])
    }
}
