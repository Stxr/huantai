import Foundation
import ServiceManagement
import XCTest

@testable import HuantaiApp

final class LoginItemTests: XCTestCase {
    func testRegistrationReadsBackSystemResultAndRepeatedRequestsDoNotRegisterAgain() {
        var status = SMAppService.Status.notRegistered
        var registrations = 0
        var removals = 0
        let manager = LoginItemManager(
            readStatus: { status },
            register: {
                registrations += 1
                status = .enabled
            },
            unregister: {
                removals += 1
                status = .notRegistered
            })
        XCTAssertFalse(manager.isRegistered)
        manager.setEnabled(true)
        XCTAssertEqual(manager.status, .enabled)
        XCTAssertTrue(manager.isRegistered)
        manager.setEnabled(true)
        XCTAssertEqual(registrations, 1)
        manager.setEnabled(false)
        XCTAssertFalse(manager.isRegistered)
        manager.setEnabled(false)
        XCTAssertEqual(removals, 1)
        XCTAssertNil(manager.errorMessage)
    }

    func testApprovalRemainsDistinctFromEnabledAndCanBeCancelled() {
        var status = SMAppService.Status.notRegistered
        var settingsOpened = false
        let manager = LoginItemManager(
            readStatus: { status }, register: { status = .requiresApproval },
            unregister: { status = .notRegistered }, openSettings: { settingsOpened = true })
        manager.setEnabled(true)
        XCTAssertTrue(manager.isRegistered)
        XCTAssertEqual(manager.status, .requiresApproval)
        XCTAssertTrue(manager.statusDescription.contains("等待系统允许"))
        manager.showSystemSettings()
        XCTAssertTrue(settingsOpened)
        manager.setEnabled(false)
        XCTAssertEqual(manager.status, .notRegistered)
        XCTAssertFalse(manager.isRegistered)
    }

    func testFailuresRetainActualSystemStateAndNextSuccessfulActionClearsError() {
        var status = SMAppService.Status.notRegistered
        var fail = true
        let failure = NSError(
            domain: "synthetic.login-item", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "合成系统错误"])
        let manager = LoginItemManager(
            readStatus: { status },
            register: {
                if fail { throw failure }
                status = .enabled
            }, unregister: { throw failure })
        manager.setEnabled(true)
        XCTAssertFalse(manager.isRegistered)
        XCTAssertEqual(manager.errorMessage, "开启开机运行失败：合成系统错误")
        fail = false
        manager.setEnabled(true)
        XCTAssertTrue(manager.isRegistered)
        XCTAssertNil(manager.errorMessage)
        manager.setEnabled(false)
        XCTAssertTrue(manager.isRegistered)
        XCTAssertEqual(manager.errorMessage, "关闭开机运行失败：合成系统错误")
    }

    func testExternalSystemChangesAndRelaunchAreReadWithoutStoredBoolean() {
        var status = SMAppService.Status.enabled
        let manager = LoginItemManager(readStatus: { status }, register: {}, unregister: {})
        XCTAssertTrue(manager.isRegistered)
        status = .requiresApproval
        manager.refresh()
        XCTAssertEqual(manager.status, .requiresApproval)
        status = .notRegistered
        manager.refresh()
        XCTAssertFalse(manager.isRegistered)
        let relaunched = LoginItemManager(readStatus: { status }, register: {}, unregister: {})
        XCTAssertFalse(relaunched.isRegistered)
        status = .notFound
        manager.refresh()
        XCTAssertFalse(manager.isRegistered)
        XCTAssertTrue(manager.statusDescription.contains("未找到"))
    }

    func testLoginLaunchWithoutEnvironmentReusesConfiguredDataAndSourceDirectories() throws {
        let suite = "huantai.launch.fixture." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let configured = AppLaunchConfiguration.store(
            preferences: preferences,
            environment: [
                "HUANTAI_HOME": "/fixture/state", "HUANTAI_CODEX_HOME": "/fixture/codex",
                "HUANTAI_BOTMUX_HOME": "/fixture/botmux",
                "HUANTAI_DSH_HOME": "/fixture/dsh",
            ])
        let relaunched = AppLaunchConfiguration.store(preferences: preferences, environment: [:])
        XCTAssertEqual(relaunched.dataDirectory, configured.dataDirectory)
        XCTAssertEqual(relaunched.codexDirectory, configured.codexDirectory)
        XCTAssertEqual(relaunched.botmuxDirectory, configured.botmuxDirectory)
        XCTAssertEqual(relaunched.deepSeekHarnessDirectory, configured.deepSeekHarnessDirectory)
        let overridden = AppLaunchConfiguration.store(
            preferences: preferences, environment: ["HUANTAI_HOME": "/fixture/new-state"])
        XCTAssertEqual(overridden.dataDirectory.path, "/fixture/new-state")
        XCTAssertEqual(overridden.codexDirectory, configured.codexDirectory)
    }

    func testSyntheticLaunchDoesNotPersistDirectoriesOrReuseProductionConfiguration() throws {
        let suite = "huantai.launch.isolation." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set("/fixture/real-state", forKey: "launchDirectory.HUANTAI_HOME")
        let test = AppLaunchConfiguration.store(
            preferences: preferences,
            environment: ["HUANTAI_TEST_MODE": "1", "HUANTAI_HOME": "/fixture/test-state"])
        XCTAssertEqual(test.dataDirectory.path, "/fixture/test-state")
        XCTAssertEqual(preferences.string(forKey: "launchDirectory.HUANTAI_HOME"), "/fixture/real-state")
        let clean = AppLaunchConfiguration.store(
            preferences: preferences, environment: ["HUANTAI_TEST_MODE": "1"])
        XCTAssertNotEqual(clean.dataDirectory.path, "/fixture/real-state")
        XCTAssertNotEqual(
            clean.deepSeekHarnessDirectory.path,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dsh").path)
    }
}
