import Darwin
import Foundation

/// Short-lived stdio client for the already-authorized Codex CLI. It sends only initialization
/// and account/rateLimits/read. It never starts login, reads credential files, starts a turn,
/// consumes resets, persists raw responses or logs app-server output.
public struct CodexRateLimitsClient: Sendable {
    public init() {}

    public func fetch(
        executable: URL? = nil, timeout: TimeInterval = 15, includeResetCreditDetails: Bool = true
    ) throws -> UsageSummary {
        guard timeout.isFinite, timeout > 0 else { throw CodexRateLimitsError.invalidTimeout }
        let executable = try executable ?? Self.findExecutable()
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CodexRateLimitsError.executableUnavailable
        }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "-c", "analytics.enabled=false"]
        process.standardInput = input
        process.standardOutput = output
        // Deliberately discard stderr instead of collecting or persisting possible identity data.
        process.standardError = FileHandle.nullDevice
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
                let shutdownDeadline = ProcessInfo.processInfo.systemUptime + 0.2
                while process.isRunning, ProcessInfo.processInfo.systemUptime < shutdownDeadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
            try? output.fileHandleForReading.close()
        }
        do { try process.run() } catch {
            throw CodexRateLimitsError.launchFailed(code: (error as NSError).code)
        }
        let descriptor = output.fileHandleForReading.fileDescriptor
        let originalFlags = fcntl(descriptor, F_GETFL)
        guard originalFlags >= 0, fcntl(descriptor, F_SETFL, originalFlags | O_NONBLOCK) == 0 else {
            throw CodexRateLimitsError.transportFailed
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var buffer = Data()
        try send(
            [
                "id": 1, "method": "initialize",
                "params": [
                    "clientInfo": ["name": "huantai", "title": "换台", "version": "0.2.0"],
                    "capabilities": [
                        "experimentalApi": false, "requestAttestation": false,
                        // Prevent automatic gateway browser authorization. No login method is sent.
                        "explicitGatewayOauth": true,
                    ],
                ],
            ], to: input.fileHandleForWriting)
        _ = try receive(id: 1, descriptor: descriptor, buffer: &buffer, deadline: deadline, process: process)
        try send(["method": "initialized"], to: input.fileHandleForWriting)
        try send(
            [
                "id": 2, "method": "account/rateLimits/read",
                // Read expiry metadata as requested; no Luna Reserve experiment opt-in.
                "params": ["excludeResetCreditDetails": !includeResetCreditDetails],
            ], to: input.fileHandleForWriting)
        let payload = try receive(
            id: 2, descriptor: descriptor, buffer: &buffer,
            deadline: deadline, process: process)
        return payload.summary(observedAt: Date())
    }

    private static func findExecutable() throws -> URL {
        let bundled = SourceOpening.codexApplication()?.appendingPathComponent(
            "Contents/Resources/codex-cli/bin/codex"
        ).path
        let candidates = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"] + [bundled].compactMap { $0 }
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }
        // Inspect only PATH; never inspect authentication environment variables.
        if let searchPath = getenv("PATH") {
            for directory in String(cString: searchPath).split(separator: ":") where !directory.isEmpty {
                let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
                    .appendingPathComponent("codex")
                if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            }
        }
        throw CodexRateLimitsError.executableUnavailable
    }

    private func send(_ object: [String: Any], to handle: FileHandle) throws {
        do {
            var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            data.append(10)
            try handle.write(contentsOf: data)
        } catch { throw CodexRateLimitsError.transportFailed }
    }

    private func receive(
        id: Int, descriptor: Int32, buffer: inout Data,
        deadline: TimeInterval, process: Process
    ) throws -> Payload {
        while ProcessInfo.processInfo.systemUptime < deadline {
            while let boundary = buffer.firstIndex(of: 10) {
                let line = Data(buffer.prefix(upTo: boundary))
                buffer.removeSubrange(...boundary)
                guard let reply = try? JSONDecoder().decode(Reply.self, from: line) else {
                    // Non-protocol output is not retained or exposed; the bounded deadline applies.
                    continue
                }
                if reply.method != nil, reply.id != nil {
                    throw CodexRateLimitsError.unsupportedServerRequest(
                        requiresLogin: reply.method == "account/chatgptAuthTokens/refresh")
                }
                guard reply.id == id else { continue }
                if let error = reply.error {
                    throw CodexRateLimitsError.rpc(code: error.code, requiresLogin: error.requiresLogin)
                }
                guard let payload = reply.result else { throw CodexRateLimitsError.invalidResponse }
                return payload
            }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { break }
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
            let ready = Darwin.poll(&pollDescriptor, 1, Int32(max(1, min(250, remaining * 1000))))
            if ready < 0 {
                if errno == EINTR { continue }
                throw CodexRateLimitsError.transportFailed
            }
            if ready == 0 { continue }
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let count = Darwin.read(descriptor, &chunk, chunk.count)
            if count > 0 {
                buffer.append(contentsOf: chunk.prefix(count))
                guard buffer.count <= 2 * 1024 * 1024 else { throw CodexRateLimitsError.responseTooLarge }
            } else if count == 0 {
                throw CodexRateLimitsError.processExited(
                    code: process.isRunning ? nil : process.terminationStatus)
            } else if errno != EAGAIN && errno != EINTR {
                throw CodexRateLimitsError.transportFailed
            }
        }
        throw CodexRateLimitsError.timeout
    }

    private struct Reply: Decodable {
        var id: Int?
        var method: String?
        var result: Payload?
        var error: RPCError?
        enum CodingKeys: String, CodingKey { case id, method, result, error }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let numeric = try? container.decode(Int.self, forKey: .id) {
                id = numeric
            } else if let string = try? container.decode(String.self, forKey: .id) {
                id = Int(string) ?? -1
            } else {
                id = nil
            }
            method = try container.decodeIfPresent(String.self, forKey: .method)
            result = try container.decodeIfPresent(Payload.self, forKey: .result)
            error = try container.decodeIfPresent(RPCError.self, forKey: .error)
        }
    }
    private struct RPCError: Decodable {
        var code: Int?
        var requiresLogin: Bool
        enum CodingKeys: String, CodingKey { case code, message }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            code = try container.decodeIfPresent(Int.self, forKey: .code)
            // Classify transiently and discard the service message; only a Boolean survives.
            let message = (try container.decodeIfPresent(String.self, forKey: .message) ?? "").lowercased()
            requiresLogin = [
                "not logged", "unauthorized", "authentication", "chatgpt auth", "login", "sign in",
            ]
            .contains(where: { message.contains($0) })
        }
    }
    private struct Payload: Decodable {
        var rateLimits: Limits?
        var rateLimitsByLimitId: [String: Limits]?
        var rateLimitResetCredits: ResetCreditsPayload?

        func summary(observedAt: Date) -> UsageSummary {
            let limits: Limits? = rateLimitsByLimitId?["codex"] ?? rateLimits
            let candidates: [Window?] = [limits?.primary, limits?.secondary]
            var weekly: UsageWindow?
            let latestRepresentableReset = Date.distantFuture.timeIntervalSince1970
            for candidate in candidates {
                guard let window = candidate, let duration = window.windowDurationMins,
                    duration == 10080, window.usedPercent.isFinite,
                    window.usedPercent >= 0, window.usedPercent <= 100,
                    let reset = window.resetsAt, reset.isFinite, reset > 0,
                    reset <= latestRepresentableReset
                else { continue }
                weekly = UsageWindow(
                    usedPercent: window.usedPercent, windowDurationMins: duration,
                    resetsAt: Date(timeIntervalSince1970: reset))
                break
            }
            return UsageSummary(
                weekly: weekly, resetCount: rateLimitResetCredits?.availableCount,
                resetCredits: rateLimitResetCredits?.credits,
                observedAt: observedAt,
                status: "Codex app-server 实时读取", source: "codex-app-server")
        }
    }
    private struct Limits: Decodable {
        var primary: Window?
        var secondary: Window?
    }
    private struct Window: Decodable {
        var usedPercent: Double
        var windowDurationMins: Int?
        var resetsAt: Double?
    }
}

/// Error descriptions contain only fixed categories and numeric codes, never raw service data.
public enum CodexRateLimitsError: LocalizedError, Equatable {
    case executableUnavailable
    case invalidTimeout
    case launchFailed(code: Int)
    case transportFailed
    case timeout
    case responseTooLarge
    case processExited(code: Int32?)
    case invalidResponse
    case unsupportedServerRequest(requiresLogin: Bool)
    case rpc(code: Int?, requiresLogin: Bool)

    public var requiresLogin: Bool {
        switch self {
        case .rpc(_, let value), .unsupportedServerRequest(let value): return value
        default: return false
        }
    }
    public var errorDescription: String? {
        switch self {
        case .executableUnavailable: return "未找到可执行的 Codex CLI。"
        case .invalidTimeout: return "用量读取超时需为有效正数。"
        case .launchFailed(let code): return "Codex app-server 启动失败（系统码 \(code)）。"
        case .transportFailed: return "Codex 用量读取的本地 stdio 通道失败。"
        case .timeout: return "Codex 官方用量读取超时。"
        case .responseTooLarge: return "Codex 用量响应超出安全大小。"
        case .processExited(let code): return "Codex app-server 提前退出（状态 \(code.map(String.init) ?? "未知")）。"
        case .invalidResponse: return "Codex app-server 未返回有效用量响应。"
        case .unsupportedServerRequest(let login):
            return login ? "现有登录需要更新；换台不会启动登录或提供凭据。" : "Codex 请求了读取范围外的交互，已停止。"
        case .rpc(let code, let login):
            return "Codex 用量读取失败（RPC \(code.map(String.init) ?? "未知")）" + (login ? "；现有登录不可用，未启动登录。" : "。")
        }
    }
}
