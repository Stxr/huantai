import CSQLite
import Darwin
import Foundation

public final class SessionStore: @unchecked Sendable {
    public let dataDirectory: URL
    public let codexDirectory: URL
    public let botmuxDirectory: URL
    public let deepSeekHarnessDirectory: URL
    private let deepSeekHarnessScanner = DeepSeekHarnessScanner()
    private let mutex = NSLock()
    private let fileManager = FileManager.default
    private var decodedFiles: [String: (stamp: FileStamp, value: Any)] = [:]

    public init(
        dataDirectory: URL? = nil, codexDirectory: URL? = nil, botmuxDirectory: URL? = nil,
        deepSeekHarnessDirectory: URL? = nil
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configuredHome = ProcessInfo.processInfo.environment["HUANTAI_HOME"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        self.dataDirectory =
            dataDirectory ?? configuredHome
            ?? home
            .appendingPathComponent("Library/Application Support/huantai", isDirectory: true)
        self.codexDirectory =
            codexDirectory ?? ProcessInfo.processInfo.environment["HUANTAI_CODEX_HOME"].map {
                URL(fileURLWithPath: $0, isDirectory: true)
            } ?? home.appendingPathComponent(".codex", isDirectory: true)
        self.botmuxDirectory =
            botmuxDirectory ?? ProcessInfo.processInfo.environment["HUANTAI_BOTMUX_HOME"].map {
                URL(fileURLWithPath: $0, isDirectory: true)
            } ?? home.appendingPathComponent(".botmux/data/session-stores", isDirectory: true)
        self.deepSeekHarnessDirectory =
            deepSeekHarnessDirectory
            ?? (ProcessInfo.processInfo.environment["HUANTAI_DSH_HOME"]
            ?? ProcessInfo.processInfo.environment["DSH_HOME"]).map {
                URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
            } ?? home.appendingPathComponent(".dsh", isDirectory: true)
    }

    public func refresh() throws -> IndexSnapshot {
        let started = ProcessInfo.processInfo.systemUptime
        return try withStoreLock {
            let preferences = try load(Preferences.self, name: "preferences.json") ?? Preferences()
            let configuration = try load(StoreConfiguration.self, name: "config.json") ?? StoreConfiguration()
            let cached = try load(ScanCache.self, name: "reply-cache.json") ?? ScanCache()
            var nextCache = ScanCache()
            var sources: [SourceStatus] = []
            var sessions: [SessionRecord] = []
            var snapshotDate = Date()
            var metadataFresh = false
            var diagnostics = ScanDiagnostics()
            let codexRoot =
                configuration.codexHome.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? codexDirectory
            let resolvedCodexRoot = codexRoot.resolvingSymlinksInPath().standardizedFileURL
            let allowedPrefixes = ["sessions", "archived_sessions"].map {
                resolvedCodexRoot.appendingPathComponent($0, isDirectory: true).standardizedFileURL.path + "/"
            }
            if configuration.codexEnabled {
                do {
                    let metadata = try readLocalMetadata(in: codexRoot)
                    metadataFresh = true
                    var unavailableRollouts = 0
                    for thread in metadata {
                        let allowed = safeRolloutURL(
                            path: thread.rolloutPath, allowedPrefixes: allowedPrefixes)
                        var reply: Date?
                        var preview: String?
                        if let allowed {
                            do {
                                let attributes = try fileManager.attributesOfItem(atPath: allowed.path)
                                let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                                let modified =
                                    (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                                let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
                                var readOffset: UInt64
                                if let old = cached.entries[thread.id], old.path == allowed.path,
                                    cached.version == ScanCache.currentVersion,
                                    old.size == size, old.modified == modified, old.fileNumber == fileNumber,
                                    let offset = old.readOffset
                                {
                                    reply = old.lastAIReplyAt
                                    preview = old.preview
                                    readOffset = offset
                                    diagnostics.unchangedFiles += 1
                                } else {
                                    let old = cached.entries[thread.id]
                                    let appendOnly =
                                        cached.version == ScanCache.currentVersion
                                        && old?.path == allowed.path
                                        && fileNumber != nil && old?.fileNumber == fileNumber
                                        && (old?.size ?? UInt64.max) < size
                                        && old?.readOffset != nil
                                        && (old?.readOffset ?? UInt64.max) <= (old?.size ?? 0)
                                    let result = try RolloutReplyScanner.scan(
                                        in: allowed, startingAt: appendOnly ? old!.readOffset! : 0,
                                        previousReply: appendOnly ? old?.lastAIReplyAt : nil,
                                        previousPreview: appendOnly ? old?.preview : nil, limit: size)
                                    reply = result.lastAIReplyAt
                                    preview = result.preview
                                    readOffset = result.committedOffset
                                    diagnostics.bytesRead += result.bytesRead
                                    if appendOnly {
                                        diagnostics.appendedFiles += 1
                                    } else {
                                        diagnostics.fullReadFiles += 1
                                    }
                                }
                                nextCache.entries[thread.id] = ScanEntry(
                                    path: allowed.path, size: size,
                                    modified: modified, lastAIReplyAt: reply, preview: preview,
                                    readOffset: readOffset,
                                    fileNumber: fileNumber)
                            } catch { unavailableRollouts += 1 }
                        } else {
                            unavailableRollouts += 1
                        }
                        let mapping =
                            preferences.openMappings[thread.id].flatMap { Self.validatedOpenURL($0) }
                            ?? SourceOpening.codexURL(sessionID: thread.id)
                        sessions.append(
                            SessionRecord(
                                id: thread.id,
                                title: displayTitle(thread.title, id: thread.id),
                                cwd: cleanMetadata(thread.cwd), source: sourceName(thread.source),
                                machine: "本机",
                                lastAIReplyAt: reply, lastAIReplyPreview: preview,
                                isFavorite: preferences.favorites.contains(thread.id),
                                openURL: mapping,
                                openUnavailableReason: mapping == nil ? "尚无已核验的来源链接，可显式配置映射" : nil))
                    }
                    let detail =
                        unavailableRollouts == 0
                        ? "已连接（只读）" : "已连接（只读）；\(unavailableRollouts) 个回复记录不可读或不在允许目录"
                    sources.append(SourceStatus(id: "local", name: "本机 Codex", status: detail))
                } catch {
                    if let previous = try load(IndexSnapshot.self, name: "index.json"),
                        !previous.sessions.isEmpty
                    {
                        sessions = previous.sessions.filter { $0.source != "DeepSeek Harness" }
                        snapshotDate = previous.updatedAt
                        nextCache = cached
                        sources.append(
                            SourceStatus(
                                id: "local", name: "本机 Codex",
                                status: "索引暂不可读；显示上次缓存（"
                                    + ISO8601DateFormatter().string(from: previous.updatedAt)
                                    + "）"))
                    } else {
                        sources.append(
                            SourceStatus(id: "local", name: "本机 Codex", status: "未连接：本地会话索引不存在或不可读"))
                    }
                }
            } else {
                sources.append(SourceStatus(id: "local", name: "本机 Codex", status: "已关闭"))
            }
            let botmux = readBotmuxAssociations()
            if botmux.databaseCount > 0 {
                for index in sessions.indices where botmux.sessionIDs.contains(sessions[index].id) {
                    sessions[index].source = "Botmux"
                    if let title = botmux.titles[sessions[index].id] { sessions[index].title = title }
                    sessions[index].openURL =
                        preferences.openMappings[sessions[index].id]
                        .flatMap { Self.validatedOpenURL($0) }
                        ?? botmux.openURLs[sessions[index].id]
                    if sessions[index].openURL == nil {
                        sessions[index].openUnavailableReason =
                            botmux.unavailableReasons[sessions[index].id]
                            ?? "Botmux 会话尚无已核验的飞书链接，可显式配置映射"
                    } else {
                        sessions[index].openUnavailableReason = nil
                    }
                }
                sources.append(
                    SourceStatus(
                        id: "botmux", name: "本机 Botmux",
                        status: "已关联 \(sessions.filter { $0.source == "Botmux" }.count) 个 Codex 会话（只读）"))
            }
            if configuration.deepSeekHarnessEnabled {
                let root =
                    configuration.deepSeekHarnessHome.map { URL(fileURLWithPath: $0, isDirectory: true) }
                    ?? deepSeekHarnessDirectory
                do {
                    let result = try deepSeekHarnessScanner.scan(home: root, diagnostics: &diagnostics)
                    sessions.append(contentsOf: result.sessions)
                    metadataFresh = true
                    let detail =
                        result.unreadable == 0
                        ? "已连接（只读）；\(result.sessions.count) 个会话"
                        : "已读取 \(result.sessions.count) 个会话；\(result.unreadable) 个记录格式不支持或不可读"
                    sources.append(
                        SourceStatus(id: "deepseek-harness", name: "本机 DeepSeek Harness", status: detail))
                } catch {
                    let previous =
                        (try? load(IndexSnapshot.self, name: "index.json"))?.sessions.filter {
                            $0.source == "DeepSeek Harness"
                        } ?? []
                    sessions.append(contentsOf: previous)
                    let detail = previous.isEmpty ? "未连接：会话目录不存在或不可读" : "会话目录暂不可读；显示上次缓存"
                    sources.append(
                        SourceStatus(id: "deepseek-harness", name: "本机 DeepSeek Harness", status: detail))
                }
            } else {
                sources.append(
                    SourceStatus(id: "deepseek-harness", name: "本机 DeepSeek Harness", status: "已关闭"))
            }
            for index in sessions.indices {
                sessions[index].isFavorite = preferences.favorites.contains(sessions[index].id)
                sessions[index].isCompleted = preferences.completed.contains(sessions[index].id)
                if sessions[index].source == "DeepSeek Harness" {
                    sessions[index].openURL =
                        preferences.openMappings[sessions[index].id].flatMap {
                            Self.validatedOpenURL($0)
                        } ?? SourceOpening.deepSeekHarnessURL
                    sessions[index].openUnavailableReason = nil
                } else if sessions[index].source != "Botmux" {
                    sessions[index].openURL =
                        preferences.openMappings[sessions[index].id]
                        .flatMap { Self.validatedOpenURL($0) }
                        ?? SourceOpening.codexURL(sessionID: sessions[index].id)
                    sessions[index].openUnavailableReason =
                        sessions[index].openURL == nil
                        ? "尚无已核验的来源链接，可显式配置映射" : nil
                }
            }
            for target in configuration.remoteTargets {
                sources.append(
                    SourceStatus(
                        id: target.id, name: target.name,
                        status: "已配置，未连接（首版不自动执行 SSH）"))
            }
            let usage = try load(UsageSummary.self, name: "usage.json") ?? UsageSummary()
            if nextCache != cached { try save(nextCache, name: "reply-cache.json") }
            if metadataFresh { snapshotDate = Date() }
            diagnostics.durationMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
            var snapshot = IndexSnapshot(
                sessions: sessions.sorted(by: SessionRecord.aiReplyOrder),
                usage: usage, sources: sources, updatedAt: snapshotDate, scan: diagnostics)
            try save(snapshot, name: "index.json")
            // Returned/shared in-process metrics include encoding and persistence as well.
            snapshot.scan?.durationMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
            decodedFiles["index.json"]?.value = snapshot
            return snapshot
        }
    }

    public func snapshot() throws -> IndexSnapshot {
        let existing: IndexSnapshot? = try withStoreLock {
            guard var snapshot = try load(IndexSnapshot.self, name: "index.json") else { return nil }
            let preferences = try load(Preferences.self, name: "preferences.json") ?? Preferences()
            var needsSanitizedSave = false
            for index in snapshot.sessions.indices {
                let title = displayTitle(snapshot.sessions[index].title, id: snapshot.sessions[index].id)
                let source = sourceName(snapshot.sessions[index].source)
                if title != snapshot.sessions[index].title || source != snapshot.sessions[index].source {
                    snapshot.sessions[index].title = title
                    snapshot.sessions[index].source = source
                    needsSanitizedSave = true
                }
                snapshot.sessions[index].isFavorite = preferences.favorites.contains(
                    snapshot.sessions[index].id)
                snapshot.sessions[index].isCompleted = preferences.completed.contains(
                    snapshot.sessions[index].id)
                snapshot.sessions[index].openURL =
                    preferences.openMappings[snapshot.sessions[index].id]
                    .flatMap { Self.validatedOpenURL($0) }
                    ?? (snapshot.sessions[index].source == "DeepSeek Harness"
                        ? SourceOpening.deepSeekHarnessURL
                        : snapshot.sessions[index].source == "Botmux"
                            ? snapshot.sessions[index].openURL.flatMap { Self.validatedOpenURL($0) }
                            : SourceOpening.codexURL(sessionID: snapshot.sessions[index].id))
                if snapshot.sessions[index].openURL != nil {
                    snapshot.sessions[index].openUnavailableReason = nil
                } else if snapshot.sessions[index].openUnavailableReason == nil {
                    snapshot.sessions[index].openUnavailableReason = "尚无已核验的来源链接，可显式配置映射"
                }
            }
            snapshot.usage = try load(UsageSummary.self, name: "usage.json") ?? UsageSummary()
            if needsSanitizedSave { try save(snapshot, name: "index.json") }
            return snapshot
        }
        return try existing ?? refresh()
    }

    public func filteredSessions(
        query: String = "", favoritesOnly: Bool = false, includeCompleted: Bool = false
    ) throws -> [SessionRecord] {
        try snapshot().filteredSessions(
            query: query, favoritesOnly: favoritesOnly, includeCompleted: includeCompleted)
    }

    public func setFavorite(id: String, value: Bool) throws {
        try withStoreLock {
            guard let snapshot = try load(IndexSnapshot.self, name: "index.json"),
                snapshot.sessions.contains(where: { $0.id == id })
            else { throw HuantaiError.sessionNotFound }
            var preferences = try load(Preferences.self, name: "preferences.json") ?? Preferences()
            if value { preferences.favorites.insert(id) } else { preferences.favorites.remove(id) }
            try save(preferences, name: "preferences.json")
        }
    }

    /// Local task state is independent from source archives, favorites and reply timestamps.
    public func setCompleted(id: String, value: Bool) throws {
        try withStoreLock {
            guard let snapshot = try load(IndexSnapshot.self, name: "index.json"),
                snapshot.sessions.contains(where: { $0.id == id })
            else { throw HuantaiError.sessionNotFound }
            var preferences = try load(Preferences.self, name: "preferences.json") ?? Preferences()
            if value { preferences.completed.insert(id) } else { preferences.completed.remove(id) }
            try save(preferences, name: "preferences.json")
        }
    }

    /// Caller must supply an explicitly verified link; this never guesses URLs from session IDs.
    public func setOpenMapping(id: String, url: String) throws {
        guard let validated = Self.validatedOpenURL(url) else { throw HuantaiError.invalidOpenURL }
        try withStoreLock {
            guard let snapshot = try load(IndexSnapshot.self, name: "index.json"),
                snapshot.sessions.contains(where: { $0.id == id })
            else { throw HuantaiError.sessionNotFound }
            var preferences = try load(Preferences.self, name: "preferences.json") ?? Preferences()
            preferences.openMappings[id] = validated
            try save(preferences, name: "preferences.json")
        }
    }

    public func configuration() throws -> StoreConfiguration {
        try withStoreLock { try load(StoreConfiguration.self, name: "config.json") ?? StoreConfiguration() }
    }

    public func setSessionSource(_ source: SessionSource, enabled: Bool) throws {
        try withStoreLock {
            var configuration = try load(StoreConfiguration.self, name: "config.json") ?? StoreConfiguration()
            switch source {
            case .codex: configuration.codexEnabled = enabled
            case .deepSeekHarness: configuration.deepSeekHarnessEnabled = enabled
            }
            try save(configuration, name: "config.json")
        }
    }

    public func setSessionDirectory(_ source: SessionSource, path: String?) throws {
        let expanded = path.map {
            ($0.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        }
        if let expanded,
            !expanded.hasPrefix("/")
                || expanded.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        {
            throw HuantaiError.invalidConfiguration("请选择绝对目录路径。")
        }
        try withStoreLock {
            var configuration = try load(StoreConfiguration.self, name: "config.json") ?? StoreConfiguration()
            let previousPath = source == .codex ? configuration.codexHome : configuration.deepSeekHarnessHome
            switch source {
            case .codex: configuration.codexHome = expanded
            case .deepSeekHarness: configuration.deepSeekHarnessHome = expanded
            }
            if previousPath != expanded {
                // Cached rows belong to their source root; a new directory must not inherit them on failure.
                if var snapshot = try load(IndexSnapshot.self, name: "index.json") {
                    snapshot.sessions.removeAll {
                        source == .deepSeekHarness
                            ? $0.source == "DeepSeek Harness" : $0.source != "DeepSeek Harness"
                    }
                    try save(snapshot, name: "index.json")
                }
                if source == .deepSeekHarness { deepSeekHarnessScanner.reset() }
            }
            try save(configuration, name: "config.json")
        }
    }

    public func setRemoteTarget(_ target: RemoteTarget) throws {
        guard !target.id.isEmpty, !target.name.isEmpty,
            target.host.range(of: "^[A-Za-z0-9_.@:-]+$", options: .regularExpression) != nil,
            !target.host.hasPrefix("-"), !target.sessionRoot.contains("\n"),
            !target.sessionRoot.isEmpty
        else {
            throw HuantaiError.invalidConfiguration("SSH 目标需明确名称、有效主机及会话根目录；首版仅保存配置。")
        }
        try withStoreLock {
            var configuration = try load(StoreConfiguration.self, name: "config.json") ?? StoreConfiguration()
            configuration.remoteTargets.removeAll { $0.id == target.id }
            configuration.remoteTargets.append(target)
            try save(configuration, name: "config.json")
        }
    }

    @discardableResult
    public func importUsageSnapshot(from url: URL) throws -> UsageSummary {
        let size = try fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        guard let size, size.intValue <= 2 * 1024 * 1024 else { throw HuantaiError.invalidUsageSnapshot }
        let summary = try UsageSnapshotImporter.decode(Data(contentsOf: url))
        try withStoreLock { try save(summary, name: "usage.json") }
        return summary
    }

    @discardableResult
    public func refreshUsage() throws -> UsageSummary {
        do {
            let summary = try CodexRateLimitsClient().fetch()
            try withStoreLock { try save(summary, name: "usage.json") }
            return summary
        } catch {
            try withStoreLock {
                var previous = try load(UsageSummary.self, name: "usage.json") ?? UsageSummary()
                previous.status =
                    previous.observedAt == nil
                    ? "额度读取失败：" + error.localizedDescription
                    : "额度刷新失败，显示上次读取：" + error.localizedDescription
                try save(previous, name: "usage.json")
            }
            throw error
        }
    }

    public static func validatedOpenURL(_ string: String) -> String? {
        guard string.count <= 4096,
            !string.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
            let components = URLComponents(string: string), components.user == nil,
            components.password == nil, components.port == nil,
            let scheme = components.scheme?.lowercased(), let url = components.url
        else { return nil }
        if scheme == "dsh", components.host?.lowercased() == "open",
            ["", "/"].contains(components.path), components.query == nil, components.fragment == nil
        {
            return SourceOpening.deepSeekHarnessURL
        }
        if scheme == "codex", components.host == "threads",
            components.query == nil, components.fragment == nil,
            SourceOpening.codexURL(sessionID: String(components.path.dropFirst())) != nil
        {
            return url.absoluteString
        }
        guard ["https", "lark", "x-feishu"].contains(scheme),
            components.host?.lowercased() == "applink.feishu.cn",
            components.fragment == nil, let items = components.queryItems
        else { return nil }
        if components.path == "/client/chat/open",
            items.count == 1, items[0].name == "openChatId"
        {
            return SourceOpening.feishuChatURL(chatID: items[0].value ?? "")
        }
        let names: Set<String> = [
            "open_chat_id", "open_thread_id", "openchatid", "openthreadid", "thread_position",
        ]
        guard components.path == "/client/thread/open", items.count == names.count,
            Set(items.map(\.name)) == names
        else { return nil }
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        guard values["open_chat_id"] == values["openchatid"],
            values["open_thread_id"] == values["openthreadid"], values["thread_position"] == "-1"
        else { return nil }
        return SourceOpening.feishuThreadURL(
            chatID: values["open_chat_id"] ?? "", threadID: values["open_thread_id"] ?? "")
    }

    private struct ThreadMetadata {
        var id: String
        var title: String
        var cwd: String
        var source: String
        var rolloutPath: String
    }
    private struct Preferences: Codable {
        var favorites: Set<String> = []
        var openMappings: [String: String] = [:]
        var completed: Set<String> = []

        init() {}
        private enum CodingKeys: String, CodingKey { case favorites, openMappings, completed }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            favorites = try values.decodeIfPresent(Set<String>.self, forKey: .favorites) ?? []
            openMappings = try values.decodeIfPresent([String: String].self, forKey: .openMappings) ?? [:]
            completed = try values.decodeIfPresent(Set<String>.self, forKey: .completed) ?? []
        }
    }
    private struct ScanCache: Codable, Equatable {
        static let currentVersion = 3
        var version: Int? = currentVersion
        var entries: [String: ScanEntry] = [:]
    }
    private struct ScanEntry: Codable, Equatable {
        var path: String
        var size: UInt64
        var modified: TimeInterval
        var lastAIReplyAt: Date?
        var preview: String?
        var readOffset: UInt64?
        var fileNumber: UInt64?
    }

    private func sourceName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["cli", "exec", "app", "vscode", "mcp", "codex"].contains(trimmed.lowercased()) {
            return "Codex"
        }
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            // Inspect only the top-level tag. Internal parent IDs and source payloads never
            // become display labels or persist in the public index.
            if trimmed.utf8.count <= 16_384,
                let descriptor = try? JSONDecoder().decode(SourceDescriptor.self, from: Data(trimmed.utf8)),
                descriptor.isSubagent
            {
                return "Codex 子会话"
            }
            return "其他来源"
        }
        return trimmed.isEmpty ? "未知来源" : String(cleanMetadata(trimmed).prefix(32))
    }

    private struct SourceDescriptor: Decodable {
        var isSubagent: Bool
        private enum CodingKeys: String, CodingKey { case subagent }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if container.contains(.subagent) {
                isSubagent = !(try container.decodeNil(forKey: .subagent))
            } else {
                isSubagent = false
            }
        }
    }

    /// SQLite title columns may contain transport wrappers or full initial prompts.
    /// Only short display titles enter snapshots; rejected values are never truncated into labels.
    private func validDisplayTitle(_ value: String) -> String? {
        guard value.count <= 160 else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let markers = [
            "<botmux_", "<session_id>", "<user_message>", "<codex_delegation>",
            "# agents.md", "<environment_context>", "<instructions>",
        ]
        let lowercase = trimmed.lowercased()
        guard !markers.contains(where: { lowercase.contains($0) }) else { return nil }
        let cleaned = cleanMetadata(trimmed)
        return cleaned.isEmpty ? nil : cleaned
    }

    private func displayTitle(_ value: String, id: String) -> String {
        validDisplayTitle(value) ?? "未命名会话 · " + String(cleanMetadata(id).prefix(8))
    }

    private func cleanMetadata(_ value: String) -> String {
        String(
            String(
                String.UnicodeScalarView(
                    value.unicodeScalars.filter {
                        !CharacterSet.controlCharacters.contains($0)
                    })
            ).prefix(1000))
    }

    private func safeRolloutURL(path: String, allowedPrefixes: [String]) -> URL? {
        guard !path.isEmpty, path.hasPrefix("/") else { return nil }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        guard resolved.pathExtension == "jsonl",
            allowedPrefixes.contains(where: { resolved.path.hasPrefix($0) })
        else { return nil }
        return resolved
    }

    /// Codex stores generated and renamed display titles separately from the initial prompt.
    /// The index is append-only: later valid entries for a thread replace earlier names.
    private func readCodexDisplayTitles(in root: URL) -> [String: String] {
        let url = root.appendingPathComponent("session_index.jsonl")
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
            values.isRegularFile == true, values.isSymbolicLink != true,
            let handle = try? FileHandle(forReadingFrom: url)
        else { return [:] }
        defer { try? handle.close() }
        struct Entry: Decodable {
            let id: String
            let threadName: String
            enum CodingKeys: String, CodingKey {
                case id
                case threadName = "thread_name"
            }
        }
        let decoder = JSONDecoder()
        var titles: [String: String] = [:]
        var pending = Data()
        // Stream bounded lines so an incomplete write or oversized malformed record is harmless.
        var skippingOversizedLine = false
        while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            for byte in chunk {
                if byte == 10 {
                    if !skippingOversizedLine,
                        let entry = try? decoder.decode(Entry.self, from: pending),
                        let title = validDisplayTitle(entry.threadName)
                    {
                        titles[entry.id] = title
                    }
                    pending.removeAll(keepingCapacity: true)
                    skippingOversizedLine = false
                } else if !skippingOversizedLine {
                    if pending.count < 64 * 1024 {
                        pending.append(byte)
                    } else {
                        pending.removeAll(keepingCapacity: true)
                        skippingOversizedLine = true
                    }
                }
            }
        }
        return titles
    }

    private func readLocalMetadata(in root: URL) throws -> [ThreadMetadata] {
        let dbURL = root.appendingPathComponent("state_5.sqlite")
        guard fileManager.fileExists(atPath: dbURL.path),
            (try? dbURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
        else {
            throw HuantaiError.sourceUnavailable("本地 Codex 索引不存在或是软链接")
        }
        var database: OpaquePointer?
        guard
            sqlite3_open_v2(dbURL.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
                == SQLITE_OK,
            let database
        else {
            if let database { sqlite3_close(database) }
            throw HuantaiError.sourceUnavailable("本地 Codex 索引不可读")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 2000)
        var statement: OpaquePointer?
        let query = "SELECT id, title, cwd, source, rollout_path FROM threads"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw HuantaiError.sourceUnavailable("本地 Codex 元数据格式暂不支持")
        }
        defer { sqlite3_finalize(statement) }
        let displayTitles = readCodexDisplayTitles(in: root)
        var threads: [ThreadMetadata] = []
        func column(_ index: Int32) -> String {
            guard let value = sqlite3_column_text(statement, index) else { return "" }
            return String(cString: value)
        }
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            let id = column(0)
            if !id.isEmpty {
                threads.append(
                    ThreadMetadata(
                        id: id, title: displayTitles[id] ?? displayTitle(column(1), id: id), cwd: column(2),
                        source: sourceName(column(3)), rolloutPath: column(4)))
            }
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw HuantaiError.sourceUnavailable("读取会话元数据失败") }
        return threads
    }

    /// Only display and routing metadata is selected; private JSON rows are never loaded.
    private func readBotmuxAssociations() -> (
        sessionIDs: Set<String>, titles: [String: String], openURLs: [String: String],
        unavailableReasons: [String: String], databaseCount: Int
    ) {
        let root = botmuxDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard
            let children = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles])
        else {
            return ([], [:], [:], [:], 0)
        }
        var ids = Set<String>()
        var titles: [String: String] = [:]
        var openURLs: [String: String] = [:]
        var unavailableReasons: [String: String] = [:]
        var count = 0
        for directory in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).prefix(32) {
            guard
                let properties = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                ),
                properties.isDirectory == true, properties.isSymbolicLink != true
            else { continue }
            let url = directory.appendingPathComponent("sessions.db")
            guard url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root.path + "/"),
                fileManager.fileExists(atPath: url.path),
                (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
            else { continue }
            var database: OpaquePointer?
            guard
                sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
                    == SQLITE_OK,
                let database
            else {
                if let database { sqlite3_close(database) }
                continue
            }
            defer { sqlite3_close(database) }
            sqlite3_busy_timeout(database, 500)
            var statement: OpaquePointer?
            // json_extract avoids loading or persisting the private JSON row.
            let query =
                "SELECT json_extract(row, '$.cliSessionId'), json_extract(row, '$.title'), json_extract(row, '$.nativeSessionTitle'), json_extract(row, '$.scope'), json_extract(row, '$.chatId'), json_extract(row, '$.larkThreadId') FROM sessions WHERE json_valid(row)"
            guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK, let statement else {
                continue
            }
            defer { sqlite3_finalize(statement) }
            count += 1
            while sqlite3_step(statement) == SQLITE_ROW {
                if let value = sqlite3_column_text(statement, 0) {
                    let id = String(cString: value)
                    if !id.isEmpty {
                        ids.insert(id)
                        if titles[id] == nil {
                            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
                            let nativeTitle =
                                sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
                            titles[id] = validDisplayTitle(title) ?? validDisplayTitle(nativeTitle)
                        }
                        let scope = sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? ""
                        let chatID = sqlite3_column_text(statement, 4).map { String(cString: $0) } ?? ""
                        let threadID = sqlite3_column_text(statement, 5).map { String(cString: $0) } ?? ""
                        if scope == "chat", let link = SourceOpening.feishuChatURL(chatID: chatID) {
                            openURLs[id] = link
                            unavailableReasons.removeValue(forKey: id)
                        } else if scope == "thread",
                            let link = SourceOpening.feishuThreadURL(chatID: chatID, threadID: threadID)
                        {
                            openURLs[id] = link
                            unavailableReasons.removeValue(forKey: id)
                        } else {
                            unavailableReasons[id] =
                                scope == "thread"
                                ? (SourceOpening.feishuChatURL(chatID: chatID) == nil
                                    ? "Botmux 话题缺少有效飞书聊天 ID"
                                    : "Botmux 话题缺少有效的 omt_ 话题 ID；需要补充对应话题链接")
                                : "Botmux 记录没有有效飞书聊天目标（如 headless 会话）"
                        }
                    }
                }
            }
        }
        return (ids, titles, openURLs, unavailableReasons, count)
    }

    private func withStoreLock<T>(_ action: () throws -> T) throws -> T {
        mutex.lock()
        defer { mutex.unlock() }
        try fileManager.createDirectory(
            at: dataDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let lockPath = dataDirectory.appendingPathComponent("store.lock").path
        let descriptor = Darwin.open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw HuantaiError.sourceUnavailable("无法写入换台本地索引目录") }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw HuantaiError.sourceUnavailable("无法锁定换台本地索引") }
        defer { flock(descriptor, LOCK_UN) }
        return try action()
    }

    private func load<T: Decodable>(_ type: T.Type, name: String) throws -> T? {
        let url = dataDirectory.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: url.path) else {
            decodedFiles[name] = nil
            return nil
        }
        let stamp = try FileStamp(url: url)
        if let cached = decodedFiles[name], cached.stamp == stamp, let value = cached.value as? T {
            return value
        }
        let decoder = HuantaiJSON.decoder()
        let value = try decoder.decode(type, from: Data(contentsOf: url))
        decodedFiles[name] = (stamp, value)
        return value
    }

    private func save<T: Encodable>(_ value: T, name: String) throws {
        let encoder = HuantaiJSON.encoder()
        let url = dataDirectory.appendingPathComponent(name)
        try encoder.encode(value).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        decodedFiles[name] = (try FileStamp(url: url), value)
    }

    private struct FileStamp: Equatable {
        var size: UInt64
        var modified: Date?
        var fileNumber: UInt64?
        init(url: URL) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            modified = attributes[.modificationDate] as? Date
            fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        }
    }
}
