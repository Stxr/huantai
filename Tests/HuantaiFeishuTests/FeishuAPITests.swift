import Foundation
import XCTest

@testable import HuantaiFeishu

private final class FeishuHTTPFixture: URLProtocol {
    static let lock = NSLock()
    static var authCount = 0
    static var sends = 0
    static var endpointHost = "msg-frontier.feishu.cn"
    static var sentBody: [String: Any] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let result: [String: Any]
        switch request.url!.path {
        case "/open-apis/auth/v3/tenant_access_token/internal":
            Self.authCount += 1
            result = ["code": 0, "tenant_access_token": "SYNTHETIC_TOKEN_\(Self.authCount)", "expire": 7200]
        case "/callback/ws/endpoint":
            result = [
                "code": 0,
                "data": [
                    "URL": "wss://\(Self.endpointHost)/ws?service_id=17&device_id=fixture",
                    "ClientConfig": ["PingInterval": 120],
                ],
            ]
        case "/open-apis/im/v1/messages":
            Self.sends += 1
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var body = Data()
                var bytes = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    if count <= 0 { break }
                    body.append(contentsOf: bytes.prefix(count))
                }
                Self.sentBody = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
            }
            result = ["code": Self.sends == 1 ? 99_991_663 : 0]
        default: result = ["code": -1]
        }
        Self.lock.unlock()
        let data = try! JSONSerialization.data(withJSONObject: result)
        client?.urlProtocol(
            self,
            didReceive: HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class FeishuAPITests: XCTestCase {
    func testOfficialEndpointAndExpiredTokenRetryKeepSameMessageId() async throws {
        FeishuHTTPFixture.authCount = 0
        FeishuHTTPFixture.sends = 0
        FeishuHTTPFixture.endpointHost = "msg-frontier.feishu.cn"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FeishuHTTPFixture.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let api = FeishuAPI(appID: "cli_fixture", secret: "SYNTHETIC_SECRET", session: session)
        let endpoint = try await api.endpoint()
        XCTAssertEqual(endpoint.service, 17)
        XCTAssertEqual(endpoint.pingInterval, 120)
        try await api.validate()
        let item = FeishuOutboxItem(
            id: "fixed_id", bindingID: "binding", chatID: "oc_fixture", card: "{}", createdAt: .now)
        try await api.send(item)
        XCTAssertEqual(FeishuHTTPFixture.authCount, 2)
        XCTAssertEqual(FeishuHTTPFixture.sends, 2)
        XCTAssertEqual(FeishuHTTPFixture.sentBody["uuid"] as? String, "fixed_id")
        XCTAssertEqual(FeishuHTTPFixture.sentBody["msg_type"] as? String, "interactive")
        XCTAssertNil(FeishuHTTPFixture.sentBody["app_secret"])
        FeishuHTTPFixture.endpointHost = "untrusted.invalid"
        do {
            _ = try await api.endpoint()
            XCTFail("Untrusted endpoint accepted")
        } catch {}
    }
}
