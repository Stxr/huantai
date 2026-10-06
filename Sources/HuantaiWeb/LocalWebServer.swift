import Foundation
import HuantaiCore
import Network

/// An in-process detail view. It never listens on a LAN interface.
public final class LocalWebServer {
    public enum ServerError: LocalizedError {
        case unavailable
        case startTimedOut
        public var errorDescription: String? {
            switch self {
            case .unavailable: return "本地 Web 服务无法启动，请检查端口是否占用。"
            case .startTimedOut: return "本地 Web 服务启动超时。"
            }
        }
    }

    public let url: URL
    private let port: UInt16
    private let queue = DispatchQueue(label: "huantai.local-web")
    private let queueKey = DispatchSpecificKey<Bool>()
    private let router: WebRequestRouter
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]

    public init(store: SessionStore, port: UInt16 = 18784) {
        precondition(port != 0, "A fixed local port is required.")
        self.port = port
        self.url = URL(string: "http://127.0.0.1:\(port)/")!
        let token = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
        self.router = WebRequestRouter(
            port: port, token: token,
            getSnapshot: {
                try WebSnapshotEncoder.encode(store.snapshot())
            },
            setFavorite: { id, value in
                try store.setFavorite(id: id, value: value)
            },
            setCompleted: { id, value in try store.setCompleted(id: id, value: value) },
            openSession: { id in
                guard let session = try store.snapshot().sessions.first(where: { $0.id == id }),
                    let value = session.openURL, let url = URL(string: value),
                    SessionStore.validatedOpenURL(value) != nil
                else { throw HuantaiError.openUnavailable }
                let completed = DispatchSemaphore(value: 0)
                let lock = NSLock()
                var openingError: Error?
                DispatchQueue.main.async {
                    SourceOpening.open(url) { error in
                        lock.lock()
                        openingError = error
                        lock.unlock()
                        completed.signal()
                    }
                }
                guard completed.wait(timeout: .now() + 5) == .success else {
                    throw HuantaiError.openUnavailable
                }
                lock.lock()
                let error = openingError
                lock.unlock()
                if let error { throw error }
            })
        queue.setSpecific(key: queueKey, value: true)
    }

    /// Resolves only after the listener is ready or failed. Run once during app setup.
    public func start() throws {
        if synchronized({ listener != nil }) { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = false
        let candidate = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        let stateLock = NSLock()
        var startupError: Error?
        var settled = false
        candidate.stateUpdateHandler = { state in
            stateLock.lock()
            defer { stateLock.unlock() }
            guard !settled else { return }
            switch state {
            case .ready:
                settled = true
                ready.signal()
            case .failed:
                startupError = ServerError.unavailable
                settled = true
                ready.signal()
            default: break
            }
        }
        candidate.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        synchronized { listener = candidate }
        candidate.start(queue: queue)
        guard ready.wait(timeout: .now() + 4) == .success else {
            stop()
            throw ServerError.startTimedOut
        }
        stateLock.lock()
        let error = startupError
        stateLock.unlock()
        if let error {
            stop()
            throw error
        }
    }

    public func stop() {
        synchronized {
            listener?.cancel()
            listener = nil
            for connection in connections.values { connection.cancel() }
            connections.removeAll()
        }
    }

    deinit { stop() }

    private func synchronized<T>(_ block: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return block() }
        return queue.sync(execute: block)
    }

    private func accept(_ connection: NWConnection) {
        guard case .hostPort(let host, _) = connection.endpoint,
            host == .ipv4(.loopback), connections.count < 32
        else {
            connection.cancel()
            return
        }
        let id = UUID()
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.connections.removeValue(forKey: id)
            default: break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, id: id, accumulated: Data())
        queue.asyncAfter(deadline: .now() + 10) { [weak self, weak connection] in
            guard let self, let connection, self.connections[id] != nil else { return }
            connection.cancel()
            self.connections.removeValue(forKey: id)
        }
    }

    private func receive(on connection: NWConnection, id: UUID, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) {
            [weak self, weak connection] bytes, _, complete, error in
            guard let self, let connection, self.connections[id] != nil else { return }
            var data = accumulated
            if let bytes { data.append(bytes) }
            switch WebRequestParser.parse(data) {
            case .invalid:
                self.send(.text(400, "请求无效。"), on: connection, id: id)
            case .request(let request):
                self.send(self.router.response(to: request), on: connection, id: id)
            case .incomplete:
                if complete || error != nil {
                    connection.cancel()
                    self.connections.removeValue(forKey: id)
                } else {
                    self.receive(on: connection, id: id, accumulated: data)
                }
            }
        }
    }

    private func send(_ response: WebHTTPResponse, on connection: NWConnection, id: UUID) {
        connection.send(
            content: response.encoded(),
            completion: .contentProcessed { [weak self, weak connection] _ in
                connection?.cancel()
                self?.connections.removeValue(forKey: id)
            })
    }
}

/// Keep reply-date precision and ordering identical to the shared local index.
enum WebSnapshotEncoder {
    static func encode(_ value: IndexSnapshot, now: Date = Date()) throws -> Data {
        var snapshot = value
        snapshot.sessions = snapshot.filteredSessions(includeCompleted: true)
        struct Envelope: Encodable {
            let snapshot: IndexSnapshot
            let usageProjection: UsageProjection
        }
        return try HuantaiJSON.encoder().encode(
            Envelope(
                snapshot: snapshot,
                usageProjection: .calculate(window: snapshot.usage.weekly, now: now)))
    }
}
