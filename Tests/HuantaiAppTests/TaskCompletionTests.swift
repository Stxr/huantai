import AppKit
import HuantaiCore
import SwiftUI
import XCTest

@testable import HuantaiApp

final class TaskCompletionTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let root: URL
        let suite: String
        let preferences: UserDefaults
        let store: SessionStore
        var model: AppModel!
        var now: TimeInterval = 100
        var opened: [String] = []
        var openedURLs: [String] = []
        var failedIDs = Set<String>()
        var delaysOpens = false
        var pending: [(Error?) -> Void] = []

        init(count: Int = 3) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "huantai-completion-" + UUID().uuidString)
            suite = "huantai.completion." + UUID().uuidString
            preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
            store = SessionStore(
                dataDirectory: root, codexDirectory: root.appendingPathComponent("codex"),
                botmuxDirectory: root.appendingPathComponent("botmux"),
                deepSeekHarnessDirectory: root.appendingPathComponent("dsh"))
            let sessions = (1...count).map { item in
                let id = String(format: "01234567-89ab-cdef-0123-%012d", item)
                return SessionRecord(
                    id: id, title: "合成任务 \(item)", cwd: "/fixture", source: "Codex",
                    machine: "本机", lastAIReplyAt: Date(timeIntervalSince1970: Double(100 - item)),
                    openURL: SourceOpening.codexURL(sessionID: id))
            }
            let snapshot = IndexSnapshot(sessions: sessions, usage: .init(), sources: [], updatedAt: .now)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try HuantaiJSON.encoder().encode(snapshot).write(to: root.appendingPathComponent("index.json"))
            model = AppModel(
                startServices: false, preferences: preferences,
                openSource: { [weak self] url, callback in
                    guard let self else { return }
                    let id = String(url.path.dropFirst())
                    self.opened.append(id)
                    self.openedURLs.append(url.absoluteString)
                    if self.delaysOpens {
                        self.pending.append(callback)
                    } else {
                        callback(self.failedIDs.contains(id) ? ShortcutError.message("合成打开失败") : nil)
                    }
                }, store: store, uptime: { [weak self] in self?.now ?? 0 })
            model.setFavoritesOnly(false)
            model.snapshot = snapshot
        }

        func cleanup() {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        func setUnavailable(_ index: Int, reason: String) throws {
            model.snapshot.sessions[index].source = "Botmux"
            model.snapshot.sessions[index].openURL = nil
            model.snapshot.sessions[index].openUnavailableReason = reason
            try HuantaiJSON.encoder().encode(model.snapshot).write(
                to: root.appendingPathComponent("index.json"))
        }
    }

    @MainActor
    private func waitFor(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line)
        async throws
    {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("异步流程未完成", file: file, line: line)
    }

    @MainActor
    func testRowControlsChangeStateWithoutOpeningAndPreserveCurrentContext() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = fixture.model.snapshot.sessions[0]
        let second = fixture.model.snapshot.sessions[1]
        fixture.model.openSession(first)
        try await waitFor { fixture.model.navigation.currentID == first.id }
        fixture.model.toggleFavorite(first)
        try await waitFor { fixture.model.snapshot.sessions[0].isFavorite }
        XCTAssertEqual(fixture.opened, [first.id])
        fixture.model.setCompleted(second, value: true)
        try await waitFor { fixture.model.snapshot.sessions[1].isCompleted }
        XCTAssertEqual(fixture.opened, [first.id])
        XCTAssertEqual(fixture.model.navigation.currentID, first.id)
        XCTAssertEqual(fixture.model.toast?.message, "已标为完成")
        fixture.model.performShortcut(.completeCurrent)
        try await waitFor { fixture.opened.count == 2 }
        XCTAssertTrue(fixture.model.snapshot.sessions[0].isCompleted)
        XCTAssertEqual(fixture.opened.last, fixture.model.snapshot.sessions[2].id)
    }

    @MainActor
    func testNativeRowTitleAndStatusControlsAreIndependent() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = fixture.model.snapshot.sessions[0]
        let controller = NSHostingController(
            rootView: SessionRow(session: first, model: fixture.model).frame(width: 430))
        let size = controller.sizeThatFits(in: NSSize(width: 430, height: 300))
        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: size.width, height: size.height),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.orderBack(nil)
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        defer { window.orderOut(nil) }
        try await Task.sleep(nanoseconds: 20_000_000)

        // Deliver only to this test-owned offscreen window; never post desktop input events.
        func click(_ x: CGFloat, _ y: CGFloat) throws {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(
                    NSEvent.mouseEvent(
                        with: type, location: NSPoint(x: x, y: y), modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
                )
                window.sendEvent(event)
            }
        }
        try click(40, size.height - 23)
        try await waitFor { fixture.model.navigation.currentID == first.id }
        XCTAssertEqual(fixture.opened, [first.id])
        try click(5, size.height / 2)
        try click(45, size.height - 50)
        try click(220, size.height - 23)
        try click(330, size.height - 50)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(fixture.opened, [first.id])
        XCTAssertFalse(fixture.model.snapshot.sessions[0].isFavorite)
        XCTAssertFalse(fixture.model.snapshot.sessions[0].isCompleted)
        try click(399, size.height - 26)
        try await waitFor { fixture.model.snapshot.sessions[0].isFavorite }
        XCTAssertEqual(fixture.opened, [first.id])
        try click(399, size.height - 54)
        try await waitFor { fixture.model.snapshot.sessions[0].isCompleted }
        XCTAssertEqual(fixture.opened, [first.id])
        XCTAssertEqual(fixture.model.navigation.currentID, first.id)
        XCTAssertEqual(fixture.model.toast?.message, "已标为完成")
        fixture.model.performShortcut(.completeCurrent)
        XCTAssertEqual(fixture.opened, [first.id])
        XCTAssertFalse(fixture.model.snapshot.sessions[1].isCompleted)
    }

    @MainActor
    func testManualCompletionOfCurrentSessionAndRestoreNeverAdvanceOrRenewShortcutWindow() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = fixture.model.snapshot.sessions[0]
        let last = fixture.model.snapshot.sessions[2]
        fixture.model.openSession(first)
        try await waitFor { fixture.model.navigation.currentID == first.id }
        let navigation = fixture.model.navigation
        fixture.model.setCompleted(first, value: true)
        try await waitFor { fixture.model.snapshot.sessions[0].isCompleted }
        XCTAssertEqual(fixture.opened, [first.id])
        XCTAssertEqual(fixture.model.navigation, navigation)
        XCTAssertTrue(try fixture.store.snapshot().sessions[0].isCompleted)
        XCTAssertFalse(fixture.model.visibleSessions.contains(where: { $0.id == first.id }))
        fixture.model.setCompleted(first, value: false)
        try await waitFor { !fixture.model.snapshot.sessions[0].isCompleted }
        XCTAssertEqual(fixture.opened, [first.id])
        XCTAssertEqual(fixture.model.navigation, navigation)
        fixture.model.performShortcut(.completeCurrent)
        XCTAssertFalse(try fixture.store.snapshot().sessions[0].isCompleted)
        XCTAssertEqual(fixture.opened, [first.id])
        fixture.model.openSession(last)
        try await waitFor { fixture.model.navigation.currentID == last.id }
        fixture.model.performShortcut(.completeCurrent)
        try await waitFor { fixture.model.navigation.currentID == first.id }
        XCTAssertEqual(fixture.opened, [first.id, last.id, first.id])
        XCTAssertTrue(try fixture.store.snapshot().sessions[2].isCompleted)
    }

    @MainActor
    func testShortcutToastReportsOrdinalTitleAndReplyForHistoryNavigation() async throws {
        let fixture = try Fixture(count: 7)
        defer { fixture.cleanup() }
        let seventh = fixture.model.snapshot.sessions[6]
        fixture.model.openSession(seventh)
        fixture.model.navigate(.first)
        fixture.model.navigate(.back)
        try await waitFor { fixture.opened.count == 3 && fixture.model.toast?.session.id == seventh.id }
        let toast = try XCTUnwrap(fixture.model.toast)
        XCTAssertEqual(toast.position, 7)
        XCTAssertEqual(toast.total, 7)
        XCTAssertEqual(toast.session.title, seventh.title)
        XCTAssertEqual(toast.session.lastAIReplyAt, seventh.lastAIReplyAt)
        XCTAssertEqual(toast.completionShortcut, "⇧⌘D")
        XCTAssertEqual(toast.completionDeadline, 115)
    }

    @MainActor
    func testCompleteBeforeDeadlinePersistsAndOpensNextWithUpdatedToastCount() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = fixture.model.snapshot.sessions[0].id
        let second = fixture.model.snapshot.sessions[1].id
        try fixture.store.setFavorite(id: first, value: true)
        fixture.model.navigate(.first)
        try await waitFor { fixture.model.navigation.currentID == first }
        fixture.now = 114.999
        fixture.model.performShortcut(.completeCurrent)
        try await waitFor { fixture.model.navigation.currentID == second }
        XCTAssertEqual(fixture.opened, [first, second])
        XCTAssertEqual(fixture.model.visibleSessions.count, 2)
        XCTAssertTrue(try fixture.store.snapshot().sessions[0].isCompleted)
        XCTAssertTrue(try fixture.store.snapshot().sessions[0].isFavorite)
        XCTAssertEqual(fixture.model.toast?.position, 1)
        XCTAssertEqual(fixture.model.toast?.total, 2)
        XCTAssertTrue(fixture.model.toast?.message.contains("上一项已完成") == true)
        XCTAssertEqual(fixture.model.toast?.completionDeadline, 129.999)
        fixture.model.setShowsCompleted(true)
        XCTAssertEqual(fixture.model.visibleSessions.map(\.id), [first])
    }

    @MainActor
    func testExactlyFifteenSecondsAndWakeShortcutCannotCompleteTask() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.model.navigate(.first)
        try await waitFor { fixture.model.navigation.currentID != nil }
        fixture.now = 115
        fixture.model.performShortcut(.showPopover)
        fixture.model.performShortcut(.completeCurrent)
        XCTAssertTrue(try fixture.store.snapshot().sessions.allSatisfy { !$0.isCompleted })
        XCTAssertEqual(fixture.opened.count, 1)
        XCTAssertTrue(fixture.model.notice?.contains("15 秒") == true)
    }

    @MainActor
    func testSwitchInFlightAndFailedSwitchCannotCreateCompletionWindow() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.delaysOpens = true
        fixture.model.navigate(.first)
        fixture.model.performShortcut(.completeCurrent)
        XCTAssertTrue(try fixture.store.snapshot().sessions.allSatisfy { !$0.isCompleted })
        XCTAssertTrue(fixture.model.notice?.contains("正在切换") == true)
        fixture.pending.removeFirst()(ShortcutError.message("合成打开失败"))
        try await waitFor { fixture.model.notice == "合成打开失败" }
        fixture.model.performShortcut(.completeCurrent)
        XCTAssertNil(fixture.model.navigation.currentID)
        XCTAssertTrue(try fixture.store.snapshot().sessions.allSatisfy { !$0.isCompleted })
    }

    @MainActor
    func testSaveFailureDoesNotJumpAndCanRetryWithinOriginalWindow() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.model.navigate(.first)
        try await waitFor { fixture.model.navigation.currentID != nil }
        let preferenceURL = fixture.root.appendingPathComponent("preferences.json")
        try FileManager.default.createDirectory(at: preferenceURL, withIntermediateDirectories: true)
        fixture.model.performShortcut(.completeCurrent)
        try await waitFor { fixture.model.notice?.hasPrefix("状态保存失败") == true }
        XCTAssertEqual(fixture.opened.count, 1)
        XCTAssertTrue(fixture.model.snapshot.sessions.allSatisfy { !$0.isCompleted })
        try FileManager.default.removeItem(at: preferenceURL)
        fixture.now = 114
        fixture.model.performShortcut(.completeCurrent)
        try await waitFor { fixture.opened.count == 2 }
        try await waitFor { fixture.model.navigation.currentID == fixture.model.snapshot.sessions[1].id }
    }

    @MainActor
    func testLastTaskWrapsToFirstAndCompletedHistoryIsSkipped() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let last = fixture.model.snapshot.sessions[2]
        let first = fixture.model.snapshot.sessions[0]
        fixture.model.openSession(last)
        try await waitFor { fixture.model.navigation.currentID == last.id }
        fixture.model.performShortcut(.completeCurrent)
        try await waitFor { fixture.model.navigation.currentID == first.id }
        fixture.model.navigate(.back)
        XCTAssertEqual(fixture.opened, [last.id, first.id])
        XCTAssertEqual(fixture.model.navigation.currentID, first.id)
    }

    @MainActor
    func testCompletingOnlyFilteredTaskStopsAndRestoreKeepsFavorite() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = fixture.model.snapshot.sessions[0]
        fixture.model.sessionQuery = first.title
        fixture.model.navigate(.first)
        try await waitFor { fixture.model.navigation.currentID == first.id }
        fixture.model.performShortcut(.completeCurrent)
        try await waitFor { fixture.model.snapshot.sessions[0].isCompleted }
        XCTAssertTrue(fixture.model.visibleSessions.isEmpty)
        XCTAssertEqual(fixture.opened.count, 1)
        XCTAssertTrue(fixture.model.toast?.message.contains("没有下一条") == true)
        fixture.model.setShowsCompleted(true)
        XCTAssertEqual(fixture.model.visibleSessions.count, 1)
        fixture.model.setCompleted(fixture.model.visibleSessions[0], value: false)
        try await waitFor { !fixture.model.snapshot.sessions[0].isCompleted }
        fixture.model.setShowsCompleted(false)
        XCTAssertEqual(fixture.model.visibleSessions.count, 1)
        XCTAssertEqual(fixture.opened.count, 1)
    }

    @MainActor
    func testNextOpenFailureKeepsCompletionAndDoesNotMarkFailedTarget() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = fixture.model.snapshot.sessions[0].id
        let second = fixture.model.snapshot.sessions[1].id
        fixture.failedIDs.insert(second)
        fixture.model.navigate(.first)
        try await waitFor { fixture.model.navigation.currentID == first }
        fixture.model.performShortcut(.completeCurrent)
        try await waitFor { fixture.model.notice == "合成打开失败" }
        XCTAssertTrue(fixture.model.snapshot.sessions[0].isCompleted)
        XCTAssertFalse(fixture.model.snapshot.sessions[1].isCompleted)
        XCTAssertEqual(fixture.model.navigation.currentID, first)
        XCTAssertTrue(fixture.model.toast?.message.contains("上一项已完成") == true)
        fixture.model.performShortcut(.completeCurrent)
        XCTAssertFalse(try fixture.store.snapshot().sessions[1].isCompleted)
    }

    @MainActor
    func testCompletionUsesCurrentSessionEvenWhenItIsOutsideCurrentFavoriteFilter() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = fixture.model.snapshot.sessions[0]
        let second = fixture.model.snapshot.sessions[1]
        try fixture.store.setFavorite(id: second.id, value: true)
        fixture.model.snapshot = try fixture.store.snapshot()
        fixture.model.openSession(first)
        try await waitFor { fixture.model.navigation.currentID == first.id }
        fixture.model.setFavoritesOnly(true)
        fixture.model.performShortcut(.completeCurrent)
        try await waitFor { fixture.model.navigation.currentID == second.id }
        XCTAssertTrue(fixture.model.snapshot.sessions[0].isCompleted)
        XCTAssertFalse(fixture.model.snapshot.sessions[1].isCompleted)
        XCTAssertEqual(fixture.model.toast?.total, 1)
    }

    @MainActor
    func testUnavailableThreadReportsSpecificReasonWithoutOpeningOrGrantingCompletion() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let reason = "Botmux 话题定位协议尚未核验；需要对应话题的已核验链接"
        try fixture.setUnavailable(0, reason: reason)
        fixture.model.navigate(.first)
        XCTAssertTrue(fixture.opened.isEmpty)
        XCTAssertNil(fixture.model.navigation.currentID)
        let toast = try XCTUnwrap(fixture.model.toast)
        XCTAssertEqual(toast.kind, .warning)
        XCTAssertEqual(toast.message, "未能打开：" + reason)
        XCTAssertNil(toast.completionDeadline)
        XCTAssertFalse(toast.showsCompletionHint)
        fixture.model.performShortcut(.completeCurrent)
        XCTAssertTrue(try fixture.store.snapshot().sessions.allSatisfy { !$0.isCompleted })
    }

    @MainActor
    func testCompletionWithUnavailableSuccessorKeepsSavedStateAndReportsTargetReason() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let reason = "合成话题缺少已核验的精准链接"
        try fixture.setUnavailable(1, reason: reason)
        let first = fixture.model.snapshot.sessions[0].id
        let second = fixture.model.snapshot.sessions[1].id
        fixture.model.navigate(.first)
        try await waitFor { fixture.model.navigation.currentID == first }
        fixture.model.performShortcut(.completeCurrent)
        try await waitFor { fixture.model.toast?.session.id == second }
        XCTAssertEqual(fixture.model.toast?.kind, .warning)
        XCTAssertEqual(fixture.model.toast?.message, "上一项已完成 · 下一项未能打开：" + reason)
        XCTAssertNil(fixture.model.toast?.completionDeadline)
        XCTAssertTrue(try fixture.store.snapshot().sessions[0].isCompleted)
        XCTAssertFalse(try fixture.store.snapshot().sessions[1].isCompleted)
        XCTAssertEqual(fixture.opened, [first])
        XCTAssertEqual(fixture.model.navigation.currentID, first)
    }

    @MainActor
    func testUndoCompletionRestoresAndReturnsOutsideFilterAfterDeadline() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = fixture.model.snapshot.sessions[0]
        let second = fixture.model.snapshot.sessions[1]
        try fixture.store.setFavorite(id: first.id, value: true)
        fixture.model.navigate(.first)
        try await waitFor { fixture.model.navigation.currentID == first.id }
        fixture.model.performShortcut(.completeCurrent)
        try await waitFor { fixture.model.navigation.currentID == second.id }
        XCTAssertTrue(fixture.model.toast?.message.contains("⇧⌘Z") == true)
        fixture.now = 1000
        fixture.model.sessionQuery = second.title
        fixture.model.performShortcut(.undoCompletion)
        try await waitFor { fixture.model.navigation.currentID == first.id }
        let restored = try fixture.store.snapshot().sessions[0]
        XCTAssertFalse(restored.isCompleted)
        XCTAssertTrue(restored.isFavorite)
        XCTAssertEqual(restored.lastAIReplyAt, first.lastAIReplyAt)
        XCTAssertEqual(fixture.opened, [first.id, second.id, first.id])
        XCTAssertEqual(fixture.model.sessionQuery, second.title)
        XCTAssertEqual(fixture.model.toast?.message, "已撤回完成 · 已返回会话")
        XCTAssertEqual(fixture.model.toast?.position, 1)
        XCTAssertEqual(fixture.model.toast?.completionDeadline, 1015)
        fixture.model.navigate(.back)
        try await waitFor { fixture.model.navigation.currentID == second.id }
        fixture.model.navigate(.forward)
        try await waitFor { fixture.model.navigation.currentID == first.id }
        let count = fixture.opened.count
        fixture.model.performShortcut(.undoCompletion)
        XCTAssertEqual(fixture.model.notice, "没有可撤回的完成记录。")
        XCTAssertEqual(fixture.opened.count, count)
    }

    @MainActor
    func testImmediateUndoWaitsForCompletionSaveAndNextOpening() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = fixture.model.snapshot.sessions[0].id
        let second = fixture.model.snapshot.sessions[1].id
        fixture.model.navigate(.first)
        try await waitFor { fixture.model.navigation.currentID == first }
        fixture.delaysOpens = true
        fixture.model.performShortcut(.completeCurrent)
        fixture.model.performShortcut(.undoCompletion)
        try await waitFor { fixture.pending.count == 1 }
        XCTAssertTrue(try fixture.store.snapshot().sessions[0].isCompleted)
        XCTAssertEqual(fixture.opened, [first, second])
        fixture.pending.removeFirst()(nil)
        try await waitFor { fixture.pending.count == 1 }
        XCTAssertFalse(try fixture.store.snapshot().sessions[0].isCompleted)
        XCTAssertEqual(fixture.opened, [first, second, first])
        XCTAssertEqual(fixture.model.navigation.currentID, second)
        fixture.pending.removeFirst()(nil)
        try await waitFor { fixture.model.navigation.currentID == first }
        XCTAssertEqual(fixture.model.toast?.message, "已撤回完成 · 已返回会话")
    }

    @MainActor
    func testConsecutiveUndoRestoresCompletionsInReverseOrder() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let ids = fixture.model.snapshot.sessions.map(\.id)
        fixture.model.navigate(.first)
        try await waitFor { fixture.model.navigation.currentID == ids[0] }
        fixture.model.performShortcut(.completeCurrent)
        try await waitFor { fixture.model.navigation.currentID == ids[1] }
        fixture.model.performShortcut(.completeCurrent)
        try await waitFor { fixture.model.navigation.currentID == ids[2] }
        fixture.model.performShortcut(.undoCompletion)
        fixture.model.performShortcut(.undoCompletion)
        try await waitFor { fixture.model.navigation.currentID == ids[0] }
        XCTAssertTrue(try fixture.store.snapshot().sessions.allSatisfy { !$0.isCompleted })
        XCTAssertEqual(fixture.opened, [ids[0], ids[1], ids[2], ids[1], ids[0]])
    }

    @MainActor
    func testUndoOnlyTaskReturnsAndAllowsCompletionAgain() async throws {
        let fixture = try Fixture(count: 1)
        defer { fixture.cleanup() }
        fixture.model.navigate(.first)
        try await waitFor { fixture.model.navigation.currentID != nil }
        fixture.model.performShortcut(.completeCurrent)
        try await waitFor { fixture.model.snapshot.sessions[0].isCompleted }
        fixture.model.performShortcut(.undoCompletion)
        try await waitFor { fixture.model.toast?.message == "已撤回完成 · 已返回会话" }
        XCTAssertEqual(fixture.opened.count, 2)
        XCTAssertEqual(fixture.model.visibleSessions.count, 1)
        fixture.model.performShortcut(.completeCurrent)
        try await waitFor { fixture.model.snapshot.sessions[0].isCompleted }
        fixture.model.performShortcut(.undoCompletion)
        try await waitFor { !fixture.model.snapshot.sessions[0].isCompleted && fixture.opened.count == 3 }
    }

    @MainActor
    func testUndoRemainsAvailableAfterNextOpenFails() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = fixture.model.snapshot.sessions[0].id
        fixture.failedIDs.insert(fixture.model.snapshot.sessions[1].id)
        fixture.model.navigate(.first)
        try await waitFor { fixture.model.navigation.currentID == first }
        fixture.model.performShortcut(.completeCurrent)
        try await waitFor { fixture.model.notice == "合成打开失败" }
        fixture.model.performShortcut(.undoCompletion)
        try await waitFor { fixture.model.toast?.message == "已撤回完成 · 已返回会话" }
        XCTAssertFalse(try fixture.store.snapshot().sessions[0].isCompleted)
        XCTAssertEqual(fixture.opened.last, first)
        XCTAssertEqual(fixture.model.navigation.currentID, first)
    }

    @MainActor
    func testImmediateUndoSurvivesFailedOrUnavailableNextOpen() async throws {
        for missingLink in [false, true] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let first = fixture.model.snapshot.sessions[0].id
            if missingLink {
                try fixture.setUnavailable(1, reason: "合成来源缺少链接")
            } else {
                fixture.failedIDs.insert(fixture.model.snapshot.sessions[1].id)
            }
            fixture.model.navigate(.first)
            try await waitFor { fixture.model.navigation.currentID == first }
            fixture.model.performShortcut(.completeCurrent)
            fixture.model.performShortcut(.undoCompletion)
            try await waitFor { fixture.model.toast?.message == "已撤回完成 · 已返回会话" }
            XCTAssertFalse(try fixture.store.snapshot().sessions[0].isCompleted)
            XCTAssertEqual(fixture.model.navigation.currentID, first)
            XCTAssertEqual(fixture.opened.last, first)
        }
    }

    @MainActor
    func testUndoSaveFailurePreservesRecordAndCanRetry() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = fixture.model.snapshot.sessions[0].id
        let second = fixture.model.snapshot.sessions[1].id
        fixture.model.navigate(.first)
        try await waitFor { fixture.model.navigation.currentID == first }
        fixture.model.performShortcut(.completeCurrent)
        try await waitFor { fixture.model.navigation.currentID == second }
        let preferenceURL = fixture.root.appendingPathComponent("preferences.json")
        let backupURL = fixture.root.appendingPathComponent("preferences-backup.json")
        try FileManager.default.moveItem(at: preferenceURL, to: backupURL)
        try FileManager.default.createDirectory(at: preferenceURL, withIntermediateDirectories: true)
        fixture.model.performShortcut(.undoCompletion)
        try await waitFor { fixture.model.notice?.hasPrefix("状态保存失败") == true }
        XCTAssertEqual(fixture.opened, [first, second])
        XCTAssertTrue(fixture.model.snapshot.sessions[0].isCompleted)
        try FileManager.default.removeItem(at: preferenceURL)
        try FileManager.default.moveItem(at: backupURL, to: preferenceURL)
        fixture.model.performShortcut(.undoCompletion)
        try await waitFor { fixture.model.navigation.currentID == first }
        XCTAssertFalse(try fixture.store.snapshot().sessions[0].isCompleted)
    }

    @MainActor
    func testUndoOpenFailureKeepsRestoredStateAndCurrentNavigation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = fixture.model.snapshot.sessions[0].id
        let second = fixture.model.snapshot.sessions[1].id
        fixture.model.navigate(.first)
        try await waitFor { fixture.model.navigation.currentID == first }
        fixture.model.performShortcut(.completeCurrent)
        try await waitFor { fixture.model.navigation.currentID == second }
        fixture.failedIDs.insert(first)
        fixture.model.performShortcut(.undoCompletion)
        try await waitFor { fixture.model.notice == "合成打开失败" }
        XCTAssertFalse(try fixture.store.snapshot().sessions[0].isCompleted)
        XCTAssertEqual(fixture.model.navigation.currentID, second)
        XCTAssertEqual(fixture.model.toast?.message, "已撤回完成 · 会话打开失败：合成打开失败")
        XCTAssertNil(fixture.model.toast?.completionDeadline)
        fixture.model.performShortcut(.completeCurrent)
        XCTAssertFalse(try fixture.store.snapshot().sessions[1].isCompleted)
        XCTAssertEqual(fixture.opened.count, 3)
    }

    @MainActor
    func testUndoTracksNativeManualCompletionAndSkipsAlreadyRestoredEntries() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = fixture.model.snapshot.sessions[0]
        let second = fixture.model.snapshot.sessions[1]
        fixture.model.setCompleted(first, value: true)
        try await waitFor { fixture.model.snapshot.sessions[0].isCompleted }
        fixture.model.setCompleted(second, value: true)
        try await waitFor { fixture.model.snapshot.sessions[1].isCompleted }
        XCTAssertTrue(fixture.opened.isEmpty)
        // External restore can happen before the app's next periodic snapshot refresh.
        try fixture.store.setCompleted(id: second.id, value: false)
        fixture.model.performShortcut(.undoCompletion)
        try await waitFor { fixture.model.navigation.currentID == first.id }
        XCTAssertTrue(try fixture.store.snapshot().sessions.allSatisfy { !$0.isCompleted })
        XCTAssertEqual(fixture.opened, [first.id])
        fixture.model.performShortcut(.undoCompletion)
        XCTAssertEqual(fixture.model.notice, "没有可撤回的完成记录。")
    }

    @MainActor
    func testHarnessApplicationOpenAllowsCompletionAndUndoReopensApplication() async throws {
        let fixture = try Fixture(count: 2)
        defer { fixture.cleanup() }
        fixture.model.snapshot.sessions[0].id = "dsh:session-fixture"
        fixture.model.snapshot.sessions[0].source = "DeepSeek Harness"
        fixture.model.snapshot.sessions[0].openURL = SourceOpening.deepSeekHarnessURL
        try HuantaiJSON.encoder().encode(fixture.model.snapshot).write(
            to: fixture.root.appendingPathComponent("index.json"))
        let first = fixture.model.snapshot.sessions[0]
        let second = fixture.model.snapshot.sessions[1]
        fixture.model.openSession(first)
        try await waitFor { fixture.model.navigation.currentID == first.id }
        XCTAssertEqual(fixture.model.toast?.message, "已打开 DeepSeek Harness")
        XCTAssertNotNil(fixture.model.toast?.completionDeadline)
        fixture.model.performShortcut(.completeCurrent)
        try await waitFor { fixture.model.navigation.currentID == second.id }
        XCTAssertTrue(try fixture.store.snapshot().sessions[0].isCompleted)
        fixture.now += 20
        fixture.model.performShortcut(.undoCompletion)
        try await waitFor { fixture.model.navigation.currentID == first.id }
        XCTAssertEqual(
            fixture.openedURLs,
            [SourceOpening.deepSeekHarnessURL, second.openURL!, SourceOpening.deepSeekHarnessURL])
        XCTAssertFalse(try fixture.store.snapshot().sessions[0].isCompleted)
        XCTAssertEqual(fixture.model.toast?.message, "已撤回完成 · 已打开 DeepSeek Harness")
        XCTAssertNotNil(fixture.model.toast?.completionDeadline)
    }

    @MainActor
    func testUndoSkipsMissingSessionsAndManualRestoreRemovesUndoRecord() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = fixture.model.snapshot.sessions[0]
        let second = fixture.model.snapshot.sessions[1]
        fixture.model.setCompleted(first, value: true)
        try await waitFor { fixture.model.snapshot.sessions[0].isCompleted }
        fixture.model.setCompleted(second, value: true)
        try await waitFor { fixture.model.snapshot.sessions[1].isCompleted }
        fixture.model.snapshot.sessions.removeAll { $0.id == second.id }
        try HuantaiJSON.encoder().encode(fixture.model.snapshot).write(
            to: fixture.root.appendingPathComponent("index.json"))
        fixture.model.performShortcut(.undoCompletion)
        try await waitFor { fixture.model.navigation.currentID == first.id }
        XCTAssertFalse(try fixture.store.snapshot().sessions[0].isCompleted)
        fixture.model.setCompleted(first, value: true)
        try await waitFor { fixture.model.snapshot.sessions[0].isCompleted }
        fixture.model.setCompleted(first, value: false)
        try await waitFor { !fixture.model.snapshot.sessions[0].isCompleted }
        fixture.model.performShortcut(.undoCompletion)
        XCTAssertEqual(fixture.model.notice, "没有可撤回的完成记录。")
        XCTAssertEqual(fixture.opened, [first.id])
    }

    @MainActor
    func testToastPanelCannotTakeFocusAndAllowsClicksThroughToSourceApplication() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let controller = SessionToastController(model: fixture.model, observeChanges: false)
        XCTAssertTrue(controller.panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(controller.panel.canBecomeKey)
        XCTAssertFalse(controller.panel.canBecomeMain)
        XCTAssertTrue(controller.panel.ignoresMouseEvents)
        XCTAssertFalse(controller.panel.isOpaque)
        XCTAssertFalse(controller.panel.hidesOnDeactivate)
        XCTAssertTrue(controller.panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertFalse(controller.panel.isVisible)
    }

    @MainActor
    func testSourceSettingsRefreshAndReloadWithoutResettingOtherSource() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        XCTAssertTrue(fixture.model.sourceEnabled(.codex))
        XCTAssertTrue(fixture.model.sourceEnabled(.deepSeekHarness))
        fixture.model.setSessionSource(.deepSeekHarness, enabled: false)
        try await waitFor { !fixture.model.savingSourceConfiguration }
        XCTAssertFalse(fixture.model.sourceEnabled(.deepSeekHarness))
        XCTAssertTrue(fixture.model.sourceEnabled(.codex))
        let path = fixture.root.appendingPathComponent("alternate-dsh").path
        fixture.model.setSessionDirectory(.deepSeekHarness, path: path)
        try await waitFor { !fixture.model.savingSourceConfiguration }
        XCTAssertEqual(fixture.model.sessionDirectory(.deepSeekHarness), path)
        let reloaded = AppModel(startServices: false, preferences: fixture.preferences, store: fixture.store)
        XCTAssertFalse(reloaded.sourceEnabled(.deepSeekHarness))
        XCTAssertEqual(reloaded.sessionDirectory(.deepSeekHarness), path)
        XCTAssertTrue(reloaded.sourceEnabled(.codex))
        fixture.model.setSessionDirectory(.deepSeekHarness, path: "relative")
        try await waitFor { !fixture.model.savingSourceConfiguration }
        XCTAssertEqual(fixture.model.sessionDirectory(.deepSeekHarness), path)
        XCTAssertTrue(fixture.model.notice?.contains("失败") == true)
    }

    func testToastFitsBottomRightOnOffsetAndSmallDisplays() {
        for screen in [
            NSRect(x: 0, y: 30, width: 1440, height: 870),
            NSRect(x: -800, y: -480, width: 800, height: 480),
            NSRect(x: 1440, y: 0, width: 320, height: 300),
        ] {
            let frame = SessionToastLayout.frame(in: screen)
            XCTAssertTrue(screen.contains(frame))
            XCTAssertEqual(frame.maxX, screen.maxX - 20)
            XCTAssertEqual(frame.minY, screen.minY + 20)
        }
    }

    @MainActor
    func testToastRendersProductionLightAndDarkComponents() throws {
        guard let path = ProcessInfo.processInfo.environment["HUANTAI_RENDER_TOAST_DIR"] else { return }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let session = SessionRecord(
            id: "fixture", title: "优化会话排序与增量扫描，检查最后回复时间", cwd: "/fixture",
            source: "Codex", machine: "本机", lastAIReplyAt: Date().addingTimeInterval(-180))
        let toast = SessionToast(
            session: session, position: 7, total: 24, message: "已切换会话",
            completionShortcut: "⇧⌘D", completionDeadline: ProcessInfo.processInfo.systemUptime + 15)
        let unavailable = SessionToast(
            session: SessionRecord(
                id: "fixture-thread", title: "合成话题会话", cwd: "/fixture",
                source: "Botmux", machine: "本机", lastAIReplyAt: Date().addingTimeInterval(-7200)),
            message: "未能打开：Botmux 话题定位协议尚未核验；需要对应话题的已核验链接", kind: .warning)
        for theme in ["light", "dark"] {
            for (name, value) in [("toast", toast), ("toast-unavailable", unavailable)] {
                let renderer = ImageRenderer(
                    content: SessionToastView(toast: value).frame(width: 360, height: 184)
                        .environment(\.colorScheme, theme == "dark" ? .dark : .light))
                renderer.scale = 2
                let rendered = try XCTUnwrap(renderer.nsImage)
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(rendered.tiffRepresentation)))
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent("\(name)-\(theme).png"))
            }
        }
    }
}
