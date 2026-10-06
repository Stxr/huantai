import Foundation

public struct SessionRecord: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var cwd: String
    public var source: String
    public var machine: String
    public var lastAIReplyAt: Date?
    public var lastAIReplyPreview: String?
    public var isFavorite: Bool
    public var isCompleted: Bool
    public var openURL: String?
    public var openUnavailableReason: String?

    public init(
        id: String, title: String, cwd: String, source: String, machine: String,
        lastAIReplyAt: Date? = nil, lastAIReplyPreview: String? = nil, isFavorite: Bool = false,
        isCompleted: Bool = false,
        openURL: String? = nil,
        openUnavailableReason: String? = nil
    ) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.source = source
        self.machine = machine
        self.lastAIReplyAt = lastAIReplyAt
        self.lastAIReplyPreview = lastAIReplyPreview
        self.isFavorite = isFavorite
        self.isCompleted = isCompleted
        self.openURL = openURL
        self.openUnavailableReason = openUnavailableReason
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, cwd, source, machine, lastAIReplyAt, lastAIReplyPreview, isFavorite, isCompleted,
            openURL,
            openUnavailableReason
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        cwd = try values.decode(String.self, forKey: .cwd)
        source = try values.decode(String.self, forKey: .source)
        machine = try values.decode(String.self, forKey: .machine)
        lastAIReplyAt = try values.decodeIfPresent(Date.self, forKey: .lastAIReplyAt)
        lastAIReplyPreview = try values.decodeIfPresent(String.self, forKey: .lastAIReplyPreview)
        isFavorite = try values.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        isCompleted = try values.decodeIfPresent(Bool.self, forKey: .isCompleted) ?? false
        openURL = try values.decodeIfPresent(String.self, forKey: .openURL)
        openUnavailableReason = try values.decodeIfPresent(String.self, forKey: .openUnavailableReason)
    }
}

public struct SourceStatus: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var status: String
    public init(id: String, name: String, status: String) {
        self.id = id
        self.name = name
        self.status = status
    }
}

public struct UsageWindow: Codable, Sendable, Equatable {
    public var usedPercent: Double
    public var windowDurationMins: Int
    public var resetsAt: Date
    public init(usedPercent: Double, windowDurationMins: Int, resetsAt: Date) {
        self.usedPercent = usedPercent
        self.windowDurationMins = windowDurationMins
        self.resetsAt = resetsAt
    }
}

public struct UsageSummary: Codable, Sendable, Equatable {
    public var weekly: UsageWindow?
    public var resetCount: Int?
    public var resetCredits: [ResetCreditExpiry]?
    public var observedAt: Date?
    public var status: String
    public var source: String?
    public init(
        weekly: UsageWindow? = nil, resetCount: Int? = nil, resetCredits: [ResetCreditExpiry]? = nil,
        observedAt: Date? = nil,
        status: String = "未连接用量来源", source: String? = nil
    ) {
        self.weekly = weekly
        self.resetCount = resetCount
        self.resetCredits = resetCredits
        self.observedAt = observedAt
        self.status = status
        self.source = source
    }
}

/// Only expiration metadata; never a credit identifier, title or account identity.
public struct ResetCreditExpiry: Codable, Sendable, Equatable {
    public var expiresAt: Date?
    public var expirationKnown: Bool
    public init(expiresAt: Date? = nil, expirationKnown: Bool = true) {
        self.expiresAt = expiresAt
        self.expirationKnown = expirationKnown
    }
}

public struct IndexSnapshot: Codable, Sendable, Equatable {
    public var sessions: [SessionRecord]
    public var usage: UsageSummary
    public var sources: [SourceStatus]
    public var updatedAt: Date
    public var scan: ScanDiagnostics?
    public init(
        sessions: [SessionRecord], usage: UsageSummary, sources: [SourceStatus], updatedAt: Date,
        scan: ScanDiagnostics? = nil
    ) {
        self.sessions = sessions
        self.usage = usage
        self.sources = sources
        self.updatedAt = updatedAt
        self.scan = scan
    }
    public func filteredSessions(
        query: String = "", favoritesOnly: Bool = false, includeCompleted: Bool = false
    ) -> [SessionRecord] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return sessions.filter {
            (includeCompleted || !$0.isCompleted) && (!favoritesOnly || $0.isFavorite)
                && (term.isEmpty || $0.title.localizedCaseInsensitiveContains(term)
                    || $0.cwd.localizedCaseInsensitiveContains(term))
        }.sorted(by: SessionRecord.aiReplyOrder)
    }
}

public struct ScanDiagnostics: Codable, Sendable, Equatable {
    public var durationMilliseconds: Double = 0
    public var unchangedFiles: Int = 0
    public var fullReadFiles: Int = 0
    public var appendedFiles: Int = 0
    public var bytesRead: UInt64 = 0
    public init() {}
}

extension SessionRecord {
    /// AI reply dates take precedence; missing replies are last. IDs make ties deterministic.
    public static func aiReplyOrder(_ lhs: SessionRecord, _ rhs: SessionRecord) -> Bool {
        switch (lhs.lastAIReplyAt, rhs.lastAIReplyAt) {
        case (let left?, let right?) where left != right: return left > right
        case (_?, nil): return true
        case (nil, _?): return false
        default: return lhs.id < rhs.id
        }
    }
}

public struct RemoteTarget: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var host: String
    public var sessionRoot: String
    public init(id: String, name: String, host: String, sessionRoot: String = "~/.codex") {
        self.id = id
        self.name = name
        self.host = host
        self.sessionRoot = sessionRoot
    }
}

public struct StoreConfiguration: Codable, Sendable, Equatable {
    public var remoteTargets: [RemoteTarget]
    public init(remoteTargets: [RemoteTarget] = []) { self.remoteTargets = remoteTargets }
}

public enum HuantaiError: LocalizedError {
    case invalidConfiguration(String)
    case sourceUnavailable(String)
    case sessionNotFound
    case invalidOpenURL
    case openUnavailable
    case invalidUsageSnapshot

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let reason), .sourceUnavailable(let reason): return reason
        case .sessionNotFound: return "未找到指定会话；请先刷新索引。"
        case .invalidOpenURL: return "打开链接仅接受已支持的 Codex 或飞书聊天、话题链接。"
        case .openUnavailable: return "该会话尚无已核验的打开链接。"
        case .invalidUsageSnapshot: return "用量快照无有效周窗口；需要官方 usedPercent、10080 分钟窗口及秒级 resetsAt。"
        }
    }
}
