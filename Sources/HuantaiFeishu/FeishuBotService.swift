import Darwin
import Foundation
import HuantaiCore

private final class FeishuSnapshotCache: @unchecked Sendable {
    private let lock = NSLock()
    private var value: IndexSnapshot
    init(_ value: IndexSnapshot) { self.value = value }
    func read() -> IndexSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func update(_ value: IndexSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        self.value = value
    }
}

/// A foreground CLI or the menu-bar app owns the listener; no public HTTP server is required.
public final class FeishuBotService: @unchecked Sendable {
    private let store: SessionStore
    private let configuration: FeishuBotConfiguration
    private let refreshSessions: Bool

    public init(store: SessionStore, refreshSessions: Bool = false) {
        self.store = store
        configuration = FeishuBotConfiguration(dataDirectory: store.dataDirectory)
        self.refreshSessions = refreshSessions
    }

    public func run() async throws {
        let lock = try configuration.acquireListener()
        defer {
            flock(lock, LOCK_UN)
            close(lock)
        }
        let cache = FeishuSnapshotCache(
            (try? store.snapshot()) ?? .init(sessions: [], usage: .init(), sources: [], updatedAt: .now))
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.refreshLoop(cache) }
            group.addTask { try await self.connectionLoop(cache) }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    private func refreshLoop(_ cache: FeishuSnapshotCache) async throws {
        var nextUsage = Date.distantPast
        while !Task.isCancelled {
            if (try configuration.binding()) != nil {
                let snapshot = try? (refreshSessions ? store.refresh() : store.snapshot())
                if let snapshot { cache.update(snapshot) }
                if refreshSessions && Date() >= nextUsage {
                    nextUsage = Date().addingTimeInterval(300)
                    _ = try? store.refreshUsage()
                }
            }
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    private func connectionLoop(_ cache: FeishuSnapshotCache) async throws {
        var retries = 0
        while !Task.isCancelled {
            guard let binding = try configuration.binding() else {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }
            let api = FeishuAPI(appID: binding.appID, secret: binding.appSecret)
            let live = FeishuLiveConnection(
                configuration: configuration, bindingID: binding.id, api: api, cache: cache)
            do {
                try await live.run()
                retries = 0
            } catch {
                if Task.isCancelled { throw CancellationError() }
                retries = min(retries + 1, 5)
                // Do not log server payloads, credentials, or WebSocket signed URLs.
                let detail = (error as? FeishuBotError)?.localizedDescription ?? "连接中断，请检查网络及长连接订阅。"
                try? configuration.report(detail, bindingID: binding.id)
                for _ in 0..<min(30, 1 << retries) {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    if try configuration.binding()?.id != binding.id { break }
                }
            }
        }
    }
}

private actor FeishuLiveConnection {
    let configuration: FeishuBotConfiguration
    let bindingID: String
    let api: FeishuAPI
    let cache: FeishuSnapshotCache
    var pingInterval: Double = 120
    var lastPong = Date()
    var assembler = FeishuFrameAssembler()

    init(configuration: FeishuBotConfiguration, bindingID: String, api: FeishuAPI, cache: FeishuSnapshotCache)
    {
        self.configuration = configuration
        self.bindingID = bindingID
        self.api = api
        self.cache = cache
    }

    func run() async throws {
        try configuration.report("正在连接飞书…", bindingID: bindingID)
        let endpoint = try await api.endpoint()
        pingInterval = endpoint.pingInterval
        let socket = URLSession.shared.webSocketTask(with: endpoint.url)
        socket.maximumMessageSize = 4 * 1024 * 1024
        socket.resume()
        try await withTaskCancellationHandler {
            defer { socket.cancel(with: .goingAway, reason: nil) }
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.receive(socket) }
                group.addTask { try await self.heartbeat(socket, service: endpoint.service) }
                group.addTask { try await self.watchBinding() }
                group.addTask { try await self.sendPending() }
                defer {
                    group.cancelAll()
                    socket.cancel(with: .goingAway, reason: nil)
                }
                _ = try await group.next()
            }
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    private func watchBinding() async throws {
        while !Task.isCancelled {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            if try configuration.binding()?.id != bindingID { return }
        }
    }

    private func heartbeat(_ socket: URLSessionWebSocketTask, service: UInt64) async throws {
        while !Task.isCancelled {
            let ping = FeishuFrame(service: service, headers: ["type": "ping"])
            try await socket.send(.data(ping.encoded()))
            for second in 0..<Int(pingInterval) {
                guard let binding = try configuration.binding(), binding.id == bindingID else { return }
                if second % 5 == 0 {
                    try configuration.report(
                        binding.ownerID == nil ? "长连接已连接 · 等待配对" : "长连接已连接", bindingID: bindingID)
                }
                guard Date().timeIntervalSince(lastPong) < max(60, pingInterval * 2) else {
                    throw FeishuBotError.message("飞书心跳超时，正在重新连接。")
                }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func sendPending() async throws {
        while !Task.isCancelled {
            guard try configuration.binding()?.id == bindingID else { return }
            if let item = try configuration.pending(), item.bindingID == bindingID {
                try await api.send(item)
                try configuration.delivered(item.id)
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private func receive(_ socket: URLSessionWebSocketTask) async throws {
        let router = FeishuEventRouter(configuration: configuration)
        while !Task.isCancelled {
            let message = try await socket.receive()
            let data: Data
            switch message {
            case .data(let value): data = value
            case .string(let value): data = Data(value.utf8)
            @unknown default: continue
            }
            var frame = try FeishuFrame.decode(data)
            if frame.method == 0 {
                if frame.headers["type"] == "pong" { lastPong = Date() }
                if frame.headers["type"] == "pong",
                    let result = try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any],
                    let interval = result["PingInterval"] as? Double
                {
                    pingInterval = min(300, max(5, interval))
                }
                continue
            }
            guard frame.method == 1, frame.headers["type"] == "event",
                let payload = try assembler.receive(frame)
            else { continue }
            let began = Date()
            var response: [String: Any] = ["code": 200]
            do {
                if let callback = try router.handle(payload, snapshot: cache.read(), bindingID: bindingID) {
                    response["data"] = try JSONSerialization.data(withJSONObject: callback)
                        .base64EncodedString()
                }
            } catch {
                response = ["code": 500]
            }
            frame.headers["biz_rt"] = String(Int(Date().timeIntervalSince(began) * 1000))
            frame.payload = try JSONSerialization.data(withJSONObject: response)
            try await socket.send(.data(frame.encoded()))
        }
    }
}
