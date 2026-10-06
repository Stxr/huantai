import Foundation
import XCTest

@testable import HuantaiCore

final class CodexRateLimitsClientTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "huantai-rate-client-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    /// A synthetic child speaks just the documented stdio handshake. It never invokes Codex.
    private func executable(response: String, delay: Bool = false, excludeDetails: Bool = false) throws -> URL
    {
        let url = root.appendingPathComponent("synthetic-app-server")
        let script = """
            #!/bin/sh
            IFS= read -r initialize
            case "$initialize" in
              *'"method":"initialize"'*'"explicitGatewayOauth":true'*) ;;
              *) printf '%s\\n' '{"id":1,"error":{"code":-999,"message":"SYNTHETIC_BAD_HANDSHAKE"}}'; exit 1 ;;
            esac
            printf '%s\\n' '{"id":1,"result":{"userAgent":"synthetic","codexHome":"SYNTHETIC_HOME_MUST_NOT_PERSIST"}}'
            IFS= read -r initialized
            case "$initialized" in
              *'"method":"initialized"'*) ;;
              *) exit 1 ;;
            esac
            IFS= read -r usage
            case "$usage" in
              *'"method":"account/rateLimits/read"'*'"excludeResetCreditDetails":\(excludeDetails)'*|*'"method":"account\\/rateLimits\\/read"'*'"excludeResetCreditDetails":\(excludeDetails)'*) ;;
              *) printf '%s\\n' '{"id":2,"error":{"code":-999,"message":"SYNTHETIC_BAD_READ"}}'; exit 1 ;;
            esac
            \(delay ? "exec /bin/sleep 2" : "printf '%s\\n' '" + response + "'")
            """
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    func testDocumentedHandshakeReadsWeeklyCountAndIgnoresPrivateCreditFields() throws {
        let response = """
            {"id":2,"result":{"rateLimits":{"primary":{"usedPercent":99,"windowDurationMins":300,"resetsAt":1791240000},"secondary":null},"rateLimitsByLimitId":{"codex":{"primary":null,"secondary":{"usedPercent":48,"windowDurationMins":10080,"resetsAt":1791240000}}},"rateLimitResetCredits":{"availableCount":"2","credits":[{"id":"SYNTHETIC_CREDIT_MUST_NOT_PERSIST"}]},"accountId":"SYNTHETIC_ACCOUNT_MUST_NOT_PERSIST","rateLimitUpsell":{"body":"SYNTHETIC_BANNER_MUST_NOT_PERSIST"}}}
            """
        let summary = try CodexRateLimitsClient().fetch(
            executable: executable(response: response), timeout: 2)
        XCTAssertEqual(summary.weekly?.usedPercent, 48)
        XCTAssertEqual(summary.weekly?.windowDurationMins, 10080)
        XCTAssertEqual(summary.weekly?.resetsAt.timeIntervalSince1970, 1_791_240_000)
        XCTAssertEqual(summary.resetCount, 2)
        XCTAssertNotNil(summary.observedAt)
        XCTAssertEqual(summary.status, "Codex app-server 实时读取")
        XCTAssertEqual(summary.source, "codex-app-server")
        let persisted = String(decoding: try HuantaiJSON.encoder().encode(summary), as: UTF8.self)
        XCTAssertFalse(persisted.contains("SYNTHETIC_ACCOUNT"))
        XCTAssertFalse(persisted.contains("SYNTHETIC_CREDIT"))
        XCTAssertFalse(persisted.contains("SYNTHETIC_BANNER"))
        XCTAssertFalse(persisted.contains("SYNTHETIC_HOME"))
    }

    func testResetCreditExpirationKeepsNullUnknownAndIncompleteDetailsDistinct() throws {
        let response =
            #"{"id":2,"result":{"rateLimitResetCredits":{"availableCount":"5","credits":[{"id":"PRIVATE_CARD","title":"PRIVATE_TITLE","expiresAt":1791520200},{"expiresAt":null},{},{"expiresAt":-1}]}}}"#
        let summary = try CodexRateLimitsClient().fetch(
            executable: executable(response: response), timeout: 2)
        XCTAssertEqual(summary.resetCount, 5)
        let credits = try XCTUnwrap(summary.resetCredits)
        XCTAssertEqual(credits.count, 4)
        XCTAssertEqual(credits[0].expiresAt?.timeIntervalSince1970, 1_791_520_200)
        XCTAssertTrue(credits[0].expirationKnown)
        XCTAssertNil(credits[1].expiresAt)
        XCTAssertTrue(credits[1].expirationKnown)
        XCTAssertFalse(credits[2].expirationKnown)
        XCTAssertFalse(credits[3].expirationKnown)
        let encoded = try HuantaiJSON.encoder().encode(summary)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("PRIVATE_"))
        let decoded = try HuantaiJSON.decoder().decode(UsageSummary.self, from: encoded)
        XCTAssertEqual(decoded.resetCredits, summary.resetCredits)
        XCTAssertEqual(decoded.resetCount, summary.resetCount)
        XCTAssertEqual(
            try XCTUnwrap(decoded.observedAt).timeIntervalSince1970,
            try XCTUnwrap(summary.observedAt).timeIntervalSince1970, accuracy: 0.001)
        let imported = try UsageSnapshotImporter.decode(Data(response.utf8))
        XCTAssertEqual(imported.resetCredits, credits)
        let countOnly = #"{"id":2,"result":{"rateLimitResetCredits":{"availableCount":2,"credits":null}}}"#
        let count = try CodexRateLimitsClient().fetch(
            executable: executable(response: countOnly, excludeDetails: true), timeout: 2,
            includeResetCreditDetails: false)
        XCTAssertEqual(count.resetCount, 2)
        XCTAssertNil(count.resetCredits)
    }

    func testResetDateAndCardExpirationUseLocalDatesAndMinutePrecision() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-08T16:30:45Z"))
        XCTAssertEqual(UsageDate.resetText(resetsAt: date, timeZone: zone), "10-09(周五) 00:30 重置")
        XCTAssertEqual(
            UsageDate.resetText(resetsAt: date, timeZone: TimeZone(secondsFromGMT: 0)!), "10-08(周四) 16:30 重置")
        XCTAssertEqual(UsageDate.resetText(resetsAt: nil), "重置时间未连接")
        XCTAssertEqual(
            UsageDate.creditExpiryText(ResetCreditExpiry(expiresAt: date), timeZone: zone),
            "2026-10-09 00:30到期")
        XCTAssertEqual(UsageDate.creditExpiryText(ResetCreditExpiry()), "不过期")
        XCTAssertEqual(UsageDate.creditExpiryText(ResetCreditExpiry(expirationKnown: false)), "有效期未知")
    }

    func testAuthenticationRPCErrorReportsNumericCodeWithoutServiceMessage() throws {
        let response =
            "{\"id\":2,\"error\":{\"code\":-32000,\"message\":\"Authentication required SYNTHETIC_TOKEN_MUST_NOT_LEAK\"}}"
        let url = try executable(response: response)
        XCTAssertThrowsError(try CodexRateLimitsClient().fetch(executable: url, timeout: 2)) { error in
            XCTAssertEqual(error as? CodexRateLimitsError, .rpc(code: -32000, requiresLogin: true))
            XCTAssertTrue(error.localizedDescription.contains("-32000"))
            XCTAssertFalse(error.localizedDescription.contains("SYNTHETIC_TOKEN"))
        }
    }

    func testTokenRefreshRequestIsNotAnsweredOrAuthorized() throws {
        let url = try executable(
            response:
                "{\"id\":\"server-1\",\"method\":\"account/chatgptAuthTokens/refresh\",\"params\":{\"SYNTHETIC_TOKEN\":\"do-not-use\"}}"
        )
        XCTAssertThrowsError(try CodexRateLimitsClient().fetch(executable: url, timeout: 2)) { error in
            XCTAssertEqual(error as? CodexRateLimitsError, .unsupportedServerRequest(requiresLogin: true))
            XCTAssertFalse(error.localizedDescription.contains("SYNTHETIC_TOKEN"))
        }
    }

    func testAbsentWeeklyWindowAndNullCountStayUnavailable() throws {
        let response =
            "{\"id\":2,\"result\":{\"rateLimits\":{\"primary\":{\"usedPercent\":20,\"windowDurationMins\":300,\"resetsAt\":1791240000},\"secondary\":null},\"rateLimitResetCredits\":null}}"
        let summary = try CodexRateLimitsClient().fetch(
            executable: executable(response: response), timeout: 2)
        XCTAssertNil(summary.weekly)
        XCTAssertNil(summary.resetCount)
        XCTAssertEqual(summary.status, "Codex app-server 实时读取")
        XCTAssertEqual(summary.source, "codex-app-server")
    }

    func testFloatingPointExtremesAndNonpositiveResetsCannotBecomeWeeklyWindows() throws {
        let values = [("1e308", "48"), ("0", "48"), ("-1", "48"), ("1791240000", "1e308")]
        for (reset, used) in values {
            let response =
                "{\"id\":2,\"result\":{\"rateLimits\":{\"primary\":null,\"secondary\":{\"usedPercent\":\(used),\"windowDurationMins\":10080,\"resetsAt\":\(reset)}},\"rateLimitResetCredits\":null}}"
            let summary = try CodexRateLimitsClient().fetch(
                executable: executable(response: response), timeout: 2)
            XCTAssertNil(summary.weekly)
            XCTAssertNil(summary.resetCount)
        }
    }

    func testTimeoutStopsShortLivedProcess() throws {
        let url = try executable(response: "", delay: true)
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try CodexRateLimitsClient().fetch(executable: url, timeout: 0.1)) { error in
            XCTAssertEqual(error as? CodexRateLimitsError, .timeout)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
    }

    func testMissingExecutableAndInvalidTimeoutAreClearErrors() throws {
        XCTAssertThrowsError(
            try CodexRateLimitsClient().fetch(executable: root.appendingPathComponent("absent"))
        ) { error in
            XCTAssertEqual(error as? CodexRateLimitsError, .executableUnavailable)
        }
        XCTAssertThrowsError(try CodexRateLimitsClient().fetch(timeout: 0)) { error in
            XCTAssertEqual(error as? CodexRateLimitsError, .invalidTimeout)
        }
    }
}
