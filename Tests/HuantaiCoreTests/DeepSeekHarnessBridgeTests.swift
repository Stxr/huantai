import Darwin
import Foundation
import Network
import XCTest

@testable import HuantaiCore

final class DeepSeekHarnessBridgeTests: XCTestCase {
    private let target = DeepSeekHarnessOpenTarget(sessionID: "session-fixture", dataDir: "/fixture/dsh")!

    private func discovery(_ changes: [String: Any] = [:], target: DeepSeekHarnessOpenTarget? = nil) throws
        -> DeepSeekHarnessBridgeDiscovery
    {
        let target = target ?? self.target
        var json: [String: Any] = [
            "protocolVersion": 1, "instanceId": "desktop-fixture", "pid": 123,
            "profile": "desktop", "dataDir": target.dataDir,
            "endpoint": "http://127.0.0.1:32123/huantai/session-bridge/v1/open",
            "token": String(repeating: "a", count: 64), "startedAt": 1_800_000_000_000,
        ]
        for (key, value) in changes { json[key] = value }
        return try JSONDecoder().decode(
            DeepSeekHarnessBridgeDiscovery.self,
            from: JSONSerialization.data(withJSONObject: json))
    }

    private static func result(
        _ request: URLRequest, status: String = "opened", http: Int = 200,
        changes: [String: Any] = [:]
    ) throws -> (Data, HTTPURLResponse) {
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        var result: [String: Any] = [
            "protocolVersion": 1, "requestId": try XCTUnwrap(payload["requestId"]),
            "sessionId": try XCTUnwrap(payload["sessionId"]), "status": status,
        ]
        for (key, value) in changes { result[key] = value }
        return (
            try JSONSerialization.data(withJSONObject: result),
            try XCTUnwrap(
                HTTPURLResponse(
                    url: XCTUnwrap(request.url), statusCode: http,
                    httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]))
        )
    }

    func testDiscoveryRejectsForeignRootsUnsafeEndpointsAndProtocolFields() throws {
        _ = try discovery().validated(for: target)
        let changes: [[String: Any]] =
            [
                ["protocolVersion": 2], ["profile": "cli"], ["dataDir": "/other/dsh"],
                ["dataDir": "/fixture/../fixture/dsh"], ["token": "short"],
                ["token": String(repeating: "z", count: 64)], ["pid": 0], ["startedAt": 0],
            ]
            + [
                "https://127.0.0.1:32123/huantai/session-bridge/v1/open",
                "http://localhost:32123/huantai/session-bridge/v1/open",
                "http://127.1:32123/huantai/session-bridge/v1/open",
                "http://127.0.0.1:32123/huantai/session-bridge/v1/open?query=1",
                "http://127.0.0.1:32123/huantai/session-bridge/v1/open#fragment",
                "http://user@127.0.0.1:32123/huantai/session-bridge/v1/open",
                "http://127.0.0.1:32123/huantai/session-bridge/v1/open/",
                "http://127.0.0.1:32123/huantai/session-bridge/v1/%6fpen",
                "http://127.0.0.1:0/huantai/session-bridge/v1/open",
            ].map { ["endpoint": $0] }
        for change in changes {
            XCTAssertThrowsError(try discovery(change).validated(for: target), "\(change.keys)")
        }
    }

    func testDiscoveryFileRequiresPrivateRegularBoundedFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "huantai-bridge-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("huantai-bridge")
        let file = directory.appendingPathComponent("desktop.json")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let local = try XCTUnwrap(DeepSeekHarnessOpenTarget(sessionID: "fixture", dataDir: root.path))
        let valid: [String: Any] = [
            "protocolVersion": 1, "instanceId": "fixture", "pid": 123, "profile": "desktop",
            "dataDir": local.dataDir, "endpoint": "http://127.0.0.1:32123/huantai/session-bridge/v1/open",
            "token": String(repeating: "b", count: 64), "startedAt": 1_800_000_000_000,
        ]
        let data = try JSONSerialization.data(withJSONObject: valid)
        try data.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertEqual(try DeepSeekHarnessBridgeDiscovery.read(for: local).instanceId, "fixture")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertThrowsError(try DeepSeekHarnessBridgeDiscovery.read(for: local))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try DeepSeekHarnessBridgeDiscovery.read(for: local))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try Data(repeating: 32, count: 16 * 1024 + 1).write(to: file)
        XCTAssertThrowsError(try DeepSeekHarnessBridgeDiscovery.read(for: local))
        try FileManager.default.removeItem(at: file)
        let other = root.appendingPathComponent("other.json")
        try data.write(to: other)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: other.path)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
        XCTAssertThrowsError(try DeepSeekHarnessBridgeDiscovery.read(for: local))
    }

    func testRetriesKeepIdentityAndWaitThroughAcceptedAndReadiness() async throws {
        let discovery = try discovery()
        let transport = RecordingBridgeTransport { request, index in
            if index == 0 { throw URLError(.networkConnectionLost) }
            return try Self.result(
                request, status: index == 1 ? "not-ready" : index == 2 ? "accepted" : "opened",
                http: index == 1 ? 503 : 200)
        }
        let start = Date().timeIntervalSince1970 * 1000
        let client = DeepSeekHarnessBridgeClient(
            transport: transport, readDiscovery: { _ in discovery }, retryDelay: 1)
        try await client.open(target, deadline: ProcessInfo.processInfo.systemUptime + 1)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 4)
        let payloads = try requests.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap($0.httpBody)) as? [String: Any])
        }
        XCTAssertEqual(Set(payloads.compactMap { $0["requestId"] as? String }).count, 1)
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(payloads[0]["requestId"] as? String)))
        for (request, payload) in zip(requests, payloads) {
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + discovery.token)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(payload["protocolVersion"] as? Int, 1)
            XCTAssertEqual(payload["instanceId"] as? String, discovery.instanceId)
            XCTAssertEqual(payload["sessionId"] as? String, target.sessionID)
            XCTAssertEqual(payload["dataDir"] as? String, target.dataDir)
            let expiry = try XCTUnwrap(payload["expiresAt"] as? Double)
            XCTAssertGreaterThan(expiry, start)
            XCTAssertLessThanOrEqual(expiry, start + 15_000)
        }
    }

    func testTerminalBusinessResultsAndMismatchedRepliesNeverReportSuccess() async throws {
        let discovery = try discovery()
        for status in [
            "not-found", "archived", "unsupported-target", "load-failed", "timeout",
            "superseded", "instance-mismatch", "invalid-request", "unknown",
        ] {
            let transport = RecordingBridgeTransport { request, _ in try Self.result(request, status: status)
            }
            do {
                try await DeepSeekHarnessBridgeClient(transport: transport, readDiscovery: { _ in discovery })
                    .open(target, deadline: ProcessInfo.processInfo.systemUptime + 1)
                XCTFail("Unexpected success for \(status)")
            } catch {}
            let count = await transport.requests.count
            XCTAssertEqual(count, 1)
        }
        let changes: [[String: Any]] = [
            ["requestId": "foreign"], ["sessionId": "other"], ["protocolVersion": 2],
        ]
        for change in changes {
            let transport = RecordingBridgeTransport { request, _ in try Self.result(request, changes: change)
            }
            do {
                try await DeepSeekHarnessBridgeClient(transport: transport, readDiscovery: { _ in discovery })
                    .open(target, deadline: ProcessInfo.processInfo.systemUptime + 1)
                XCTFail("Accepted mismatched response")
            } catch {}
        }
        let transport = RecordingBridgeTransport { request, _ in try Self.result(request, http: 503) }
        do {
            try await DeepSeekHarnessBridgeClient(transport: transport, readDiscovery: { _ in discovery })
                .open(target, deadline: ProcessInfo.processInfo.systemUptime + 1)
            XCTFail("Accepted opened with invalid HTTP status")
        } catch {}
    }

    @MainActor
    func testLaunchWaitsForAcknowledgementWithoutBlockingMainAndBareEntryOnlyLaunches() async throws {
        let discovery = try discovery()
        let transport = RecordingBridgeTransport { request, _ in try Self.result(request) }
        let exact = expectation(description: "precise completion")
        let client = DeepSeekHarnessBridgeClient(transport: transport, readDiscovery: { _ in discovery })
        let operation = DeepSeekHarnessOpenOperation(client: client, timeout: 1) { error in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertNil(error)
            exact.fulfill()
        }
        operation.launched(error: nil, target: target)
        let main = expectation(description: "main remains available")
        DispatchQueue.main.async { main.fulfill() }
        await fulfillment(of: [main, exact], timeout: 2)
        let bare = expectation(description: "bare launch completion")
        let bareOperation = DeepSeekHarnessOpenOperation(client: client, timeout: 1) { error in
            XCTAssertNil(error)
            bare.fulfill()
        }
        bareOperation.launched(error: nil, target: nil)
        await fulfillment(of: [bare], timeout: 2)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    @MainActor
    func testNoDesktopConsumerEndsWithExplicitErrorAndSingleCallback() async throws {
        let failed = expectation(description: "missing consumer fails")
        failed.assertForOverFulfill = true
        let client = DeepSeekHarnessBridgeClient(
            readDiscovery: { _ in throw DeepSeekHarnessBridgeError.missingDiscovery }, retryDelay: 1_000_000)
        let operation = DeepSeekHarnessOpenOperation(client: client, timeout: 0.03) { error in
            XCTAssertNotNil(error)
            XCTAssertTrue(error?.localizedDescription.contains("桥接") == true)
            failed.fulfill()
        }
        operation.launched(error: nil, target: target)
        await fulfillment(of: [failed], timeout: 1)
    }

    func testRealHTTPTransportReceivesExactAckAndRejectsRedirectsAndOversizedBodies() async throws {
        let server = try await BridgeHTTPFixture { request in
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: request) as? [String: Any])
            return "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n".data(
                using: .utf8)!
                + (try JSONSerialization.data(withJSONObject: [
                    "protocolVersion": 1, "requestId": try XCTUnwrap(payload["requestId"]),
                    "sessionId": try XCTUnwrap(payload["sessionId"]), "status": "opened",
                ]))
        }
        defer { server.stop() }
        let discovery = try discovery(["endpoint": server.endpoint])
        try await DeepSeekHarnessBridgeClient(readDiscovery: { _ in discovery })
            .open(target, deadline: ProcessInfo.processInfo.systemUptime + 2)
        for response in [
            "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:1/credentials\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
                .data(using: .utf8)!,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n".data(
                using: .utf8)! + Data(repeating: 32, count: 65 * 1024),
        ] {
            let server = try await BridgeHTTPFixture { _ in response }
            defer { server.stop() }
            let info = try self.discovery(["endpoint": server.endpoint])
            do {
                try await DeepSeekHarnessBridgeClient(readDiscovery: { _ in info })
                    .open(target, deadline: ProcessInfo.processInfo.systemUptime + 2)
                XCTFail("Unsafe HTTP response was accepted")
            } catch let error as DeepSeekHarnessBridgeError {
                switch error {
                case .invalidResponse, .responseTooLarge: break
                default: XCTFail("Unexpected bridge failure: \(error)")
                }
            }
        }
    }
}

private actor RecordingBridgeTransport: DeepSeekHarnessBridgeTransport {
    private(set) var requests: [URLRequest] = []
    let respond: (URLRequest, Int) throws -> (Data, HTTPURLResponse)
    init(_ respond: @escaping (URLRequest, Int) throws -> (Data, HTTPURLResponse)) { self.respond = respond }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let index = requests.count
        requests.append(request)
        return try respond(request, index)
    }
}

private final class BridgeHTTPFixture {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "huantai.bridge.http-fixture")
    private let respond: (Data) throws -> Data
    var endpoint: String { "http://127.0.0.1:\(listener.port!.rawValue)/huantai/session-bridge/v1/open" }

    init(respond: @escaping (Data) throws -> Data) async throws {
        self.respond = respond
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            connection.start(queue: self.queue)
            self.receive(connection, buffered: Data())
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.listener.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    self?.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, ended, error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            let buffer = buffered + (data ?? Data())
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)),
                let headers = String(data: buffer[..<range.lowerBound], encoding: .utf8),
                let lengthLine = headers.components(separatedBy: "\r\n").first(where: {
                    $0.lowercased().hasPrefix("content-length:")
                }),
                let length = Int(
                    lengthLine.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)),
                buffer.count - range.upperBound >= length
            {
                do {
                    let response = try self.respond(
                        Data(buffer[range.upperBound..<(range.upperBound + length)]))
                    connection.send(
                        content: response, completion: .contentProcessed { _ in connection.cancel() })
                } catch { connection.cancel() }
            } else if ended {
                connection.cancel()
            } else {
                self.receive(connection, buffered: buffer)
            }
        }
    }
}
