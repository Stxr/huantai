import AppKit
import HuantaiCore
import XCTest

@testable import HuantaiApp

final class ShortcutTests: XCTestCase {
    private func preferences() throws -> (String, UserDefaults) {
        let name = "huantai.shortcuts.fixture." + UUID().uuidString
        return (name, try XCTUnwrap(UserDefaults(suiteName: name)))
    }

    func testDefaultsMatchRequestedCombinationsAndInvalidBindingsCannotReplaceThem() throws {
        let defaults = ShortcutBinding.defaults
        try ShortcutBinding.validate(defaults)
        XCTAssertEqual(defaults[.previous]?.display, "⇧⌘↑")
        XCTAssertEqual(defaults[.next]?.display, "⇧⌘↓")
        XCTAssertEqual(defaults[.first]?.display, "⇧⌘\\")
        XCTAssertEqual(defaults[.back]?.display, "⇧⌘←")
        XCTAssertEqual(defaults[.forward]?.display, "⇧⌘→")
        XCTAssertEqual(defaults[.showPopover]?.display, "⌥⌘,")
        XCTAssertEqual(defaults[.showPopover]?.keyCode, 43)
        XCTAssertEqual(defaults[.completeCurrent]?.display, "⇧⌘D")
        XCTAssertEqual(defaults[.completeCurrent]?.keyCode, 2)
        var duplicate = defaults
        duplicate[.next] = defaults[.previous]
        XCTAssertThrowsError(try ShortcutBinding.validate(duplicate))
        duplicate = defaults
        duplicate[.first] = defaults[.showPopover]
        XCTAssertThrowsError(try ShortcutBinding.validate(duplicate))
        XCTAssertThrowsError(
            try ShortcutBinding.validate([.first: .init(keyCode: 43, flags: .command, keyLabel: ",")]))
        XCTAssertThrowsError(
            try ShortcutBinding.validate([.first: .init(keyCode: 0, flags: .shift, keyLabel: "A")]))
    }

    @MainActor
    func testCustomAndDisabledShortcutsPersistWhileRegistrationFailuresDoNotOverwritePreferences() throws {
        let (name, preferences) = try preferences()
        defer { preferences.removePersistentDomain(forName: name) }
        let model = AppModel(startServices: false, preferences: preferences)
        let custom = ShortcutBinding(keyCode: 0, flags: [.command, .option], keyLabel: "A")
        model.updateShortcut(.first, binding: custom)
        model.updateShortcut(.next, binding: nil)
        let reloaded = AppModel(startServices: false, preferences: preferences)
        XCTAssertEqual(reloaded.shortcuts[.first], custom)
        XCTAssertNil(reloaded.shortcuts[.next])
        let savedData = preferences.data(forKey: "sessionShortcuts")
        reloaded.onShortcutConfiguration = { _ in throw ShortcutError.message("合成占用错误") }
        reloaded.restoreDefaultShortcuts()
        XCTAssertEqual(reloaded.shortcuts[.first], custom)
        XCTAssertEqual(preferences.data(forKey: "sessionShortcuts"), savedData)
        XCTAssertEqual(reloaded.shortcutStatus, "合成占用错误")
    }

    func testPartialRegistrationFailureReleasesNewKeysAndRestoresOldBindings() throws {
        var active: [UInt32: String] = [:]
        var failIdentity: String?
        let manager = try GlobalShortcutManager(
            register: { binding, id in
                if binding.identity == failIdentity { throw ShortcutError.message("合成占用错误") }
                XCTAssertNil(active[id])
                active[id] = binding.identity
                return ShortcutRegistration { active[id] = nil }
            }, onAction: { _ in })
        try manager.replace(with: ShortcutBinding.defaults)
        let before = active
        var proposed = ShortcutBinding.defaults
        proposed[.next] = .init(keyCode: 0, flags: [.command, .option], keyLabel: "A")
        failIdentity = proposed[.next]?.identity
        XCTAssertThrowsError(try manager.replace(with: proposed))
        XCTAssertEqual(active, before)
        manager.suspend()
        XCTAssertTrue(active.isEmpty)
    }

    @MainActor
    func testRecordingPausesOnceAndCancellingOrClosingResumesBindings() throws {
        let (name, preferences) = try preferences()
        defer { preferences.removePersistentDomain(forName: name) }
        let model = AppModel(startServices: false, preferences: preferences)
        var transitions: [Bool] = []
        model.onRecordingChanged = { transitions.append($0) }
        model.beginRecording(.first)
        model.beginRecording(.next)
        XCTAssertEqual(transitions, [true])
        model.endRecording()
        model.endRecording()
        XCTAssertEqual(transitions, [true, false])
        model.beginRecording(.first)
        model.popoverClosed()
        XCTAssertNil(model.recordingAction)
        XCTAssertEqual(transitions, [true, false, true, false])
    }

    @MainActor
    func testSettingsNavigationPreservesSessionFiltersAndEndsRecordingOnBack() throws {
        let (name, preferences) = try preferences()
        defer { preferences.removePersistentDomain(forName: name) }
        let model = AppModel(startServices: false, preferences: preferences)
        model.sessionQuery = "fixture"
        model.setFavoritesOnly(true)
        var presentations = 0
        model.onSettingsRequested = { presentations += 1 }
        XCTAssertEqual(model.page, .sessions)
        model.showSettings()
        XCTAssertEqual(model.page, .settings)
        XCTAssertEqual(presentations, 1)
        model.beginRecording(.next)
        model.showSessions()
        XCTAssertEqual(model.page, .sessions)
        XCTAssertNil(model.recordingAction)
        XCTAssertEqual(model.sessionQuery, "fixture")
        XCTAssertTrue(model.favoritesOnly)
    }

    @MainActor
    func testRecorderAcceptsOnlySettingsWindowEventsAndEscapeCancelsBeforeReturning() throws {
        let (name, preferences) = try preferences()
        defer { preferences.removePersistentDomain(forName: name) }
        let model = AppModel(startServices: false, preferences: preferences)
        let ownWindow = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 430, height: 560), styleMask: [], backing: .buffered,
            defer: false)
        let otherWindow = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 100, height: 100), styleMask: [], backing: .buffered,
            defer: false)
        let monitor = SettingsKeyMonitor(model: model, installMonitor: false) { ownWindow }
        func event(_ key: UInt16, in window: NSWindow, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: key == 0 ? "a" : "",
                    charactersIgnoringModifiers: key == 0 ? "a" : "",
                    isARepeat: false, keyCode: key))
        }
        model.showSettings()
        model.beginRecording(.first)
        let foreign = try event(0, in: otherWindow, flags: [.command, .option])
        XCTAssertTrue(monitor.handle(foreign, in: ownWindow) === foreign)
        XCTAssertEqual(model.recordingAction, .first)
        let custom = try event(0, in: ownWindow, flags: [.command, .option])
        XCTAssertNil(monitor.handle(custom, in: ownWindow))
        XCTAssertEqual(model.shortcuts[.first]?.display, "⌥⌘A")
        XCTAssertNil(model.recordingAction)
        model.beginRecording(.next)
        let escape = try event(53, in: ownWindow)
        XCTAssertNil(monitor.handle(escape, in: ownWindow))
        XCTAssertNil(model.recordingAction)
        XCTAssertEqual(model.page, .settings)
        XCTAssertNil(monitor.handle(escape, in: ownWindow))
        XCTAssertEqual(model.page, .sessions)
        XCTAssertTrue(monitor.handle(custom, in: ownWindow) === custom)
    }

    @MainActor
    func testLegacyPreferencesGainWakeDefaultWithoutResettingCustomizedOrDisabledNavigation() throws {
        let (name, preferences) = try preferences()
        defer { preferences.removePersistentDomain(forName: name) }
        // Encode the original Core action type to verify the real older JSON format.
        let custom = ShortcutBinding(keyCode: 0, flags: [.command, .option], keyLabel: "A")
        let legacy: [SessionNavigationAction: ShortcutBinding] = [.first: custom]
        preferences.set(try JSONEncoder().encode(legacy), forKey: "sessionShortcuts")
        let model = AppModel(startServices: false, preferences: preferences)
        XCTAssertEqual(model.shortcuts[.first], custom)
        XCTAssertNil(model.shortcuts[.next])
        XCTAssertEqual(model.shortcuts[.showPopover], ShortcutBinding.defaults[.showPopover])
        XCTAssertEqual(model.shortcuts.count, 3)
        XCTAssertEqual(preferences.integer(forKey: "shortcutSchemaVersion"), 3)
        let reloaded = AppModel(startServices: false, preferences: preferences)
        XCTAssertEqual(reloaded.shortcuts, model.shortcuts)
    }

    @MainActor
    func testWakeCustomizationAndExplicitDisableSurviveReloadAndRestoreDefault() throws {
        let (name, preferences) = try preferences()
        defer { preferences.removePersistentDomain(forName: name) }
        let model = AppModel(startServices: false, preferences: preferences)
        let custom = ShortcutBinding(keyCode: 0, flags: [.command, .control], keyLabel: "A")
        model.updateShortcut(.showPopover, binding: custom)
        var reloaded = AppModel(startServices: false, preferences: preferences)
        XCTAssertEqual(reloaded.shortcuts[.showPopover], custom)
        reloaded.updateShortcut(.showPopover, binding: nil)
        reloaded = AppModel(startServices: false, preferences: preferences)
        XCTAssertNil(reloaded.shortcuts[.showPopover])
        XCTAssertEqual(reloaded.shortcuts[.first], ShortcutBinding.defaults[.first])
        reloaded.restoreDefaultShortcuts()
        let restored = AppModel(startServices: false, preferences: preferences)
        XCTAssertEqual(restored.shortcuts, ShortcutBinding.defaults)
    }

    @MainActor
    func testLegacyCollisionPreservesExistingNavigationAndExplainsMissingWakeBinding() throws {
        let (name, preferences) = try preferences()
        defer { preferences.removePersistentDomain(forName: name) }
        let wake = try XCTUnwrap(ShortcutBinding.defaults[.showPopover])
        let legacy: [SessionNavigationAction: ShortcutBinding] = [.first: wake]
        preferences.set(try JSONEncoder().encode(legacy), forKey: "sessionShortcuts")
        let model = AppModel(startServices: false, preferences: preferences)
        XCTAssertEqual(model.shortcuts[.first], wake)
        XCTAssertNil(model.shortcuts[.showPopover])
        XCTAssertNotNil(model.shortcutMigrationWarning)
        try ShortcutBinding.validate(model.shortcuts)
    }

    @MainActor
    func testRegisteredWakeDispatchRequestsToggleWithoutOpeningSessionsOrChangingCurrentPage() throws {
        let (name, preferences) = try preferences()
        defer { preferences.removePersistentDomain(forName: name) }
        var sourceOpens = 0
        let model = AppModel(
            startServices: false, preferences: preferences,
            openSource: { _, completion in
                sourceOpens += 1
                completion(nil)
            })
        model.showSettings()
        model.sessionQuery = "fixture"
        var toggleRequests = 0
        model.onPopoverToggleRequested = { toggleRequests += 1 }
        let navigation = model.navigation
        let manager = try GlobalShortcutManager(
            register: { _, _ in ShortcutRegistration {} }, onAction: model.performShortcut)
        try manager.replace(with: model.shortcuts)
        manager.dispatch(.showPopover)
        manager.dispatch(.showPopover)
        XCTAssertEqual(toggleRequests, 2)
        XCTAssertEqual(model.page, .settings)
        XCTAssertEqual(model.sessionQuery, "fixture")
        XCTAssertEqual(model.navigation, navigation)
        XCTAssertEqual(sourceOpens, 0)
        manager.suspend()
        manager.dispatch(.showPopover)
        XCTAssertEqual(toggleRequests, 2)
        var disabled = model.shortcuts
        disabled[.showPopover] = nil
        try manager.replace(with: disabled)
        manager.dispatch(.showPopover)
        XCTAssertEqual(toggleRequests, 2)
    }

    func testOccupiedWakeKeyKeepsPreviouslyRegisteredNavigationActive() throws {
        let wake = try XCTUnwrap(ShortcutBinding.defaults[.showPopover])
        var active: [UInt32: String] = [:]
        var actions: [ShortcutAction] = []
        let manager = try GlobalShortcutManager(
            register: { binding, id in
                if binding == wake { throw ShortcutError.message("合成唤醒键占用") }
                active[id] = binding.identity
                return ShortcutRegistration { active[id] = nil }
            }, onAction: { actions.append($0) })
        let navigation = ShortcutBinding.defaults.filter { $0.key.navigationAction != nil }
        try manager.replace(with: navigation)
        let previous = active
        XCTAssertThrowsError(try manager.replace(with: ShortcutBinding.defaults))
        XCTAssertEqual(active, previous)
        manager.dispatch(.previous)
        manager.dispatch(.showPopover)
        XCTAssertEqual(actions, [.previous])
    }

    @MainActor
    func testVersionTwoAddsCompletionWithoutReenablingWakeAndPreservesExplicitCompletionDisable() throws {
        let (name, preferences) = try preferences()
        defer { preferences.removePersistentDomain(forName: name) }
        let saved: [ShortcutAction: ShortcutBinding] = [.first: ShortcutBinding.defaults[.first]!]
        preferences.set(try JSONEncoder().encode(saved), forKey: "sessionShortcuts")
        preferences.set(2, forKey: "shortcutSchemaVersion")
        var model = AppModel(startServices: false, preferences: preferences)
        XCTAssertNil(model.shortcuts[.showPopover])
        XCTAssertEqual(model.shortcuts[.completeCurrent], ShortcutBinding.defaults[.completeCurrent])
        model.updateShortcut(.completeCurrent, binding: nil)
        model = AppModel(startServices: false, preferences: preferences)
        XCTAssertNil(model.shortcuts[.completeCurrent])
        XCTAssertNil(model.shortcuts[.showPopover])
        XCTAssertEqual(model.shortcuts[.first], saved[.first])
    }

    @MainActor
    func testCompletionMigrationCollisionKeepsCustomizedBinding() throws {
        let (name, preferences) = try preferences()
        defer { preferences.removePersistentDomain(forName: name) }
        let binding = try XCTUnwrap(ShortcutBinding.defaults[.completeCurrent])
        preferences.set(try JSONEncoder().encode([ShortcutAction.first: binding]), forKey: "sessionShortcuts")
        preferences.set(2, forKey: "shortcutSchemaVersion")
        let model = AppModel(startServices: false, preferences: preferences)
        XCTAssertEqual(model.shortcuts[.first], binding)
        XCTAssertNil(model.shortcuts[.completeCurrent])
        XCTAssertNotNil(model.shortcutMigrationWarning)
    }

    func testHeldCompletionKeyCannotCompleteMultipleTasksBeforeRelease() throws {
        var actions: [ShortcutAction] = []
        let manager = try GlobalShortcutManager(
            register: { _, _ in ShortcutRegistration {} },
            onAction: { actions.append($0) })
        try manager.replace(with: ShortcutBinding.defaults)
        manager.handle(.completeCurrent, pressed: true)
        manager.handle(.completeCurrent, pressed: true)
        manager.handle(.completeCurrent, pressed: true)
        XCTAssertEqual(actions, [.completeCurrent])
        manager.handle(.completeCurrent, pressed: false)
        manager.handle(.completeCurrent, pressed: true)
        XCTAssertEqual(actions, [.completeCurrent, .completeCurrent])
    }
}
