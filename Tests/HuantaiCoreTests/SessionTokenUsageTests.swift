import Foundation
import XCTest

@testable import HuantaiCore

final class SessionTokenUsageTests: XCTestCase {
    static func sample(total: String = "12345", context: String = "4000") -> String {
        """
        {"type":"event_msg","timestamp":"2026-10-10T00:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":\(total)},"last_token_usage":{"input_tokens":\(context)},"model_context_window":10000}}}
        """
    }

    func testLatestCumulativeSampleIsNotSummedAndMalformedTailIsIgnored() throws {
        let data = Data((Self.sample(total: "100") + "\n" + Self.sample() + "\n{partial").utf8)
        let usage = try XCTUnwrap(SessionTokenUsageScanner.decodeTail(data))
        XCTAssertEqual(usage.totalTokens, 12345)
        XCTAssertEqual(usage.contextTokens, 4000)
        XCTAssertEqual(usage.percent, 40)
        XCTAssertEqual(usage.compactTotal, "12.3K")
    }

    func testCompactionInvalidatesContextUntilNextSample() throws {
        for compact in [
            "{\"type\":\"compacted\"}",
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"context_compacted\"}}",
        ] {
            let log = Self.sample() + "\n" + compact
            let usage = try XCTUnwrap(SessionTokenUsageScanner.decodeTail(Data(log.utf8)))
            XCTAssertTrue(usage.compacted)
            XCTAssertEqual(usage.totalTokens, 12345)
            XCTAssertNil(usage.contextTokens)
            XCTAssertEqual(usage.compactContext, "↻")
            let updated = try XCTUnwrap(
                SessionTokenUsageScanner.decodeTail(Data((log + "\n" + Self.sample(context: "200")).utf8)))
            XCTAssertFalse(updated.compacted)
            XCTAssertEqual(updated.contextTokens, 200)
        }
    }

    func testUnknownInvalidAndZeroRemainDistinct() {
        for invalid in ["-1", "true", "1.5", "9007199254740992", "null", "\"4\""] {
            XCTAssertNil(
                SessionTokenUsageScanner.decodeTail(Data(Self.sample(total: invalid, context: invalid).utf8)))
        }
        XCTAssertEqual(
            SessionTokenUsageScanner.decodeTail(Data(Self.sample(total: "0", context: "0").utf8))?
                .totalTokens, 0)
        XCTAssertNil(SessionTokenUsageScanner.decodeTail(Data()))
    }

    func testFileCacheRefreshesAfterAppendAndTruncation() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let scanner = SessionTokenUsageScanner()
        try Data(Self.sample().utf8).write(to: file)
        XCTAssertEqual(scanner.scan(file)?.totalTokens, 12345)
        XCTAssertEqual(scanner.scan(file)?.totalTokens, 12345)
        try Data((Self.sample() + "\n" + Self.sample(total: "20000")).utf8).write(to: file)
        XCTAssertEqual(scanner.scan(file)?.totalTokens, 20000)
        try Data("{}".utf8).write(to: file)
        XCTAssertNil(scanner.scan(file))
    }
}
