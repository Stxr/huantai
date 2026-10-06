import Foundation
import HuantaiCore
import XCTest

@testable import HuantaiApp

final class CodexHookTests: XCTestCase {
    private func fixture() throws -> (URL, CodexHookInstallation, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "huantai hook's fixture " + UUID().uuidString)
        let codex = root.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        return (root, CodexHookInstallation(dataDirectory: root.appendingPathComponent("state")), codex)
    }

    func testInstallAndRemovePreserveUnrelatedHooksAndMetadataAndRemainIdempotent() throws {
        let (root, installation, codex) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = codex.appendingPathComponent("hooks.json")
        let original: [String: Any] = [
            "description": "User configuration",
            "custom": ["keep": true],
            "hooks": [
                "Stop": [
                    [
                        "matcher": "custom",
                        "hooks": [["type": "command", "command": "echo user", "timeout": 10]],
                    ]
                ],
                "PreToolUse": [["hooks": [["type": "command", "command": "echo other"]]]],
            ],
        ]
        try JSONSerialization.data(withJSONObject: original).write(to: url)
        let executable = root.appendingPathComponent("fixture-executable")
        try Data("fixture".utf8).write(to: executable)
        XCTAssertFalse(installation.configuration().enabled)
        try installation.install(in: codex, executable: executable)
        try installation.install(in: codex, executable: executable)
        let installed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let hooks = try XCTUnwrap(installed["hooks"] as? [String: Any])
        XCTAssertEqual((hooks["Stop"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual((hooks["UserPromptSubmit"] as? [[String: Any]])?.count, 1)
        XCTAssertTrue(installation.command.contains("'\\''"))
        try installation.remove(from: codex)
        try installation.remove(from: codex)
        let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? NSDictionary
        XCTAssertEqual(restored, original as NSDictionary)
    }

    func testMalformedHookConfigurationIsNeverOverwritten() throws {
        let (root, installation, codex) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = codex.appendingPathComponent("hooks.json")
        let executable = root.appendingPathComponent("fixture-executable")
        try Data().write(to: executable)
        for bytes in [Data("invalid JSON".utf8), Data("{\"hooks\":{\"Stop\":42}}".utf8)] {
            try bytes.write(to: url)
            XCTAssertThrowsError(try installation.install(in: codex, executable: executable))
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            XCTAssertFalse(installation.configuration().enabled)
        }
    }

    func testReplacingSoundsIsReadImmediatelyAndEmptyFolderStaysSilent() throws {
        let (root, installation, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = root.appendingPathComponent("defaults")
        try FileManager.default.createDirectory(at: defaults, withIntermediateDirectories: true)
        try Data("default".utf8).write(to: defaults.appendingPathComponent("completed.wav"))
        try installation.prepareSounds(from: defaults)
        let folder = installation.soundsDirectory
        let original = try XCTUnwrap(installation.sound(for: .completed))
        try FileManager.default.removeItem(at: original)
        let custom = folder.appendingPathComponent("completed.MP3")
        try Data("custom".utf8).write(to: custom)
        XCTAssertEqual(
            installation.sound(for: .completed)?.resolvingSymlinksInPath(), custom.resolvingSymlinksInPath())
        try installation.prepareSounds(from: defaults)
        XCTAssertEqual(try Data(contentsOf: custom), Data("custom".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        try FileManager.default.removeItem(at: custom)
        XCTAssertNil(installation.sound(for: .completed))
        try installation.prepareSounds(from: defaults)
        XCTAssertNil(installation.sound(for: .completed))
    }

    func testReceiverHonorsDisableAndStoresNoPromptOrAssistantContent() throws {
        let (root, installation, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let arguments = ["hook", "--hook-home", installation.dataDirectory.path]
        let payload = try JSONSerialization.data(withJSONObject: [
            "transcript_path": "/fixture/sessions/transcript.jsonl", "prompt": "private prompt",
            "last_assistant_message": "private reply", "hook_event_name": "Stop",
        ])
        CodexHookInstallation.receive(arguments: arguments, input: payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installation.runtimeDirectory.path))
        try installation.save(TaskHookConfiguration(enabled: true, codexHome: "/fixture"))
        try FileManager.default.createDirectory(
            at: installation.pendingDirectory, withIntermediateDirectories: true)
        CodexHookInstallation.receive(arguments: arguments, input: payload)
        let files = try FileManager.default.contentsOfDirectory(
            at: installation.pendingDirectory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let signal =
            try JSONSerialization.jsonObject(with: Data(contentsOf: XCTUnwrap(files.first))) as? [String: Any]
        XCTAssertEqual(Set(signal?.keys.map { $0 } ?? []), ["transcript", "created"])
        try installation.save(TaskHookConfiguration())
        CodexHookInstallation.receive(arguments: arguments, input: payload)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: installation.pendingDirectory.path).count, 1)
    }

    func testLegacyFoldersFlattenWithoutReplacingCustomFiles() throws {
        let (root, installation, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = root.appendingPathComponent("defaults")
        try FileManager.default.createDirectory(at: defaults, withIntermediateDirectories: true)
        let legacy = installation.soundsDirectory.appendingPathComponent("started")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("old music".utf8).write(to: legacy.appendingPathComponent("building.mp3"))
        try installation.prepareSounds(from: defaults)
        XCTAssertEqual(
            try Data(contentsOf: XCTUnwrap(installation.sound(for: .started))), Data("old music".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        let completed = installation.soundsDirectory.appendingPathComponent("completed")
        try FileManager.default.createDirectory(at: completed, withIntermediateDirectories: true)
        try Data("old completion".utf8).write(to: completed.appendingPathComponent("construction.wav"))
        let custom = installation.soundsDirectory.appendingPathComponent("completed.mp3")
        try Data("custom completion".utf8).write(to: custom)
        try installation.prepareSounds(from: defaults)
        XCTAssertEqual(try Data(contentsOf: custom), Data("custom completion".utf8))
        XCTAssertEqual(
            try Data(
                contentsOf: installation.soundsDirectory.appendingPathComponent(
                    "completed-previous-construction.wav")), Data("old completion".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: completed.path))
    }

    func testDefaultManagerIsOffAndCreatesNoFiles() throws {
        let (root, installation, codex) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = TaskHookManager(
            dataDirectory: installation.dataDirectory, sources: TaskHookSources(codexHome: codex),
            startServices: false)
        XCTAssertFalse(manager.enabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installation.runtimeDirectory.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: codex.appendingPathComponent("hooks.json").path))
    }
}
