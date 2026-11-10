import Foundation
import XCTest
import zlib

@testable import HuantaiFeishu

private final class RegistrationHTTP: URLProtocol {
    static let lock = NSLock()
    static var responses: [(Int, String)] = []
    static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let response = Self.responses.isEmpty ? (500, "{}") : Self.responses.removeFirst()
        Self.lock.unlock()
        if response.0 == -1 {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        client?.urlProtocol(
            self,
            didReceive: HTTPURLResponse(
                url: request.url!, statusCode: response.0,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class RegistrationSleeps: @unchecked Sendable {
    let lock = NSLock()
    var values: [Double] = []
    func record(_ value: Double) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }
}

final class FeishuRegistrationTests: XCTestCase {
    private let beginResponse =
        #"{"device_code":"SYNTHETIC_DEVICE_PRIVATE","verification_uri_complete":"https://open.feishu.cn/page/launcher?code=fixture","expires_in":600,"interval":1}"#
    private var directory: URL!
    private var session: URLSession!
    private var configuration: FeishuBotConfiguration!
    private var client: FeishuAppRegistration!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "huantai-registration-" + UUID().uuidString)
        configuration = FeishuBotConfiguration(dataDirectory: directory)
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [RegistrationHTTP.self]
        session = URLSession(configuration: settings)
        client = FeishuAppRegistration(configuration: configuration, session: session)
        RegistrationHTTP.responses = []
        RegistrationHTTP.requests = []
    }
    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        try? FileManager.default.removeItem(at: directory)
    }

    func testBeginRequestsMinimalBotTemplateAndResumesPrivatelyWithoutAnotherBegin() async throws {
        RegistrationHTTP.responses = [(200, beginResponse)]
        let progress = try await client.begin(name: "换台状态助手")
        XCTAssertFalse(progress.resumed)
        let query = URLComponents(url: progress.challenge.verificationURL, resolvingAgainstBaseURL: false)!
            .queryItems!
        func value(_ key: String) -> String? { query.first { $0.name == key }?.value }
        XCTAssertEqual(value("createOnly"), "true")
        XCTAssertEqual(value("name"), "换台状态助手")
        XCTAssertEqual(value("code"), "fixture")
        let addons = try decodeAddons(try XCTUnwrap(value("addons")))
        XCTAssertEqual(addons["preset"] as? Bool, false)
        let scopes = try XCTUnwrap(addons["scopes"] as? [String: [String]])
        XCTAssertEqual(scopes["tenant"], FeishuAppRegistration.requiredScopes)
        XCTAssertEqual(scopes["user"], [])
        let events = try XCTUnwrap(addons["events"] as? [String: [String: [String]]])
        XCTAssertEqual(events["items"]?["tenant"], ["im.message.receive_v1"])
        XCTAssertEqual((addons["callbacks"] as? [String: [String]])?["items"], ["card.action.trigger"])
        XCTAssertNil(addons["security"])
        let resumed = try await FeishuAppRegistration(configuration: configuration, session: session).begin()
        XCTAssertTrue(resumed.resumed)
        XCTAssertEqual(resumed.challenge.verificationURL, progress.challenge.verificationURL)
        XCTAssertEqual(RegistrationHTTP.requests.count, 1)
        XCTAssertEqual(RegistrationHTTP.requests[0].url?.host, "accounts.feishu.cn")
        XCTAssertEqual(RegistrationHTTP.requests[0].httpMethod, "POST")
        let file = configuration.directory.appendingPathComponent("binding.json")
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        let publicStatus = String(decoding: try JSONEncoder().encode(configuration.status()), as: UTF8.self)
        XCTAssertFalse(publicStatus.contains("SYNTHETIC_DEVICE_PRIVATE"))
        XCTAssertFalse(publicStatus.contains("verification"))
        XCTAssertNil(try configuration.binding())
    }

    func testPendingSlowDownAndSuccessSaveCredentialsOnceAndPreserveExistingBinding() async throws {
        RegistrationHTTP.responses = [
            (200, beginResponse), (400, #"{"error":"authorization_pending"}"#),
            (400, #"{"error":"slow_down"}"#),
            (
                200,
                #"{"client_id":"cli_created","client_secret":"SYNTHETIC_SECRET_PRIVATE","user_info":{"tenant_brand":"feishu"}}"#
            ),
        ]
        let challenge = try await client.begin().challenge
        let sleeps = RegistrationSleeps()
        let binding = try await client.finish(challenge) { sleeps.record($0) }
        XCTAssertEqual(sleeps.values, [1, 6])
        XCTAssertEqual(binding.appID, "cli_created")
        XCTAssertEqual(binding.appSecret, "SYNTHETIC_SECRET_PRIVATE")
        XCTAssertNil(try configuration.registrationChallenge())
        XCTAssertEqual(try FeishuBotConfiguration(dataDirectory: directory).binding()?.appID, binding.appID)
        XCTAssertFalse(
            String(decoding: try JSONEncoder().encode(configuration.status()), as: UTF8.self).contains(
                "SYNTHETIC_SECRET_PRIVATE"))
        do {
            _ = try await client.begin()
            XCTFail("Must not create another app over an existing binding")
        } catch { XCTAssertTrue(error.localizedDescription.contains("已绑定")) }
        XCTAssertEqual(RegistrationHTTP.requests.count, 4)
    }

    func testNetworkFailureCanResumeButDenialClearsOnlyItsOwnPendingChallenge() async throws {
        RegistrationHTTP.responses = [(200, beginResponse), (-1, "")]
        let challenge = try await client.begin().challenge
        do {
            _ = try await client.finish(challenge)
            XCTFail("Network request should fail")
        } catch { XCTAssertFalse(error.localizedDescription.contains("SYNTHETIC_DEVICE_PRIVATE")) }
        XCTAssertNotNil(try configuration.registrationChallenge())
        RegistrationHTTP.responses = [(400, #"{"error":"access_denied"}"#)]
        do {
            _ = try await client.finish(challenge)
            XCTFail("Denied registration should fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("取消")) }
        XCTAssertNil(try configuration.registrationChallenge())
        XCTAssertNil(try configuration.binding())
    }

    func testChangedBindingCannotBeReplacedByLateRegistrationResult() async throws {
        RegistrationHTTP.responses = [(200, beginResponse)]
        let challenge = try await client.begin().challenge
        try configuration.bind(appID: "cli_manual", secret: "MANUAL_SECRET")
        RegistrationHTTP.responses = [(200, #"{"client_id":"cli_late","client_secret":"LATE_SECRET"}"#)]
        do {
            _ = try await client.finish(challenge)
            XCTFail("Must not replace manual binding")
        } catch { XCTAssertTrue(error.localizedDescription.contains("未覆盖")) }
        XCTAssertEqual(try configuration.binding()?.appID, "cli_manual")
        XCTAssertEqual(try configuration.binding()?.appSecret, "MANUAL_SECRET")
    }

    func testCancelledRunDoesNotPollAndLeavesChallengeResumable() async throws {
        RegistrationHTTP.responses = [(200, beginResponse)]
        let challenge = try await client.begin().challenge
        let client = self.client!
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.finish(challenge)
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled run must stop")
        } catch is CancellationError {} catch { XCTFail("Unexpected cancellation error") }
        XCTAssertEqual(RegistrationHTTP.requests.count, 1)
        XCTAssertNotNil(try configuration.registrationChallenge())
        XCTAssertNil(try configuration.binding())
    }

    func testExpiredPendingLinkStopsWithoutStartingAnotherRegistration() async throws {
        let challenge = FeishuRegistrationChallenge(
            deviceCode: "expired", verificationURL: URL(string: "https://accounts.feishu.cn/fixture")!,
            expiresAt: .distantPast, interval: 1)
        _ = try configuration.saveRegistration(challenge)
        do {
            _ = try await client.begin()
            XCTFail("Expired registration should stop")
        } catch { XCTAssertTrue(error.localizedDescription.contains("过期")) }
        XCTAssertEqual(RegistrationHTTP.requests.count, 0)
        XCTAssertNil(try configuration.registrationChallenge())
    }

    func testUntrustedVerificationHostAndServerErrorsNeverExposePayloads() async throws {
        RegistrationHTTP.responses = [
            (
                200,
                #"{"device_code":"private","verification_uri_complete":"https://untrusted.invalid/login","expires_in":600}"#
            )
        ]
        do {
            _ = try await client.begin()
            XCTFail("Untrusted host should fail")
        } catch { XCTAssertFalse(error.localizedDescription.contains("private")) }
        XCTAssertNil(try configuration.registrationChallenge())
        RegistrationHTTP.responses = [
            (200, beginResponse), (400, #"{"error":"SYNTHETIC_PRIVATE_SERVER_PAYLOAD"}"#),
        ]
        let challenge = try await client.begin().challenge
        do {
            _ = try await client.finish(challenge)
            XCTFail("Unexpected error should fail")
        } catch { XCTAssertFalse(error.localizedDescription.contains("SYNTHETIC_PRIVATE_SERVER_PAYLOAD")) }
        XCTAssertNotNil(try configuration.registrationChallenge())
    }

    func testScopeReadbackAndWebSocketEndpointAreCheckedBeforeReady() async throws {
        RegistrationHTTP.responses = [
            (200, #"{"code":0,"tenant_access_token":"SYNTHETIC_ACCESS","expire":7200}"#),
            (
                200,
                #"{"code":0,"data":{"scopes":[{"scope_name":"im:message.p2p_msg:readonly","grant_status":1},{"scope_name":"im:message:send_as_bot","grant_status":1}]}}"#
            ),
            (
                200,
                #"{"code":0,"data":{"URL":"wss://msg-frontier.feishu.cn/ws?service_id=17","ClientConfig":{"PingInterval":120}}}"#
            ),
        ]
        let api = FeishuAPI(appID: "cli_fixture", secret: "SYNTHETIC_SECRET", session: session)
        try await api.validateDashboardScopes()
        XCTAssertEqual(RegistrationHTTP.requests[1].httpMethod, "GET")
        XCTAssertEqual(RegistrationHTTP.requests[1].url?.path, "/open-apis/application/v6/scopes")
        XCTAssertEqual(
            RegistrationHTTP.requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer SYNTHETIC_ACCESS"
        )
        RegistrationHTTP.responses = [
            (200, #"{"code":0,"data":{"scopes":[{"scope_name":"im:message:send_as_bot","grant_status":2}]}}"#)
        ]
        do {
            try await api.validateDashboardScopes()
            XCTFail("Ungranted scopes must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("尚未生效")) }
        XCTAssertEqual(RegistrationHTTP.requests.count, 4)
    }

    private func decodeAddons(_ encoded: String) throws -> [String: Any] {
        var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        let compressed = try XCTUnwrap(Data(base64Encoded: base64))
        var stream = z_stream()
        XCTAssertEqual(inflateInit2_(&stream, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)), Z_OK)
        defer { inflateEnd(&stream) }
        var output = [UInt8](repeating: 0, count: 4096)
        let status = compressed.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { buffer in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress)
                stream.avail_in = uInt(compressed.count)
                stream.next_out = buffer.bindMemory(to: UInt8.self).baseAddress
                stream.avail_out = uInt(buffer.count)
                return inflate(&stream, Z_FINISH)
            }
        }
        XCTAssertEqual(status, Z_STREAM_END)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(output.prefix(Int(stream.total_out)))) as? [String: Any])
    }
}
