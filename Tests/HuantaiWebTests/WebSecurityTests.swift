import XCTest

@testable import HuantaiWeb

final class WebSecurityTests: XCTestCase {
    private let token = String(repeating: "ab", count: 32)
    private let port: UInt16 = 18784

    private func request(
        _ method: String = "GET", _ path: String = "/api/snapshot",
        headers: [String: String] = [:], body: String = ""
    ) -> WebHTTPRequest {
        var values = ["host": "127.0.0.1:\(port)"]
        values.merge(headers) { _, new in new }
        return WebHTTPRequest(
            method: method, target: path, version: "HTTP/1.1",
            headers: values, body: Data(body.utf8))
    }

    private func router(
        snapshot: @escaping () throws -> Data = { Data("{\"sessions\":[]}".utf8) },
        favorite: @escaping (String, Bool) throws -> Void = { _, _ in },
        completed: @escaping (String, Bool) throws -> Void = { _, _ in },
        open: @escaping (String) throws -> Void = { _ in }
    ) -> WebRequestRouter {
        WebRequestRouter(
            port: port, token: token, getSnapshot: snapshot, setFavorite: favorite, setCompleted: completed,
            openSession: open)
    }

    func testSameOriginReadAndMissingOrForeignHostAreRejected() {
        var reads = 0
        let handler = router(snapshot: {
            reads += 1
            return Data("{}".utf8)
        })
        XCTAssertEqual(handler.response(to: request(headers: ["sec-fetch-site": "same-origin"])).status, 200)
        XCTAssertEqual(reads, 1)
        let hosts = [
            "evil.example:18784", "127.0.0.1.evil.example:18784", "127.0.0.1:80", "127.0.0.1", "[::1]:18784",
            "",
        ]
        for host in hosts {
            XCTAssertEqual(handler.response(to: request(headers: ["host": host])).status, 403, host)
        }
        XCTAssertEqual(
            handler.response(
                to: WebHTTPRequest(
                    method: "GET", target: "/api/snapshot", version: "HTTP/1.1", headers: [:], body: Data())
            ).status, 403)
        XCTAssertEqual(reads, 1)
    }

    func testCrossOriginAndCrossSiteCannotReadMetadata() {
        let handler = router(snapshot: {
            XCTFail("Cross-site request reached the store")
            return Data()
        })
        for origin in ["https://evil.example", "http://127.0.0.1:9999", "null", "http://localhost:18784"] {
            XCTAssertEqual(handler.response(to: request(headers: ["origin": origin])).status, 403, origin)
        }
        for site in ["cross-site", "same-site", "unknown"] {
            XCTAssertEqual(handler.response(to: request(headers: ["sec-fetch-site": site])).status, 403, site)
        }
    }

    func testFavoriteRequiresRandomTokenJSONAndValidIdentifier() {
        var writes: [(String, Bool)] = []
        let handler = router(favorite: { writes.append(($0, $1)) })
        let body = "{\"id\":\"fixture-thread\",\"value\":true}"
        for supplied in ["", "bad", String(token.dropLast()), token.uppercased()] {
            XCTAssertEqual(
                handler.response(
                    to: request(
                        "POST", "/api/favorite",
                        headers: ["content-type": "application/json", "x-huantai-csrf": supplied], body: body)
                ).status, 403)
        }
        XCTAssertEqual(
            handler.response(
                to: request(
                    "POST", "/api/favorite",
                    headers: ["content-type": "text/plain", "x-huantai-csrf": token], body: body)
            ).status, 403)
        let validHeaders = [
            "content-type": "application/json; charset=utf-8", "x-huantai-csrf": token,
            "origin": "http://127.0.0.1:18784", "sec-fetch-site": "same-origin",
        ]
        XCTAssertEqual(
            handler.response(to: request("POST", "/api/favorite", headers: validHeaders, body: body)).status,
            200)
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?.0, "fixture-thread")
        XCTAssertEqual(writes.first?.1, true)
        for badBody in [
            "{}", "{\"id\":\"\",\"value\":true}", "{\"id\":\"x\",\"value\":\"yes\"}",
            "{\"id\":\"x\\n\",\"value\":true}",
            "{\"id\":\"\(String(repeating: "x", count: 513))\",\"value\":true}",
        ] {
            XCTAssertEqual(
                handler.response(to: request("POST", "/api/favorite", headers: validHeaders, body: badBody))
                    .status, 400)
        }
        XCTAssertEqual(writes.count, 1)
    }

    func testFailureDoesNotExposeStoreErrorOrPrivateContent() {
        enum FixtureFailure: LocalizedError {
            case failed
            var errorDescription: String? { "PRIVATE_MESSAGE_BODY" }
        }
        let handler = router(
            snapshot: { throw FixtureFailure.failed }, favorite: { _, _ in throw FixtureFailure.failed })
        let response = handler.response(to: request())
        XCTAssertEqual(response.status, 500)
        XCTAssertFalse(String(decoding: response.body, as: UTF8.self).contains("PRIVATE_MESSAGE_BODY"))
        let write = handler.response(
            to: request(
                "POST", "/api/favorite",
                headers: ["content-type": "application/json", "x-huantai-csrf": token],
                body: "{\"id\":\"fixture\",\"value\":true}"))
        XCTAssertEqual(write.status, 400)
        XCTAssertFalse(String(decoding: write.body, as: UTF8.self).contains("PRIVATE_MESSAGE_BODY"))
    }

    func testCompletionMutationRequiresLocalOriginTokenBooleanAndKnownSession() {
        var writes: [(String, Bool)] = []
        let handler = router(completed: { id, value in
            guard id == "fixture" else { throw NSError(domain: "fixture", code: 1) }
            writes.append((id, value))
        })
        let headers = [
            "content-type": "application/json", "x-huantai-csrf": token,
            "origin": "http://127.0.0.1:18784",
        ]
        let body = "{\"id\":\"fixture\",\"value\":true}"
        XCTAssertEqual(handler.response(to: request("POST", "/api/completion", body: body)).status, 403)
        var foreign = headers
        foreign["origin"] = "https://evil.example"
        XCTAssertEqual(
            handler.response(to: request("POST", "/api/completion", headers: foreign, body: body)).status, 403
        )
        for bad in ["{}", "{\"id\":\"fixture\",\"value\":\"true\"}", "{\"id\":\"missing\",\"value\":true}"] {
            XCTAssertEqual(
                handler.response(to: request("POST", "/api/completion", headers: headers, body: bad)).status,
                400)
        }
        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(
            handler.response(to: request("POST", "/api/completion", headers: headers, body: body)).status, 200
        )
        XCTAssertEqual(
            handler.response(
                to: request(
                    "POST", "/api/completion", headers: headers,
                    body: "{\"id\":\"fixture\",\"value\":false}")
            ).status, 200)
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes.map { $0.1 }, [true, false])
        XCTAssertEqual(handler.response(to: request("GET", "/api/completion")).status, 405)
    }

    func testStaticPageHasLocalAssetsAndNoTitleHTMLInterpolation() {
        let handler = router()
        let htmlResponse = handler.response(to: request("GET", "/"))
        let html = String(decoding: htmlResponse.body, as: UTF8.self)
        XCTAssertEqual(htmlResponse.status, 200)
        XCTAssertTrue(html.contains(token))
        XCTAssertFalse(html.contains("__CSRF_TOKEN__"))
        XCTAssertTrue(html.contains("src=\"/assets/app.js\""))
        XCTAssertTrue(html.contains("src=\"/assets/model.js\""))
        XCTAssertTrue(html.contains("id=\"source-filter\""))
        XCTAssertTrue(html.contains("id=\"machine-filter\""))
        XCTAssertFalse(html.contains("src=\"https://"))
        let javascript = String(
            decoding: handler.response(to: request("GET", "/assets/app.js")).body, as: UTF8.self)
        XCTAssertFalse(javascript.contains("innerHTML"))
        XCTAssertFalse(javascript.contains("document.write"))
        XCTAssertTrue(javascript.contains("node.textContent = text"))
        XCTAssertTrue(javascript.contains("localStorage.setItem('huantai-sort'"))
        let model = handler.response(to: request("GET", "/assets/model.js"))
        XCTAssertEqual(model.status, 200)
        XCTAssertFalse(String(decoding: model.body, as: UTF8.self).contains("innerHTML"))
        let encoded = String(decoding: htmlResponse.encoded(), as: UTF8.self)
        XCTAssertTrue(encoded.contains("Content-Security-Policy: default-src 'none'"))
        XCTAssertTrue(encoded.contains("frame-ancestors 'none'"))
        XCTAssertTrue(encoded.contains("Cache-Control: no-store"))
        XCTAssertTrue(encoded.contains("Referrer-Policy: no-referrer"))
        XCTAssertFalse(encoded.contains("Access-Control-Allow-Origin"))
    }

    func testOnlyKnownPathsAndMethodsAreServed() {
        let handler = router()
        XCTAssertEqual(handler.response(to: request("GET", "/../../.codex/auth.json")).status, 404)
        XCTAssertEqual(handler.response(to: request("GET", "/api/favorite")).status, 405)
        XCTAssertEqual(handler.response(to: request("DELETE", "/api/snapshot")).status, 405)
        XCTAssertEqual(handler.response(to: request("GET", "/api/snapshot", body: "x")).status, 400)
    }

    func testOpenRequiresSameOriginTokenAndUsesSessionIDRatherThanArbitraryURL() {
        var opened: [String] = []
        let handler = router(open: { opened.append($0) })
        let headers = ["content-type": "application/json", "x-huantai-csrf": token]
        let body = "{\"id\":\"fixture-thread\"}"
        XCTAssertEqual(handler.response(to: request("GET", "/api/open")).status, 405)
        XCTAssertEqual(handler.response(to: request("POST", "/api/open", body: body)).status, 403)
        XCTAssertEqual(
            handler.response(
                to: request(
                    "POST", "/api/open",
                    headers: headers.merging(["origin": "https://evil.example"]) { _, new in new }, body: body
                )
            ).status, 403)
        XCTAssertEqual(
            handler.response(
                to: request("POST", "/api/open", headers: headers, body: "{\"url\":\"https://evil.example\"}")
            ).status, 400)
        XCTAssertEqual(
            handler.response(to: request("POST", "/api/open", headers: headers, body: body)).status, 200)
        XCTAssertEqual(opened, ["fixture-thread"])
    }

    func testParserSupportsFragmentedBodyButRejectsAmbiguity() {
        let start = "POST /api/favorite HTTP/1.1\r\nHost: 127.0.0.1:18784\r\nContent-Length: 2\r\n\r\n"
        if case .incomplete = WebRequestParser.parse(Data((start + "{").utf8)) {
        } else {
            XCTFail("Body should be incomplete")
        }
        if case .request(let parsed) = WebRequestParser.parse(Data((start + "{}").utf8)) {
            XCTAssertEqual(parsed.headers["host"], "127.0.0.1:18784")
            XCTAssertEqual(parsed.body, Data("{}".utf8))
        } else {
            XCTFail("Request should parse")
        }
        let invalid = [
            "GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n",
            "POST / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\nx",
            "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n",
            "GET / HTTP/1.0\r\nHost: a\r\n\r\n",
            "GET http://example.com/ HTTP/1.1\r\nHost: a\r\n\r\n",
            "GET //example.com/ HTTP/1.1\r\nHost: a\r\n\r\n",
            "GET / HTTP/1.1\r\n Host: a\r\n\r\n",
            "GET / HTTP/1.1\r\nHost: a\r\n\r\nGET / HTTP/1.1\r\n\r\n",
            "POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n",
            "POST / HTTP/1.1\r\nContent-Length: 8193\r\n\r\n",
        ]
        for raw in invalid {
            if case .invalid = WebRequestParser.parse(Data(raw.utf8)) {
            } else {
                XCTFail("Ambiguous request accepted")
            }
        }
        if case .invalid = WebRequestParser.parse(
            Data(repeating: 65, count: WebRequestParser.maximumRequestBytes + 1))
        {
        } else {
            XCTFail("Oversized request accepted")
        }
    }
}
