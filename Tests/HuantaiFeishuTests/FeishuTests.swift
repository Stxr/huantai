import Foundation
import HuantaiCore
import XCTest

@testable import HuantaiFeishu

final class FeishuTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)
    private func fixture() throws -> (URL, FeishuBotConfiguration, FeishuBotBinding) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "huantai-feishu-" + UUID().uuidString)
        let config = FeishuBotConfiguration(dataDirectory: root)
        return (root, config, try config.bind(appID: "cli_fixture", secret: "SYNTHETIC_SECRET", now: now))
    }
    private func snapshot() -> IndexSnapshot {
        .init(
            sessions: (0..<12).map { index in
                SessionRecord(
                    id: "fixture-\(index)", title: "会话 \(index)", cwd: "/PRIVATE_CWD", source: "Botmux",
                    machine: "远端",
                    lastAIReplyAt: now.addingTimeInterval(-Double(index) * 86400), isFavorite: index % 2 == 0,
                    openURL: "lark://applink.feishu.cn/client/chat/open?openChatId=oc_fixture")
            },
            usage: .init(
                weekly: .init(
                    usedPercent: 1, windowDurationMins: 10080, resetsAt: now.addingTimeInterval(7 * 86400)),
                resetCount: 3), sources: [], updatedAt: now)
    }
    private func message(
        _ command: String, id: String = "om_test", owner: String = "ou_owner", chat: String = "oc_owner",
        type: String = "p2p"
    ) throws -> Data {
        let content = String(
            decoding: try JSONSerialization.data(withJSONObject: ["text": command]), as: UTF8.self)
        return try JSONSerialization.data(withJSONObject: [
            "header": ["event_type": "im.message.receive_v1", "app_id": "cli_fixture"],
            "event": [
                "sender": ["sender_type": "user", "sender_id": ["open_id": owner]],
                "message": [
                    "message_type": "text", "chat_type": type, "chat_id": chat, "message_id": id,
                    "content": content,
                ],
            ],
        ])
    }
    private func callback(
        binding: FeishuBotBinding, action: String, option: String = "", page: Int = 0,
        owner: String = "ou_owner", chat: String = "oc_owner"
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "header": ["event_type": "card.action.trigger", "app_id": "cli_fixture"],
            "event": [
                "operator": ["open_id": owner],
                "context": ["open_chat_id": chat, "open_message_id": "om_card"],
                "action": [
                    "option": option,
                    "value": [
                        "binding": binding.id, "action": action, "days": 0, "favorites": false,
                        "completed": false, "size": 5, "query": "", "page": page,
                    ],
                ],
            ],
        ])
    }
    private func pair(_ config: FeishuBotConfiguration, _ binding: FeishuBotBinding) throws
        -> FeishuBotBinding
    {
        try XCTUnwrap(
            config.pair(
                id: binding.id, code: binding.pairingCode!, ownerID: "ou_owner", chatID: "oc_owner", now: now)
        )
    }

    func testConfigIsPrivateAndStatusNeverContainsSecret() throws {
        let (root, config, binding) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = try config.binding()
        XCTAssertEqual(saved?.appID, binding.appID)
        XCTAssertEqual(saved?.appSecret, "SYNTHETIC_SECRET")
        let attrs = try FileManager.default.attributesOfItem(
            atPath: config.directory.appendingPathComponent("binding.json").path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let dir = try FileManager.default.attributesOfItem(atPath: config.directory.path)
        XCTAssertEqual((dir[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let status = String(decoding: try JSONEncoder().encode(config.status()), as: UTF8.self)
        XCTAssertFalse(status.contains("SYNTHETIC_SECRET"))
        XCTAssertFalse(status.contains(binding.pairingCode!))
        XCTAssertThrowsError(try config.bind(appID: "invalid", secret: "secret"))
    }

    func testPairingIsExpiringAndUnbindInvalidatesOldCardsAndPendingMessages() throws {
        let (root, config, binding) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(
            try config.pair(id: binding.id, code: "wrong", ownerID: "ou_owner", chatID: "oc_owner", now: now))
        XCTAssertNil(
            try config.pair(
                id: binding.id, code: binding.pairingCode!, ownerID: "ou_owner", chatID: "oc_owner",
                now: now.addingTimeInterval(600)))
        let paired = try pair(config, binding)
        XCTAssertNil(paired.pairingCode)
        let router = FeishuEventRouter(configuration: config)
        _ = try router.handle(message("/status"), snapshot: snapshot(), bindingID: binding.id, now: .now)
        XCTAssertNotNil(try config.pending())
        try config.unbind()
        XCTAssertNil(try config.binding())
        XCTAssertNil(try config.pending())
        XCTAssertNil(
            try router.handle(
                callback(binding: binding, action: "next"), snapshot: snapshot(), bindingID: binding.id))
        XCTAssertFalse(
            try String(contentsOf: config.directory.appendingPathComponent("binding.json")).contains(
                "SYNTHETIC_SECRET"))
    }

    func testOnlyPairedDirectChatCanRequestDashboardAndDuplicateCommandsAreDeduplicated() throws {
        let (root, config, binding) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let router = FeishuEventRouter(configuration: config)
        _ = try router.handle(message("/status"), snapshot: snapshot(), bindingID: binding.id, now: now)
        XCTAssertNil(try config.pending())
        _ = try router.handle(
            message("/bind " + binding.pairingCode!, type: "group"), snapshot: snapshot(),
            bindingID: binding.id, now: now)
        XCTAssertNil(try config.binding()?.ownerID)
        _ = try router.handle(
            message("/bind " + binding.pairingCode!), snapshot: snapshot(), bindingID: binding.id, now: now)
        XCTAssertEqual(try config.binding()?.ownerID, "ou_owner")
        // Pairing card is intentionally old in this fixed-time fixture; pending() expires it.
        XCTAssertNil(try config.pending())
        for event in [
            try message("/status", owner: "ou_other"), try message("/status", chat: "oc_other"),
            try message("/status", type: "group"),
        ] {
            _ = try router.handle(event, snapshot: snapshot(), bindingID: binding.id, now: .now)
        }
        XCTAssertNil(try config.pending())
        let request = try message("/status")
        _ = try router.handle(request, snapshot: snapshot(), bindingID: binding.id, now: .now)
        let item = try XCTUnwrap(config.pending())
        _ = try router.handle(request, snapshot: snapshot(), bindingID: binding.id, now: .now)
        try config.delivered(item.id)
        XCTAssertNil(try config.pending())
        _ = try router.handle(request, snapshot: snapshot(), bindingID: binding.id, now: .now)
        XCTAssertNil(try config.pending())
    }

    func testCallbacksUpdateSameCardFilterPageAndRejectOtherUsers() throws {
        let (root, config, binding) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try pair(config, binding)
        let router = FeishuEventRouter(configuration: config)
        let result = try XCTUnwrap(
            router.handle(
                callback(binding: binding, action: "next"), snapshot: snapshot(), bindingID: binding.id,
                now: now))
        let json = String(
            decoding: try JSONSerialization.data(withJSONObject: result, options: [.withoutEscapingSlashes]),
            as: UTF8.self)
        XCTAssertTrue(json.contains("第 2 / 3 页"))
        XCTAssertFalse(json.contains("PRIVATE_CWD"))
        let filtered = try router.handle(
            callback(binding: binding, action: "days", option: "1"), snapshot: snapshot(),
            bindingID: binding.id, now: now)
        XCTAssertNotNil(filtered?["card"])
        XCTAssertEqual(try config.binding()?.filter.days, 1)
        let denied = try router.handle(
            callback(binding: binding, action: "days", option: "7", owner: "ou_other"), snapshot: snapshot(),
            bindingID: binding.id, now: now)
        XCTAssertNil(denied?["card"])
        XCTAssertEqual(try config.binding()?.filter.days, 1)
        XCTAssertThrowsError(
            try router.handle(
                callback(binding: binding, action: "days", option: "999"), snapshot: snapshot(),
                bindingID: binding.id, now: now))
        _ = try config.renewPairing(now: now)
        XCTAssertNil(
            try router.handle(
                callback(binding: binding, action: "next"), snapshot: snapshot(), bindingID: binding.id,
                now: now))
    }

    func testCardIncludesQuotaAndSafeLinksWithoutCredentialsAndClampsPages() throws {
        let (root, _, binding) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let card = try FeishuDashboardCard.json(
            snapshot: snapshot(), binding: binding, page: Int.max, now: now)
        let text = String(decoding: card, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
        XCTAssertTrue(text.contains("13.3%"))
        XCTAssertTrue(text.contains("第 3 / 3 页"))
        XCTAssertTrue(text.contains("open_url"))
        XCTAssertFalse(text.contains("SYNTHETIC_SECRET"))
        XCTAssertFalse(text.contains("PRIVATE_CWD"))
        XCTAssertLessThan(card.count, 30 * 1024)
        var filter = FeishuDashboardFilter()
        filter.days = 1
        let filtered = String(
            decoding: try FeishuDashboardCard.json(
                snapshot: snapshot(), binding: binding, filter: filter, now: now), as: UTF8.self)
        XCTAssertTrue(filtered.contains("2 个会话"))
        XCTAssertEqual(FeishuDashboardCard.escape("<at id=all>*[a]"), "&lt;at id=all&gt;\\*\\[a\\]")
    }

    func testSingleListenerLockIsReleasedAndFilterChangesDoNotReplaceBinding() throws {
        let (root, config, binding) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try config.acquireListener()
        XCTAssertThrowsError(try FeishuBotConfiguration(dataDirectory: root).acquireListener())
        close(first)
        let second = try config.acquireListener()
        close(second)
        var filter = FeishuDashboardFilter()
        filter.favoritesOnly = true
        try config.setFilter(filter)
        XCTAssertEqual(try config.binding()?.id, binding.id)
        XCTAssertTrue(try XCTUnwrap(config.binding()).filter.favoritesOnly)
    }

    func testProtobufRoundTripPreservesAcknowledgmentRoutingAndUnknownFields() throws {
        let frame = FeishuFrame(
            sequence: UInt64.max, logID: 129, service: 17, method: 1,
            headers: ["type": "event", "message_id": "m", "trace_id": "t", "instance_id": "i"],
            payload: Data("{}".utf8), logIDNew: "new")
        XCTAssertEqual(try FeishuFrame.decode(frame.encoded()), frame)
        // Unknown fixed-width field 10 is skipped, preserving forward compatibility.
        var withUnknown = frame.encoded()
        withUnknown.append(contentsOf: [0x55, 0, 0, 0, 0])
        XCTAssertEqual(try FeishuFrame.decode(withUnknown), frame)
        for malformed in [Data([0x80]), Data([0x42, 0x7f, 0]), Data(repeating: 0xff, count: 12), Data([0])] {
            XCTAssertThrowsError(try FeishuFrame.decode(malformed))
        }
    }

    func testFragmentAssemblyHandlesReorderingDuplicatesExpiryAndLimits() throws {
        var assembler = FeishuFrameAssembler()
        let second = FeishuFrame(
            method: 1, headers: ["sum": "2", "seq": "1", "message_id": "m"], payload: Data("B".utf8))
        let first = FeishuFrame(
            method: 1, headers: ["sum": "2", "seq": "0", "message_id": "m"], payload: Data("A".utf8))
        XCTAssertNil(try assembler.receive(second, now: now))
        XCTAssertNil(try assembler.receive(second, now: now))
        XCTAssertEqual(try assembler.receive(first, now: now), Data("AB".utf8))
        XCTAssertNil(try assembler.receive(first, now: now))
        XCTAssertNil(try assembler.receive(second, now: now.addingTimeInterval(31)))
        var bad = first
        bad.headers["sum"] = "100000"
        XCTAssertThrowsError(try assembler.receive(bad))
    }
}
