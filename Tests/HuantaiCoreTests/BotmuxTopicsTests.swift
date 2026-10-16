import Foundation
import XCTest
@testable import HuantaiCore

final class BotmuxTopicsTests: XCTestCase {
    func testOnlyRequestedValidIDsAreCached() throws {
        let data = Data(#"{"data":{"messages":[{"message_id":"om_root","thread_id":"omt_topic","body":"PRIVATE"},{"message_id":"om_other","thread_id":"omt_other"},{"message_id":"om_bad","thread_id":"om_not_topic"}]}}"#.utf8)
        XCTAssertEqual(BotmuxTopics.parse(data, requested: ["om_root", "om_bad"]), ["om_root": "omt_topic"])
    }

    func testLookupEnrichesBothLocalAndRemoteRoutesAndPersistsOnlyIDs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let topics = BotmuxTopics(directory: directory) { roots in
            XCTAssertEqual(roots, ["om_root"])
            return Data(#"{"data":{"messages":[{"message_id":"om_root","thread_id":"omt_topic","body":"PRIVATE_BODY"}]}}"#.utf8)
        }
        XCTAssertNil(topics.topic(root: "om_root"))
        let deadline = Date().addingTimeInterval(3)
        let file = directory.appendingPathComponent("botmux-topics.json")
        while !FileManager.default.fileExists(atPath: file.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertEqual(topics.topic(root: "om_root"), "omt_topic")
        let cache = try Data(contentsOf: file)
        XCTAssertFalse(String(decoding: cache, as: UTF8.self).contains("PRIVATE_BODY"))
        let restored = BotmuxTopics(directory: directory) { _ in XCTFail("cache should avoid lookup"); return Data() }
        let route = RemoteBotmuxRoute(scope: "thread", chatId: "oc_fixture", rootMessageId: "om_root")
        XCTAssertEqual(route.openingURL(topics: restored), SourceOpening.feishuThreadURL(chatID: "oc_fixture", threadID: "omt_topic"))
        XCTAssertEqual(SourceOpening.feishuThreadURL(chatID: "oc_fixture", threadID: restored.topic(root: "om_root")!), route.openingURL(topics: restored))
        let explicit = RemoteBotmuxRoute(scope: "thread", chatId: "oc_fixture", larkThreadId: "omt_original", rootMessageId: "om_root")
        XCTAssertTrue(explicit.openingURL(topics: restored)!.contains("omt_original"))
        XCTAssertEqual(RemoteBotmuxRoute(scope: "chat", chatId: "oc_fixture", rootMessageId: "om_root").openingURL(topics: restored), SourceOpening.feishuChatURL(chatID: "oc_fixture"))
    }

    func testInvalidRootsAndLookupFailureDoNotCreateCache() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let called = expectation(description: "one lookup despite repeated requests")
        called.assertForOverFulfill = true
        let topics = BotmuxTopics(directory: directory) { _ in called.fulfill(); throw CocoaError(.fileReadUnknown) }
        XCTAssertNil(topics.topic(root: "../../private"))
        for _ in 0..<10 { XCTAssertNil(topics.topic(root: "om_root")) }
        wait(for: [called], timeout: 2)
        XCTAssertNil(topics.topic(root: "om_root"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("botmux-topics.json").path))
    }
}
