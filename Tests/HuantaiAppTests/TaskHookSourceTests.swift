import Foundation
import HuantaiCore
import XCTest

@testable import HuantaiApp

final class TaskHookSourceTests: XCTestCase {
    func testSourceSelectionAndConfiguredDirectoriesDefineHookTargets() {
        let configuration = StoreConfiguration(
            codexEnabled: false, deepSeekHarnessEnabled: true,
            codexHome: "/custom/codex", deepSeekHarnessHome: "/custom/dsh")
        let sources = TaskHookSources(
            configuration: configuration,
            codexHome: URL(fileURLWithPath: "/default/codex"),
            deepSeekHarnessHome: URL(fileURLWithPath: "/default/dsh"))
        XCTAssertNil(sources.codexHome)
        XCTAssertEqual(sources.deepSeekHarnessHome?.path, "/custom/dsh")
    }

    func testLegacyEnabledConfigurationMigratesButDisabledCodexDoesNotResurrect() throws {
        let decoder = JSONDecoder()
        let old = try decoder.decode(
            TaskHookConfiguration.self,
            from: Data("{\"enabled\":true,\"installedHome\":\"/old/codex\"}".utf8))
        XCTAssertTrue(old.accepts(.codex, home: "/old/codex"))
        XCTAssertFalse(old.permits(.deepSeekHarness))
        let disabled = TaskHookConfiguration(
            enabled: true, installedHome: "/old/codex",
            deepSeekHarnessHome: "/new/dsh")
        let roundTrip = try decoder.decode(TaskHookConfiguration.self, from: JSONEncoder().encode(disabled))
        XCTAssertFalse(roundTrip.permits(.codex))
        XCTAssertTrue(roundTrip.accepts(.deepSeekHarness, home: "/new/dsh"))
        XCTAssertFalse(roundTrip.accepts(.deepSeekHarness, home: "/old/dsh"))
    }

    func testCheckingUncheckingAndMovingSourcesInstallsAndRemovesOnlyOwnedHooks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hook sources " + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = CodexHookInstallation(dataDirectory: root.appendingPathComponent("state"))
        let codex = root.appendingPathComponent("codex")
        let dsh = root.appendingPathComponent("dsh")
        let nextDSH = root.appendingPathComponent("dsh-next")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dsh, withIntermediateDirectories: true)
        let hooks = codex.appendingPathComponent("hooks.json")
        let userHooks: [String: Any] = [
            "hooks": ["Stop": [["hooks": [["command": "user-hook", "type": "command"]]]]]
        ]
        try JSONSerialization.data(withJSONObject: userHooks).write(to: hooks)
        let patch = dsh.appendingPathComponent("cordis.patch.yml")
        let original = "# keep preferences\n[]\n"
        try Data(original.utf8).write(to: patch)
        let executable = root.appendingPathComponent("binary")
        let plugin = root.appendingPathComponent("plugin.mjs")
        try Data("fixture executable".utf8).write(to: executable)
        try Data("export function apply() {}".utf8).write(to: plugin)
        let both = TaskHookSources(codexHome: codex, deepSeekHarnessHome: dsh)
        try installation.synchronize(enabled: true, sources: both, executable: executable, plugin: plugin)
        XCTAssertTrue(installation.configuration().permits(.codex))
        XCTAssertTrue(installation.configuration().permits(.deepSeekHarness))
        XCTAssertTrue(try String(contentsOf: patch).contains("huantai-task-sounds"))
        let onlyDSH = TaskHookSources(deepSeekHarnessHome: dsh)
        try installation.synchronize(enabled: true, sources: onlyDSH, executable: executable, plugin: plugin)
        XCTAssertFalse(installation.configuration().permits(.codex))
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: Data(contentsOf: hooks)) as? NSDictionary,
            userHooks as NSDictionary)
        try installation.synchronize(
            enabled: true, sources: TaskHookSources(deepSeekHarnessHome: nextDSH),
            executable: executable, plugin: plugin)
        XCTAssertEqual(try String(contentsOf: patch), original)
        XCTAssertFalse(installation.configuration().accepts(.deepSeekHarness, home: dsh.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: nextDSH.appendingPathComponent("cordis.patch.yml").path))
        try installation.synchronize(
            enabled: true, sources: TaskHookSources(), executable: executable, plugin: plugin)
        XCTAssertTrue(installation.configuration().enabled)
        XCTAssertFalse(installation.configuration().permits(.deepSeekHarness))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: nextDSH.appendingPathComponent("cordis.patch.yml").path))
        try installation.synchronize(enabled: false, sources: both, executable: executable, plugin: plugin)
        XCTAssertFalse(installation.configuration().enabled)
        XCTAssertEqual(try String(contentsOf: patch), original)
    }

    func testDSHPatchInsertionIsIdempotentAndRetainsUserExpressionsVerbatim() throws {
        let plugin = URL(fileURLWithPath: "/fixture/plugin's hook.mjs")
        let state = URL(fileURLWithPath: "/fixture/state")
        let home = URL(fileURLWithPath: "/fixture/dsh")
        let original = "# User owns this expression\n- id: model\n  config: !!js process.env.MODEL\n"
        // YAML is validated separately against the installed official runtime during acceptance.
        let validate: (String) throws -> Void = { XCTAssertTrue($0.hasPrefix(original)) }
        let installed = try DeepSeekHarnessHookInstallation.content(
            original, enabled: true,
            plugin: plugin, dataDirectory: state, home: home, validate: validate)
        let repeated = try DeepSeekHarnessHookInstallation.content(
            installed, enabled: true,
            plugin: plugin, dataDirectory: state, home: home, validate: validate)
        XCTAssertEqual(installed, repeated)
        let removed = try DeepSeekHarnessHookInstallation.content(
            installed, enabled: false,
            plugin: plugin, dataDirectory: state, home: home, validate: validate)
        XCTAssertEqual(removed, original)
        XCTAssertThrowsError(
            try DeepSeekHarnessHookInstallation.content(
                installed?.replacingOccurrences(of: "# END huantai-task-hook", with: "# changed marker"),
                enabled: false, plugin: plugin, dataDirectory: state, home: home, validate: validate))
    }

    func testDSHPatchPreservesMissingFinalNewlineAndRefusesForeignOwnership() throws {
        let plugin = URL(fileURLWithPath: "/fixture/plugin.mjs")
        let state = URL(fileURLWithPath: "/fixture/state")
        let home = URL(fileURLWithPath: "/fixture/dsh")
        let original = "- id: locale\n  config: {preference: zh}"
        let installed = try DeepSeekHarnessHookInstallation.content(
            original, enabled: true,
            plugin: plugin, dataDirectory: state, home: home, validate: { _ in })
        XCTAssertEqual(
            try DeepSeekHarnessHookInstallation.content(
                installed, enabled: false,
                plugin: plugin, dataDirectory: state, home: home), original)
        XCTAssertThrowsError(
            try DeepSeekHarnessHookInstallation.content(
                installed, enabled: false,
                plugin: URL(fileURLWithPath: "/different/plugin.mjs"), dataDirectory: state, home: home))
        XCTAssertThrowsError(
            try DeepSeekHarnessHookInstallation.content(
                "{invalid", enabled: true,
                plugin: plugin, dataDirectory: state, home: home,
                validate: { _ in throw HookError.message("invalid") }))
    }

    func testMalformedConfigurationCannotKeepACancelledSourceActive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hook malformed " + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = CodexHookInstallation(dataDirectory: root.appendingPathComponent("state"))
        let home = root.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let hooks = home.appendingPathComponent("hooks.json")
        let bytes = Data("invalid JSON".utf8)
        try bytes.write(to: hooks)
        try installation.save(
            TaskHookConfiguration(enabled: true, installedHome: home.path, codexHome: home.path))
        XCTAssertThrowsError(
            try installation.synchronize(
                enabled: true, sources: TaskHookSources(),
                executable: home, plugin: home))
        XCTAssertFalse(installation.configuration().permits(.codex))
        XCTAssertEqual(try Data(contentsOf: hooks), bytes)
        // Retains installation history so cleanup can retry once the user repairs their configuration.
        XCTAssertEqual(installation.configuration().installedHome, home.path)
    }
}
