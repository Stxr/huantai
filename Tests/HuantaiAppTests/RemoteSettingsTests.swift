import AppKit
import SwiftUI
import XCTest

@testable import HuantaiApp
@testable import HuantaiCore

final class RemoteSettingsTests: XCTestCase {
    @MainActor
    func testSettingsSaveEditRemoveStayIndependentOfLocalSources() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "huantai.remote-settings." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let store = SessionStore(
            dataDirectory: directory, codexDirectory: directory.appendingPathComponent("codex"),
            botmuxDirectory: directory.appendingPathComponent("botmux"),
            deepSeekHarnessDirectory: directory.appendingPathComponent("dsh"))
        store.remoteScanner = RemoteCodexScanner { _ in [] }
        try store.setSessionSource(.codex, enabled: false)
        try store.setSessionSource(.deepSeekHarness, enabled: false)
        let model = AppModel(startServices: false, preferences: preferences, store: store)
        model.saveRemoteTarget(id: nil, name: " 自定义远端 ", host: " example ", root: "/srv/custom-codex")
        try await waitForSave(model)
        let target = try XCTUnwrap(model.sourceConfiguration.remoteTargets.first)
        XCTAssertEqual(target.name, "自定义远端")
        XCTAssertEqual(target.host, "example")
        XCTAssertEqual(target.sessionRoot, "/srv/custom-codex")
        XCTAssertFalse(model.sourceConfiguration.codexEnabled)
        XCTAssertNil(model.sourceConfiguration.codexHome)
        model.saveRemoteTarget(id: target.id, name: "已编辑", host: "another", root: "~/custom")
        try await waitForSave(model)
        XCTAssertEqual(model.sourceConfiguration.remoteTargets.count, 1)
        XCTAssertEqual(model.sourceConfiguration.remoteTargets.first?.host, "another")
        XCTAssertEqual(try store.configuration().remoteTargets.first?.sessionRoot, "~/custom")
        model.removeRemoteTarget(id: target.id)
        try await waitForSave(model)
        XCTAssertTrue(model.sourceConfiguration.remoteTargets.isEmpty)
        XCTAssertFalse(model.sourceConfiguration.codexEnabled)
    }

    @MainActor
    func testRemoteEditorFitsNarrowSettingsAndRendersPreview() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(dataDirectory: directory)
        try store.setRemoteTarget(
            RemoteTarget(id: "fixture", name: "合成远端", host: "user@example", sessionRoot: "/srv/codex"))
        let model = AppModel(startServices: false, store: store)
        let view = RemoteConnectionsView(model: model).padding(16).frame(width: 366)
        let controller = NSHostingController(rootView: view)
        XCTAssertEqual(controller.sizeThatFits(in: NSSize(width: 366, height: 800)).width, 366, accuracy: 1)
        guard let path = ProcessInfo.processInfo.environment["HUANTAI_RENDER_REMOTE_DIR"] else { return }
        let previewDirectory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: previewDirectory, withIntermediateDirectories: true)
        let usage = SessionTokenUsage(
            totalTokens: 1_234_567, contextTokens: 88000, contextWindow: 100000,
            measuredAt: "2026-10-10T00:00:00Z", compacted: false)
        let preview = VStack(alignment: .leading, spacing: 18) {
            view
            Text("会话 Token 用量").font(.headline)
            SessionTokenUsageView(usage: usage)
            SessionTokenUsageView(usage: nil)
        }.padding(20).background(Color.white).environment(\.colorScheme, .light)
        let hosting = NSHostingController(rootView: preview)
        let size = hosting.sizeThatFits(in: NSSize(width: 406, height: 1000))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        window.orderFront(nil)
        defer { window.close() }
        hosting.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let bitmap = try XCTUnwrap(hosting.view.bitmapImageRepForCachingDisplay(in: hosting.view.bounds))
        hosting.view.cacheDisplay(in: hosting.view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
            to: previewDirectory.appendingPathComponent("remote-settings.png"))
    }

    @MainActor
    private func waitForSave(_ model: AppModel) async throws {
        for _ in 0..<100 {
            if !model.savingSourceConfiguration { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(model.savingSourceConfiguration)
        XCTAssertNil(model.notice)
    }
}
