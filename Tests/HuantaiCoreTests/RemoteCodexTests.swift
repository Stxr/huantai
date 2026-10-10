import Foundation
import XCTest

@testable import HuantaiCore

final class RemoteCodexTests: XCTestCase {
    private let nativeID = "019f9d97-401f-7942-b6ba-4cda42ca604e"
    private let target = RemoteTarget(
        id: "example", name: "测试主机", host: "user@example", sessionRoot: "/srv/codex")

    func testTargetValidationAndIdentityIsolation() throws {
        try RemoteCodexReader.validate(target)
        for host in ["-oProxyCommand=bad", "host;echo bad", "user@host\n"] {
            XCTAssertThrowsError(try RemoteCodexReader.validate(RemoteTarget(id: "x", name: "x", host: host)))
        }
        for root in ["relative/path", "/bad\npath", ""] {
            XCTAssertThrowsError(
                try RemoteCodexReader.validate(
                    RemoteTarget(id: "x", name: "x", host: "example", sessionRoot: root)))
        }
        var renamed = target
        renamed.name = "新名称"
        XCTAssertEqual(RemoteCodexReader.prefix(target), RemoteCodexReader.prefix(renamed))
        renamed.host = "other-host"
        XCTAssertNotEqual(RemoteCodexReader.prefix(target), RemoteCodexReader.prefix(renamed))
        renamed = target
        renamed.sessionRoot = "/other"
        XCTAssertNotEqual(RemoteCodexReader.prefix(target), RemoteCodexReader.prefix(renamed))
    }

    func testConfiguredRemoteWorksWithLocalDisabledAndPersistsTaskState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory)
        let record = try makeRecord()
        store.remoteScanner = RemoteCodexScanner { _ in [record] }
        try store.setSessionSource(.codex, enabled: false)
        try store.setSessionSource(.deepSeekHarness, enabled: false)
        try store.setRemoteTarget(target)
        var snapshot = try store.refreshRemotes()
        XCTAssertEqual(snapshot.sessions.map(\.id), [record.id])
        XCTAssertNil(snapshot.sessions.first?.openURL)
        XCTAssertTrue(snapshot.sessions.first?.openUnavailableReason?.contains("codex resume") == true)
        try store.setFavorite(id: record.id, value: true)
        try store.setCompleted(id: record.id, value: true)
        try store.setSessionDirectory(.codex, path: directory.appendingPathComponent("other-local").path)
        snapshot = try store.snapshot()
        XCTAssertEqual(snapshot.sessions.count, 1)
        XCTAssertTrue(snapshot.sessions[0].isFavorite)
        XCTAssertTrue(snapshot.sessions[0].isCompleted)
        XCTAssertNil(snapshot.sessions[0].openURL)

        let restarted = makeStore(directory)
        restarted.remoteScanner = RemoteCodexScanner { _ in throw HuantaiError.sourceUnavailable("offline") }
        snapshot = try restarted.refreshRemotes()
        XCTAssertEqual(snapshot.sessions.count, 1)
        XCTAssertTrue(snapshot.sources.last!.status.contains("显示上次缓存"))
        XCTAssertTrue(snapshot.sessions[0].isFavorite)
        try restarted.removeRemoteTarget(id: target.id)
        XCTAssertTrue(try restarted.snapshot().sessions.isEmpty)
        XCTAssertTrue(try restarted.refresh().sessions.isEmpty)
    }

    func testChangingHostDoesNotInheritOldCache() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory)
        let record = try makeRecord()
        store.remoteScanner = RemoteCodexScanner { target in
            if target.host == "user@example" { return [record] }
            throw HuantaiError.sourceUnavailable("offline")
        }
        try store.setRemoteTarget(target)
        _ = try store.refreshRemotes()
        var changed = target
        changed.host = "other"
        try store.setRemoteTarget(changed)
        XCTAssertTrue(try store.snapshot().sessions.isEmpty)
        XCTAssertTrue(try store.refreshRemotes().sessions.isEmpty)
    }

    func testBackgroundReadReturnsImmediatelyAndCoalescesConcurrentScans() throws {
        let started = expectation(description: "reader started")
        let gate = DispatchSemaphore(value: 0)
        let record = try makeRecord()
        let scanner = RemoteCodexScanner { _ in
            started.fulfill()
            _ = gate.wait(timeout: .now() + 5)
            return [record]
        }
        XCTAssertTrue(scanner.scan(target, cached: []).sessions.isEmpty)
        wait(for: [started], timeout: 2)
        for _ in 0..<10 { XCTAssertTrue(scanner.scan(target, cached: []).sessions.isEmpty) }
        gate.signal()
        XCTAssertEqual(scanner.scan(target, cached: [], wait: true).sessions.count, 1)
    }

    private func makeRecord() throws -> SessionRecord {
        let data = Data(
            "[{\"id\":\"\(nativeID)\",\"title\":\"远端任务\",\"cwd\":\"/srv/project\",\"reply\":1000,\"preview\":\"已完成\"}]"
                .utf8)
        return try XCTUnwrap(RemoteCodexReader.decode(data, target: target).first)
    }
    private func makeStore(_ directory: URL) -> SessionStore {
        SessionStore(
            dataDirectory: directory, codexDirectory: directory.appendingPathComponent("missing"),
            botmuxDirectory: directory.appendingPathComponent("botmux"),
            deepSeekHarnessDirectory: directory.appendingPathComponent("dsh"))
    }
}
