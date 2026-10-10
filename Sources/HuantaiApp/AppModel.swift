import AppKit
import Foundation
import HuantaiCore
import HuantaiWeb
import SwiftUI

enum PopoverPage { case sessions, settings }

final class AppModel: ObservableObject {
    static let scanInterval: TimeInterval = 5
    private static let shortcutSchemaVersion = 4
    let loginItem: LoginItemManager
    let taskHook: TaskHookManager
    let isTestEnvironment = ProcessInfo.processInfo.environment["HUANTAI_TEST_MODE"] == "1"
    @Published var snapshot = IndexSnapshot(
        sessions: [], usage: UsageSummary(), sources: [], updatedAt: Date())
    @Published var refreshing = false
    @Published var notice: String?
    @Published var webReady = false
    @Published private(set) var appearance: String
    @Published private(set) var menuBarIconMode: MenuBarIconMode
    @Published private(set) var favoritesOnly: Bool
    @Published var sessionQuery = ""
    @Published private(set) var shortcuts: [ShortcutAction: ShortcutBinding]
    @Published private(set) var shortcutStatus = "全局快捷键尚未启用"
    @Published private(set) var recordingAction: ShortcutAction?
    @Published private(set) var shortcutMigrationWarning: String?
    @Published private(set) var navigation = SessionNavigation()
    @Published private(set) var page = PopoverPage.sessions
    @Published private(set) var showsCompleted = false
    @Published private(set) var toast: SessionToast?
    @Published private(set) var sourceConfiguration: StoreConfiguration
    @Published private(set) var savingSourceConfiguration = false
    var onSettingsRequested: (() -> Void)?
    var onPopoverToggleRequested: (() -> Void)?
    var onShortcutConfiguration: (([ShortcutAction: ShortcutBinding]) throws -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?
    private let openSource: (URL, @escaping (Error?) -> Void) -> Void
    private enum OpenRequest {
        case direct(String)
        case shortcut(SessionNavigationAction)
        case afterCompletion(String)
        case undoCompletion
        case afterUndoCompletion(String)
    }
    private enum CompletionRequest {
        case manual(Bool)
        case shortcut
        case undo

        var value: Bool {
            if case .manual(let value) = self { return value }
            return !isUndo
        }

        var advancesToNext: Bool {
            if case .shortcut = self { return true }
            return false
        }

        var isUndo: Bool {
            if case .undo = self { return true }
            return false
        }
    }
    private var openRequests: [OpenRequest] = []
    private var openingSession = false
    private let preferences: UserDefaults
    private let store: SessionStore
    private let uptime: () -> TimeInterval
    private var completionWindow: CompletionWindow?
    private var completionHistory: [String] = []
    private let queue = DispatchQueue(label: "huantai.app-index", qos: .utility)
    private let usageQueue = DispatchQueue(label: "huantai.account-usage", qos: .utility)
    private var server: LocalWebServer?
    private var timer: Timer?
    private var usageTimer: Timer?
    private var usageRefreshing = false
    private let servicesEnabled: Bool

    init(
        startServices: Bool = true, preferences: UserDefaults = .standard,
        openSource: @escaping (URL, @escaping (Error?) -> Void) -> Void = SourceOpening.open,
        store: SessionStore = SessionStore(),
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        loginItem: LoginItemManager = LoginItemManager()
    ) {
        self.loginItem = loginItem
        self.preferences = preferences
        self.openSource = openSource
        self.store = store
        let initialSourceConfiguration = (try? store.configuration()) ?? StoreConfiguration()
        sourceConfiguration = initialSourceConfiguration
        taskHook = TaskHookManager(
            dataDirectory: store.dataDirectory,
            sources: TaskHookSources(
                configuration: initialSourceConfiguration,
                codexHome: store.codexDirectory, deepSeekHarnessHome: store.deepSeekHarnessDirectory),
            startServices: startServices)
        self.uptime = uptime
        let saved = preferences.string(forKey: "appearance") ?? "system"
        appearance = ["system", "light", "dark"].contains(saved) ? saved : "system"
        menuBarIconMode =
            preferences.string(forKey: "menuBarIconMode")
            .flatMap(MenuBarIconMode.init(rawValue:)) ?? .daily
        favoritesOnly =
            preferences.object(forKey: "favoritesOnly") == nil
            ? true : preferences.bool(forKey: "favoritesOnly")
        if let data = preferences.data(forKey: "sessionShortcuts"),
            var saved = try? JSONDecoder().decode(
                [ShortcutAction: ShortcutBinding].self, from: data),
            (try? ShortcutBinding.validate(saved)) != nil
        {
            // Each schema only adds its new actions, preserving earlier intentional disables.
            let version = preferences.integer(forKey: "shortcutSchemaVersion")
            if version < Self.shortcutSchemaVersion {
                let additions: [ShortcutAction] =
                    (version < 2 ? [.showPopover] : [])
                    + (version < 3 ? [.completeCurrent] : []) + [.undoCompletion]
                for action in additions where saved[action] == nil {
                    guard let binding = ShortcutBinding.defaults[action] else { continue }
                    if saved.values.contains(where: { $0.identity == binding.identity }) {
                        shortcutMigrationWarning = "默认\(action.title)快捷键与已有键位重复。原键位已保留，请在设置中选择其他组合。"
                    } else {
                        saved[action] = binding
                    }
                }
                if let migrated = try? JSONEncoder().encode(saved) {
                    preferences.set(migrated, forKey: "sessionShortcuts")
                    preferences.set(Self.shortcutSchemaVersion, forKey: "shortcutSchemaVersion")
                }
            }
            shortcuts = saved
        } else {
            shortcuts = ShortcutBinding.defaults
        }
        servicesEnabled = startServices
        guard startServices else { return }
        refresh()
        if !isTestEnvironment { refreshUsage() }
        queue.async { [weak self] in
            guard let self else { return }
            let server = LocalWebServer(store: self.store)
            do {
                try server.start()
                self.server = server
                DispatchQueue.main.async { self.webReady = true }
            } catch {
                DispatchQueue.main.async { self.notice = error.localizedDescription }
            }
        }
        let scanTimer = Timer(timeInterval: Self.scanInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(scanTimer, forMode: .common)
        timer = scanTimer
        usageTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            guard self?.isTestEnvironment == false else { return }
            self?.refreshUsage()
        }
    }

    func setAppearance(_ value: String) {
        guard ["system", "light", "dark"].contains(value) else { return }
        preferences.set(value, forKey: "appearance")
        appearance = value
    }

    func setMenuBarIconMode(_ value: MenuBarIconMode) {
        preferences.set(value.rawValue, forKey: "menuBarIconMode")
        menuBarIconMode = value
    }

    var visibleSessions: [SessionRecord] {
        snapshot.filteredSessions(
            query: sessionQuery, favoritesOnly: favoritesOnly, includeCompleted: showsCompleted
        )
        .filter { !showsCompleted || $0.isCompleted }
    }

    private var navigableSessions: [SessionRecord] {
        snapshot.filteredSessions(query: sessionQuery, favoritesOnly: favoritesOnly)
    }

    func setShowsCompleted(_ value: Bool) { showsCompleted = value }

    func setFavoritesOnly(_ value: Bool) {
        preferences.set(value, forKey: "favoritesOnly")
        favoritesOnly = value
    }

    func showSettings() {
        loginItem.refresh()
        page = .settings
        onSettingsRequested?()
    }

    var taskHookSources: TaskHookSources {
        TaskHookSources(
            configuration: sourceConfiguration, codexHome: store.codexDirectory,
            deepSeekHarnessHome: store.deepSeekHarnessDirectory)
    }

    func sourceEnabled(_ source: SessionSource) -> Bool {
        source == .codex ? sourceConfiguration.codexEnabled : sourceConfiguration.deepSeekHarnessEnabled
    }

    func sessionDirectory(_ source: SessionSource) -> String {
        source == .codex
            ? sourceConfiguration.codexHome ?? store.codexDirectory.path
            : sourceConfiguration.deepSeekHarnessHome ?? store.deepSeekHarnessDirectory.path
    }

    func setSessionSource(_ source: SessionSource, enabled: Bool) {
        updateSessionSources { try self.store.setSessionSource(source, enabled: enabled) }
    }

    func setSessionDirectory(_ source: SessionSource, path: String?) {
        updateSessionSources { try self.store.setSessionDirectory(source, path: path) }
    }

    func saveRemoteTarget(id: String?, name: String, host: String, root: String) {
        let target = RemoteTarget(
            id: id ?? UUID().uuidString, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            sessionRoot: root.trimmingCharacters(in: .whitespacesAndNewlines))
        updateSessionSources { try self.store.setRemoteTarget(target) }
    }

    func removeRemoteTarget(id: String) {
        updateSessionSources { try self.store.removeRemoteTarget(id: id) }
    }

    func chooseSessionDirectory(_ source: SessionSource) {
        let panel = NSOpenPanel()
        panel.title = "选择 \(source.title) 数据目录"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: sessionDirectory(source), isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url { setSessionDirectory(source, path: url.path) }
    }

    private func updateSessionSources(_ operation: @escaping () throws -> Void) {
        guard !savingSourceConfiguration else { return }
        savingSourceConfiguration = true
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try operation()
                let configuration = try self.store.configuration()
                DispatchQueue.main.async {
                    self.sourceConfiguration = configuration
                    self.taskHook.updateSources(self.taskHookSources)
                }
                let snapshot = try self.store.refresh()
                DispatchQueue.main.async {
                    self.snapshot = snapshot
                    self.notice = nil
                    self.savingSourceConfiguration = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.sourceConfiguration = (try? self.store.configuration()) ?? self.sourceConfiguration
                    self.taskHook.updateSources(self.taskHookSources)
                    self.notice = "来源设置保存或刷新失败：\(error.localizedDescription)"
                    self.savingSourceConfiguration = false
                }
            }
        }
    }

    func showSessions() {
        endRecording()
        page = .sessions
    }

    func popoverClosed() { endRecording() }

    func updateShortcut(_ action: ShortcutAction, binding: ShortcutBinding?) {
        var proposed = shortcuts
        proposed[action] = binding
        if applyShortcuts(proposed) { endRecording() }
    }

    func restoreDefaultShortcuts() {
        if applyShortcuts(ShortcutBinding.defaults) { endRecording() }
    }

    @discardableResult
    private func applyShortcuts(_ proposed: [ShortcutAction: ShortcutBinding]) -> Bool {
        do {
            try ShortcutBinding.validate(proposed)
            let data = try JSONEncoder().encode(proposed)
            try onShortcutConfiguration?(proposed)
            preferences.set(data, forKey: "sessionShortcuts")
            preferences.set(Self.shortcutSchemaVersion, forKey: "shortcutSchemaVersion")
            shortcuts = proposed
            shortcutMigrationWarning = nil
            shortcutStatus = proposed.isEmpty ? "全局快捷键已关闭" : "已保存 \(proposed.count) 项全局快捷键"
            return true
        } catch {
            shortcutStatus = error.localizedDescription
            return false
        }
    }

    func reportShortcutStatus(_ value: String) { shortcutStatus = value }

    func beginRecording(_ action: ShortcutAction) {
        if recordingAction == action {
            endRecording()
            return
        }
        let wasRecording = recordingAction != nil
        recordingAction = action
        if !wasRecording { onRecordingChanged?(true) }
    }

    func endRecording() {
        guard recordingAction != nil else { return }
        recordingAction = nil
        onRecordingChanged?(false)
    }

    deinit {
        timer?.invalidate()
        usageTimer?.invalidate()
    }

    func refreshUsage() {
        guard servicesEnabled else { return }
        guard !isTestEnvironment else {
            notice = "测试模式使用合成数据，账户额度读取未启用。"
            return
        }
        guard !usageRefreshing else { return }
        usageRefreshing = true
        usageQueue.async { [weak self] in
            guard let self else { return }
            do { _ = try self.store.refreshUsage() } catch {
                DispatchQueue.main.async { self.notice = error.localizedDescription }
            }
            let result = try? self.store.snapshot()
            DispatchQueue.main.async {
                // Account refreshes must not replace newer session ordering from the scan queue.
                if let result { self.snapshot.usage = result.usage }
                self.usageRefreshing = false
            }
        }
    }

    func refresh() {
        guard servicesEnabled else { return }
        guard !refreshing else { return }
        refreshing = true
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let result = try self.store.refresh()
                DispatchQueue.main.async {
                    self.snapshot = result
                    self.refreshing = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.notice = error.localizedDescription
                    self.refreshing = false
                }
            }
        }
    }

    func toggleFavorite(_ session: SessionRecord) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.store.setFavorite(id: session.id, value: !session.isFavorite)
                let result = try self.store.snapshot()
                DispatchQueue.main.async { self.snapshot = result }
            } catch {
                DispatchQueue.main.async { self.notice = error.localizedDescription }
            }
        }
    }

    func openSession(_ session: SessionRecord) {
        enqueueOpen(.direct(session.id))
    }

    func navigate(_ action: SessionNavigationAction) {
        enqueueOpen(.shortcut(action))
    }

    func performShortcut(_ action: ShortcutAction) {
        if let navigation = action.navigationAction {
            navigate(navigation)
        } else if action == .showPopover {
            onPopoverToggleRequested?()
        } else if action == .completeCurrent {
            completeCurrentSession()
        } else if action == .undoCompletion {
            enqueueOpen(.undoCompletion)
        }
    }

    private func undoLastCompletion() {
        while let id = completionHistory.last {
            guard let session = snapshot.sessions.first(where: { $0.id == id }), session.isCompleted else {
                completionHistory.removeLast()
                continue
            }
            applyCompletion(session, request: .undo)
            return
        }
        notice = "没有可撤回的完成记录。"
        if let session = snapshot.sessions.first(where: { $0.id == navigation.currentID }) {
            toast = SessionToast(session: session, message: "没有可撤回的完成记录", kind: .warning)
        }
    }

    private func completeCurrentSession() {
        guard !openingSession, openRequests.isEmpty else {
            notice = "正在切换会话，请稍后标记完成。"
            return
        }
        guard let window = completionWindow, uptime() < window.deadline,
            navigation.currentID == window.sessionID,
            let session = snapshot.sessions.first(where: { $0.id == window.sessionID }), !session.isCompleted
        else {
            notice = "请先通过换台打开会话，并在切换成功后 15 秒内标记完成。"
            if let session = snapshot.sessions.first(where: { $0.id == navigation.currentID }) {
                toast = SessionToast(session: session, message: "请先成功切换会话，再在 15 秒内标记完成", kind: .warning)
            }
            return
        }
        applyCompletion(session, request: .shortcut)
    }

    /// Mouse and context-menu actions only save status; automatic navigation is shortcut-only.
    func setCompleted(_ session: SessionRecord, value: Bool) {
        applyCompletion(session, request: .manual(value))
    }

    private func applyCompletion(_ session: SessionRecord, request: CompletionRequest) {
        guard !openingSession else {
            notice = "正在切换会话，请稍后更新状态。"
            return
        }
        let value = request.value
        let advanceToNext = request.advancesToNext
        let previousWindow = completionWindow
        let ordered = advanceToNext ? navigableSessions.map(\.id) : []
        let index = ordered.firstIndex(of: session.id)
        let successors = index.map { Array(ordered.dropFirst($0 + 1)) + Array(ordered.prefix($0)) } ?? []
        if advanceToNext || request.isUndo || (value && previousWindow?.sessionID == session.id) {
            completionWindow = nil
        }
        openingSession = true
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let before = try self.store.snapshot()
                let wasCompleted = before.sessions.first(where: { $0.id == session.id })?.isCompleted == true
                if request.isUndo, !wasCompleted {
                    DispatchQueue.main.async {
                        self.snapshot = before
                        self.completionHistory.removeAll { $0 == session.id }
                        self.openingSession = false
                        self.completionWindow = previousWindow
                        self.undoLastCompletion()
                        self.processOpenRequests()
                    }
                    return
                }
                try self.store.setCompleted(id: session.id, value: value)
                let result = try self.store.snapshot()
                DispatchQueue.main.async {
                    self.snapshot = result
                    self.openingSession = false
                    self.notice = nil
                    if value, !wasCompleted {
                        self.completionHistory.removeAll { $0 == session.id }
                        self.completionHistory.append(session.id)
                        if self.completionHistory.count > 256 { self.completionHistory.removeFirst() }
                    } else if !value {
                        self.completionHistory.removeAll { $0 == session.id }
                    }
                    let remaining = advanceToNext ? self.navigableSessions : []
                    let remainingIDs = Set(remaining.map(\.id))
                    let next = successors.first(where: { remainingIDs.contains($0) }) ?? remaining.first?.id
                    if request.isUndo {
                        self.openRequests.insert(.afterUndoCompletion(session.id), at: 0)
                    } else if value, advanceToNext, let next {
                        self.openRequests.insert(.afterCompletion(next), at: 0)
                    } else {
                        var updated = session
                        updated.isCompleted = value
                        self.toast = SessionToast(
                            session: updated,
                            message: value
                                ? (advanceToNext
                                    ? "已完成 · 当前筛选中没有下一条未完成会话" + self.undoCompletionHint : "已标为完成")
                                : "已恢复为未完成", kind: .completed)
                    }
                    self.processOpenRequests()
                }
            } catch {
                DispatchQueue.main.async {
                    self.openingSession = false
                    self.completionWindow = previousWindow
                    self.notice = "状态保存失败：\(error.localizedDescription)"
                    self.toast = SessionToast(session: session, message: "状态保存失败 · 未切换会话", kind: .warning)
                    self.openRequests.removeAll()
                }
            }
        }
    }

    private func enqueueOpen(_ request: OpenRequest) {
        guard openRequests.count < 16 else { return }
        openRequests.append(request)
        processOpenRequests()
    }

    private var undoCompletionHint: String {
        shortcuts[.undoCompletion].map { " · \($0.display) 撤回并返回" } ?? ""
    }

    private func discardPendingOpens() {
        // A failed source open must still allow an already queued completion undo to run.
        openRequests.removeAll { request in
            if case .undoCompletion = request { return false }
            return true
        }
        processOpenRequests()
    }

    private func processOpenRequests() {
        guard !openingSession else { return }
        while !openRequests.isEmpty {
            let request = openRequests.removeFirst()
            let target: String?
            let action: SessionNavigationAction?
            let completedPrevious: Bool
            let undoneCompletion: Bool
            switch request {
            case .direct(let id):
                target = id
                action = nil
                completedPrevious = false
                undoneCompletion = false
            case .afterCompletion(let id):
                target = id
                action = nil
                completedPrevious = true
                undoneCompletion = false
            case .undoCompletion:
                undoLastCompletion()
                if openingSession { return }
                continue
            case .afterUndoCompletion(let id):
                target = id
                action = nil
                completedPrevious = false
                undoneCompletion = true
            case .shortcut(let value):
                action = value
                completedPrevious = false
                undoneCompletion = false
                target = navigation.target(
                    for: value, orderedIDs: navigableSessions.map(\.id),
                    availableIDs: Set(snapshot.sessions.filter { !$0.isCompleted }.map(\.id)))
            }
            guard let target, let session = snapshot.sessions.first(where: { $0.id == target }) else {
                continue
            }
            completionWindow = nil
            let failurePrefix =
                undoneCompletion ? "已撤回完成 · 会话未能打开：" : completedPrevious ? "上一项已完成 · 下一项未能打开：" : "未能打开："
            guard let value = session.openURL,
                let validated = SessionStore.validatedOpenURL(value), let url = URL(string: validated)
            else {
                let reason = session.openUnavailableReason ?? "尚无有效的来源链接，可在会话右键菜单中设置来源链接。"
                notice = reason
                toast = SessionToast(
                    session: session, message: failurePrefix + reason,
                    kind: .warning)
                discardPendingOpens()
                return
            }
            let applicationOnly = url.scheme?.lowercased() == "dsh"
            openingSession = true
            openSource(url) { [weak self] error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.openingSession = false
                    if let error {
                        self.notice = error.localizedDescription
                        self.toast = SessionToast(
                            session: session,
                            message: (undoneCompletion
                                ? "已撤回完成 · 会话打开失败：" : completedPrevious ? "上一项已完成 · 下一项打开失败：" : "会话打开失败：")
                                + error.localizedDescription, kind: .warning)
                        self.discardPendingOpens()
                    } else {
                        self.navigation.didOpen(session.id, action: action)
                        let current = self.snapshot.sessions.first(where: { $0.id == session.id }) ?? session
                        if !current.isCompleted {
                            self.completionWindow = CompletionWindow(
                                sessionID: session.id, deadline: self.uptime() + 15)
                        }
                        if action != nil || completedPrevious || undoneCompletion || applicationOnly {
                            let filtered = self.navigableSessions
                            let ordered =
                                filtered.contains(where: { $0.id == session.id })
                                ? filtered : self.snapshot.filteredSessions()
                            self.toast = SessionToast(
                                session: current,
                                position: ordered.firstIndex(where: { $0.id == session.id }).map { $0 + 1 },
                                total: ordered.count,
                                message: applicationOnly
                                    ? (undoneCompletion
                                        ? "已撤回完成 · 已打开 DeepSeek Harness"
                                        : completedPrevious
                                            ? "上一项已完成 · 已打开 DeepSeek Harness" + self.undoCompletionHint
                                            : "已打开 DeepSeek Harness")
                                    : undoneCompletion
                                        ? "已撤回完成 · 已返回会话"
                                        : completedPrevious ? "上一项已完成" + self.undoCompletionHint : "已切换会话",
                                completionShortcut: self.shortcuts[.completeCurrent]?.display,
                                completionDeadline: self.completionWindow?.deadline)
                        }
                        self.notice = nil
                        self.processOpenRequests()
                    }
                }
            }
            return
        }
    }

    func configureLink(_ session: SessionRecord) {
        let alert = NSAlert()
        alert.messageText = "设置来源链接"
        alert.informativeText =
            "粘贴 Codex 会话、飞书聊天/话题链接或 dsh://open 以覆盖自动关联。DeepSeek Harness 入口直接打开应用。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 430, height: 24))
        field.stringValue = session.openURL ?? ""
        field.placeholderString = "已核验的来源链接"
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.store.setOpenMapping(id: session.id, url: value)
                let result = try self.store.snapshot()
                DispatchQueue.main.async { self.snapshot = result }
            } catch {
                DispatchQueue.main.async { self.notice = error.localizedDescription }
            }
        }
    }

    func openWeb() {
        guard webReady else {
            notice = "本地 Web 尚未就绪。"
            return
        }
        NSWorkspace.shared.open(URL(string: "http://127.0.0.1:18784/")!)
    }

    // Explicit review mode only: render this app's own content view into a local artifact.
    // No desktop capture, permission changes or other applications are involved.
    func saveReviewScreenshot() {
        guard CommandLine.arguments.contains("--review"),
            let view = NSApplication.shared.windows.first(where: {
                $0.title == "换台 · 原生界面审阅"
            })?.contentView
        else { return }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            notice = "无法生成当前界面的截图。"
            return
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        let target = store.dataDirectory.appendingPathComponent("native-review.png")
        do {
            try png.write(to: target, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            notice = "界面截图已保存至换台本地状态目录。"
        } catch { notice = "截图保存失败。" }
    }
}

private struct CompletionWindow {
    let sessionID: String
    let deadline: TimeInterval
}
