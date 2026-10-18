import Darwin
import Foundation
import HuantaiCore

public struct FeishuDashboardFilter: Codable, Equatable, Sendable {
    public var days = 0
    public var favoritesOnly = false
    public var completedOnly = false
    public var pageSize = 5
    public var query = ""
    public init() {}
    public func validated() throws -> Self {
        guard [0, 1, 3, 7].contains(days), [3, 5, 10].contains(pageSize), query.count <= 100 else {
            throw FeishuBotError.message("筛选范围只能为0、1、3、7日，每页3、5或10项，搜索最多100字。")
        }
        return self
    }
}

public struct FeishuBotBinding: Codable, Equatable, Sendable {
    public var id: String
    public var appID: String
    var appSecret: String
    public var ownerID: String?
    public var chatID: String?
    public var pairingCode: String?
    public var pairingExpiresAt: Date?
    public var filter: FeishuDashboardFilter
}

public struct FeishuBotStatus: Codable, Sendable {
    public var appID: String?
    public var paired: Bool
    public var connection: String
    public var updatedAt: Date?
}

public enum FeishuBotError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        if case .message(let value) = self { return value }
        return nil
    }
}

struct FeishuOutboxItem: Codable {
    var id: String
    var bindingID: String
    var chatID: String
    var card: String
    var createdAt: Date
}

private struct FeishuSavedState: Codable {
    var binding: FeishuBotBinding?
    var registration: FeishuRegistrationChallenge?
    var outbox: [FeishuOutboxItem] = []
    var delivered: [String] = []
}

/// App and CLI share a restricted local store. Secret values never enter status or logs.
public final class FeishuBotConfiguration: @unchecked Sendable {
    public static let createURL = URL(string: "https://open.feishu.cn/app")!
    public let directory: URL
    private let mutex = NSLock()

    public init(dataDirectory: URL) { directory = dataDirectory.appendingPathComponent("feishu-bot") }

    public func binding() throws -> FeishuBotBinding? { try access { $0.binding } }

    public func registrationChallenge() throws -> FeishuRegistrationChallenge? {
        try access { $0.registration }
    }

    func saveRegistration(_ challenge: FeishuRegistrationChallenge) throws -> FeishuRegistrationChallenge {
        try access(write: true) { state in
            guard state.binding == nil else { throw FeishuBotError.message("已绑定机器人，未覆盖现有配置。") }
            if let pending = state.registration { return pending }
            state.registration = challenge
            return challenge
        }
    }

    func clearRegistration(deviceCode: String) throws {
        try access(write: true) { state in
            if state.registration?.deviceCode == deviceCode { state.registration = nil }
        }
    }

    func completeRegistration(deviceCode: String, appID: String, secret: String) throws -> FeishuBotBinding {
        let binding = try Self.newBinding(appID: appID, secret: secret, now: .now)
        return try access(write: true) { state in
            guard state.binding == nil, state.registration?.deviceCode == deviceCode else {
                throw FeishuBotError.message("机器人配置已被另一操作更改，未覆盖现有绑定。")
            }
            state = FeishuSavedState(binding: binding)
            return binding
        }
    }

    @discardableResult
    public func bind(appID: String, secret: String, now: Date = .now) throws -> FeishuBotBinding {
        let binding = try Self.newBinding(appID: appID, secret: secret, now: now)
        try access(write: true) { $0 = FeishuSavedState(binding: binding) }
        return binding
    }

    private static func newBinding(appID: String, secret: String, now: Date) throws -> FeishuBotBinding {
        let appID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard appID.range(of: "^cli_[A-Za-z0-9]+$", options: .regularExpression) != nil,
            !secret.isEmpty, secret.count <= 512
        else {
            throw FeishuBotError.message("请输入有效的应用 App ID 和 App Secret。")
        }
        let binding = FeishuBotBinding(
            id: UUID().uuidString, appID: appID, appSecret: secret,
            pairingCode: String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))
                .lowercased(),
            pairingExpiresAt: now.addingTimeInterval(600), filter: .init())
        return binding
    }

    public func unbind() throws { try access(write: true) { $0 = FeishuSavedState() } }

    public func renewPairing(now: Date = .now) throws -> FeishuBotBinding {
        try access(write: true) { state in
            guard var binding = state.binding else { throw FeishuBotError.message("尚未绑定机器人。") }
            binding.id = UUID().uuidString
            binding.ownerID = nil
            binding.chatID = nil
            binding.pairingCode = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))
                .lowercased()
            binding.pairingExpiresAt = now.addingTimeInterval(600)
            state = FeishuSavedState(binding: binding)
            return binding
        }
    }

    func pair(id: String, code: String, ownerID: String, chatID: String, now: Date) throws
        -> FeishuBotBinding?
    {
        try access(write: true) { state in
            guard var binding = state.binding, binding.id == id, binding.ownerID == nil,
                binding.pairingCode == code, let expiry = binding.pairingExpiresAt, expiry > now,
                ownerID.hasPrefix("ou_"), chatID.hasPrefix("oc_")
            else { return nil }
            binding.ownerID = ownerID
            binding.chatID = chatID
            binding.pairingCode = nil
            binding.pairingExpiresAt = nil
            state.binding = binding
            return binding
        }
    }

    public func setFilter(_ filter: FeishuDashboardFilter, bindingID: String? = nil) throws {
        let checked = try filter.validated()
        try access(write: true) { state in
            guard var binding = state.binding, bindingID == nil || binding.id == bindingID else {
                throw FeishuBotError.message("机器人已解绑或更换，请重新获取看板。")
            }
            binding.filter = checked
            state.binding = binding
        }
    }

    func enqueue(_ item: FeishuOutboxItem) throws {
        try access(write: true) { state in
            state.outbox.removeAll {
                $0.createdAt < Date().addingTimeInterval(-1800) || $0.bindingID != state.binding?.id
            }
            guard state.binding?.id == item.bindingID, !state.delivered.contains(item.id),
                !state.outbox.contains(where: { $0.id == item.id })
            else { return }
            guard state.outbox.count < 50 else { throw FeishuBotError.message("待发送消息过多，请稍后重试。") }
            state.outbox.append(item)
        }
    }

    func pending() throws -> FeishuOutboxItem? {
        try access { state in
            state.outbox.first {
                $0.createdAt >= Date().addingTimeInterval(-1800) && $0.bindingID == state.binding?.id
            }
        }
    }

    func delivered(_ id: String) throws {
        try access(write: true) { state in
            state.outbox.removeAll { $0.id == id }
            state.delivered.append(id)
            state.delivered = Array(state.delivered.suffix(256))
        }
    }

    public func status() throws -> FeishuBotStatus {
        let binding = try binding()
        guard let binding else { return .init(appID: nil, paired: false, connection: "未绑定", updatedAt: nil) }
        let report = try? JSONDecoder().decode(
            ConnectionReport.self, from: Data(contentsOf: directory.appendingPathComponent("status.json")))
        let active =
            report?.bindingID == binding.id && (report?.date ?? .distantPast) > Date().addingTimeInterval(-20)
        return .init(
            appID: binding.appID, paired: binding.ownerID != nil,
            connection: active ? report!.text : "未运行：请保持换台运行或执行 ht bot run", updatedAt: report?.date)
    }

    struct ConnectionReport: Codable {
        var bindingID: String
        var text: String
        var date: Date
    }
    func report(_ text: String, bindingID: String) throws {
        try access { state in
            guard state.binding?.id == bindingID else { return }
            try secureWrite(
                JSONEncoder().encode(ConnectionReport(bindingID: bindingID, text: text, date: .now)),
                name: "status.json")
        }
    }

    /// Only one listener per state directory, so App and CLI cannot steal each other's events.
    func acquireListener() throws -> Int32 {
        try prepareDirectory()
        let fd = Darwin.open(
            directory.appendingPathComponent("listener.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw FeishuBotError.message("无法建立机器人进程锁。") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw FeishuBotError.message("已有换台或 ht bot run 正在监听此机器人。")
        }
        return fd
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw FeishuBotError.message("机器人状态目录不能是符号链接。") }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func secureWrite(_ data: Data, name: String) throws {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func access<T>(write: Bool = false, _ action: (inout FeishuSavedState) throws -> T) throws -> T {
        mutex.lock()
        defer { mutex.unlock() }
        try prepareDirectory()
        let fd = Darwin.open(
            directory.appendingPathComponent("config.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw FeishuBotError.message("无法读取机器人配置。") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw FeishuBotError.message("无法锁定机器人配置。") }
        defer { flock(fd, LOCK_UN) }
        let url = directory.appendingPathComponent("binding.json")
        var state = FeishuSavedState()
        if FileManager.default.fileExists(atPath: url.path) {
            guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw FeishuBotError.message("机器人配置不能是符号链接。")
            }
            state = try JSONDecoder().decode(FeishuSavedState.self, from: Data(contentsOf: url))
        }
        let result = try action(&state)
        if write { try secureWrite(JSONEncoder().encode(state), name: "binding.json") }
        return result
    }
}
