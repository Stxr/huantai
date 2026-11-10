import Darwin
import Foundation

/// The target travels only inside Huantai; the official application is launched without this URL.
struct DeepSeekHarnessOpenTarget: Equatable {
    let sessionID: String
    let dataDir: String

    init?(sessionID: String, dataDir: String) {
        guard !sessionID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
            sessionID.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil,
            let canonical = Self.canonicalDirectory(dataDir)
        else { return nil }
        self.sessionID = sessionID
        self.dataDir = canonical
    }

    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme?.lowercased() == "dsh", components.host?.lowercased() == "open",
            ["", "/"].contains(components.path), components.user == nil,
            components.password == nil, components.port == nil, components.fragment == nil,
            let items = components.queryItems, items.count == 2,
            Set(items.map(\.name)) == Set(["session", "dataDir"]),
            let session = items.first(where: { $0.name == "session" })?.value,
            let directory = items.first(where: { $0.name == "dataDir" })?.value
        else { return nil }
        self.init(sessionID: session, dataDir: directory)
    }

    static func canonicalDirectory(_ path: String) -> String? {
        guard path.hasPrefix("/"), path.utf8.count <= 3072,
            !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path
    }

    var urlString: String {
        var components = URLComponents(string: SourceOpening.deepSeekHarnessURL)!
        components.queryItems = [
            URLQueryItem(name: "session", value: sessionID),
            URLQueryItem(name: "dataDir", value: dataDir),
        ]
        return components.url!.absoluteString
    }
}

enum DeepSeekHarnessBridgeError: LocalizedError {
    case missingDiscovery
    case invalidDiscovery
    case invalidResponse
    case responseTooLarge
    case deadline
    case result(String)

    var errorDescription: String? {
        switch self {
        case .missingDiscovery, .deadline:
            return "DeepSeek Harness 桌面桥接未在期限内确认会话已打开；请确认 desktop 配置的桥接插件和桌面窗口已就绪。"
        case .invalidDiscovery:
            return "DeepSeek Harness 桌面桥接发现文件无效、权限不安全或与来源数据目录不匹配。"
        case .invalidResponse:
            return "DeepSeek Harness 桌面桥接返回了无效或不匹配的确认。"
        case .responseTooLarge:
            return "DeepSeek Harness 桌面桥接响应过大。"
        case .result(let status):
            switch status {
            case "not-found": return "DeepSeek Harness 未找到目标会话。"
            case "archived": return "目标 DeepSeek Harness 会话已归档。"
            case "unsupported-target": return "DeepSeek Harness 暂不支持打开此目标。"
            case "load-failed": return "DeepSeek Harness 加载目标会话失败。"
            case "superseded": return "此次 DeepSeek Harness 会话切换已被后续请求取代。"
            case "instance-mismatch": return "DeepSeek Harness 桌面实例已变化，请重试。"
            case "invalid-request": return "DeepSeek Harness 拒绝了会话切换请求。"
            default: return "DeepSeek Harness 未在期限内确认会话已打开。"
            }
        }
    }
}

struct DeepSeekHarnessBridgeDiscovery: Decodable {
    let protocolVersion: Int
    let instanceId: String
    let pid: Int
    let profile: String
    let dataDir: String
    let endpoint: String
    let token: String
    let startedAt: Double

    func validated(for target: DeepSeekHarnessOpenTarget) throws -> URL {
        guard protocolVersion == 1, profile == "desktop", pid > 0,
            !instanceId.isEmpty, instanceId.utf8.count <= 512,
            !instanceId.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
            dataDir == target.dataDir,
            DeepSeekHarnessOpenTarget.canonicalDirectory(dataDir) == dataDir,
            token.utf8.count == 64,
            token.range(of: "^[A-Fa-f0-9]{64}$", options: .regularExpression) != nil,
            startedAt.isFinite, startedAt > 0,
            let components = URLComponents(string: endpoint), let port = components.port,
            (1...65535).contains(port),
            endpoint == "http://127.0.0.1:\(port)/huantai/session-bridge/v1/open",
            let url = components.url
        else { throw DeepSeekHarnessBridgeError.invalidDiscovery }
        return url
    }

    static func read(for target: DeepSeekHarnessOpenTarget) throws -> Self {
        let directory = URL(fileURLWithPath: target.dataDir)
            .appendingPathComponent("huantai-bridge", isDirectory: true)
        let directoryFD = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else {
            throw errno == ENOENT
                ? DeepSeekHarnessBridgeError.missingDiscovery : .invalidDiscovery
        }
        defer { Darwin.close(directoryFD) }
        var directoryInfo = stat()
        guard fstat(directoryFD, &directoryInfo) == 0,
            directoryInfo.st_uid == getuid(), directoryInfo.st_mode & 0o7777 == 0o700
        else { throw DeepSeekHarnessBridgeError.invalidDiscovery }
        let descriptor = openat(directoryFD, "desktop.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw errno == ENOENT
                ? DeepSeekHarnessBridgeError.missingDiscovery : .invalidDiscovery
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            info.st_uid == getuid(), info.st_mode & 0o7777 == 0o600,
            info.st_size > 0, info.st_size <= 16 * 1024
        else { throw DeepSeekHarnessBridgeError.invalidDiscovery }
        do {
            let data = try handle.read(upToCount: 16 * 1024 + 1) ?? Data()
            guard data.count <= 16 * 1024 else { throw DeepSeekHarnessBridgeError.invalidDiscovery }
            let discovery = try JSONDecoder().decode(Self.self, from: data)
            _ = try discovery.validated(for: target)
            return discovery
        } catch {
            throw DeepSeekHarnessBridgeError.invalidDiscovery
        }
    }
}

protocol DeepSeekHarnessBridgeTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// One bounded, ephemeral connection. Refuse redirects before credentials could leave loopback.
struct DeepSeekHarnessBridgeHTTPTransport: DeepSeekHarnessBridgeTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let transfer = DeepSeekHarnessBridgeTransfer()
        return try await transfer.send(request)
    }
}

private final class DeepSeekHarnessBridgeTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let limit = 64 * 1024
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var session: URLSession?
    private var response: HTTPURLResponse?
    private var data = Data()
    private var failure: Error?

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.connectionProxyDictionary = [:]
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = request.timeoutInterval
            configuration.timeoutIntervalForResource = request.timeoutInterval
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        failure = DeepSeekHarnessBridgeError.invalidResponse
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse,
            response.expectedContentLength <= Int64(Self.limit),
            response.mimeType?.lowercased() == "application/json"
        else {
            failure =
                response.expectedContentLength > Int64(Self.limit)
                ? DeepSeekHarnessBridgeError.responseTooLarge : .invalidResponse
            completionHandler(.cancel)
            return
        }
        self.response = response
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard self.data.count + data.count <= Self.limit else {
            failure = DeepSeekHarnessBridgeError.responseTooLarge
            dataTask.cancel()
            return
        }
        self.data.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer {
            continuation = nil
            session.finishTasksAndInvalidate()
            self.session = nil
        }
        if let error = failure ?? error {
            continuation?.resume(throwing: error)
        } else if let response {
            continuation?.resume(returning: (data, response))
        } else {
            continuation?.resume(throwing: DeepSeekHarnessBridgeError.invalidResponse)
        }
    }
}

struct DeepSeekHarnessBridgeClient {
    var transport: any DeepSeekHarnessBridgeTransport = DeepSeekHarnessBridgeHTTPTransport()
    var readDiscovery: (DeepSeekHarnessOpenTarget) throws -> DeepSeekHarnessBridgeDiscovery =
        DeepSeekHarnessBridgeDiscovery.read
    var retryDelay: UInt64 = 150_000_000

    private struct Payload: Encodable {
        let protocolVersion = 1
        let instanceId: String
        let requestId: String
        let sessionId: String
        let dataDir: String
        let expiresAt: Int64
    }

    private struct Result: Decodable {
        let protocolVersion: Int
        let requestId: String
        let sessionId: String
        let status: String
    }

    func open(_ target: DeepSeekHarnessOpenTarget, deadline: TimeInterval) async throws {
        let requestID = UUID().uuidString
        let remaining = min(15, deadline - ProcessInfo.processInfo.systemUptime)
        guard remaining > 0 else { throw DeepSeekHarnessBridgeError.deadline }
        let expiresAt = Int64((Date().timeIntervalSince1970 + remaining) * 1000)
        while ProcessInfo.processInfo.systemUptime < deadline {
            do {
                let discovery = try readDiscovery(target)
                let endpoint = try discovery.validated(for: target)
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.setValue("Bearer " + discovery.token, forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.timeoutInterval = max(0.001, deadline - ProcessInfo.processInfo.systemUptime)
                request.httpBody = try JSONEncoder().encode(
                    Payload(
                        instanceId: discovery.instanceId, requestId: requestID, sessionId: target.sessionID,
                        dataDir: target.dataDir, expiresAt: expiresAt))
                let (data, response) = try await transport.send(request)
                guard data.count <= 64 * 1024,
                    response.mimeType?.lowercased() == "application/json",
                    let result = try? JSONDecoder().decode(Result.self, from: data),
                    result.protocolVersion == 1, result.requestId == requestID,
                    result.sessionId == target.sessionID
                else { throw DeepSeekHarnessBridgeError.invalidResponse }
                let allowedHTTP: Set<Int>
                switch result.status {
                case "not-ready": allowedHTTP = [200, 503]
                case "invalid-request": allowedHTTP = [200, 400]
                case "instance-mismatch": allowedHTTP = [200, 409]
                case "opened", "accepted", "not-found", "archived", "unsupported-target",
                    "load-failed", "timeout", "superseded":
                    allowedHTTP = [200]
                default: throw DeepSeekHarnessBridgeError.invalidResponse
                }
                guard allowedHTTP.contains(response.statusCode) else {
                    throw DeepSeekHarnessBridgeError.invalidResponse
                }
                if result.status == "opened" {
                    guard ProcessInfo.processInfo.systemUptime <= deadline else {
                        throw DeepSeekHarnessBridgeError.deadline
                    }
                    return
                }
                if !["not-ready", "accepted"].contains(result.status) {
                    throw DeepSeekHarnessBridgeError.result(result.status)
                }
            } catch let error as DeepSeekHarnessBridgeError {
                if case .missingDiscovery = error {
                    // Application/plugin may still be starting.
                } else {
                    throw error
                }
            } catch {
                // Network failures can follow a successful switch with a lost reply. Keep the ID.
            }
            let delay = min(Double(retryDelay), max(0, deadline - ProcessInfo.processInfo.systemUptime) * 1e9)
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay)) }
        }
        throw DeepSeekHarnessBridgeError.deadline
    }
}

/// Covers application launch and bridge acknowledgement with a single deadline and callback.
final class DeepSeekHarnessOpenOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: ((Error?) -> Void)?
    private var timeout: DispatchWorkItem?
    private let deadline: TimeInterval
    private let client: DeepSeekHarnessBridgeClient

    init(
        client: DeepSeekHarnessBridgeClient = .init(), timeout: TimeInterval = 15,
        completion: @escaping (Error?) -> Void
    ) {
        self.client = client
        self.completion = completion
        self.deadline = ProcessInfo.processInfo.systemUptime + timeout
        let item = DispatchWorkItem { [self] in finish(DeepSeekHarnessBridgeError.deadline) }
        self.timeout = item
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
    }

    func launched(error: Error?, target: DeepSeekHarnessOpenTarget?) {
        if let error {
            finish(error)
            return
        }
        guard let target else {
            finish(nil)
            return
        }
        Task {
            do {
                try await client.open(target, deadline: deadline)
                finish(nil)
            } catch { finish(error) }
        }
    }

    private func finish(_ error: Error?) {
        lock.lock()
        let callback = completion
        completion = nil
        timeout?.cancel()
        timeout = nil
        lock.unlock()
        // App/CLI callers already service the main queue. Keep callback state on that queue.
        if let callback { DispatchQueue.main.async { callback(error) } }
    }
}
