import CryptoKit
import Darwin
import Foundation

/// Executes a fixed read-only program; target paths travel as JSON, never shell syntax.
struct RemoteCodexReader {
    static func validate(_ target: RemoteTarget) throws {
        guard !target.id.isEmpty, !target.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            target.name.count <= 100, target.host.count <= 255, target.sessionRoot.count <= 4096,
            target.sessionRoot.hasPrefix("/") || target.sessionRoot == "~"
                || target.sessionRoot.hasPrefix("~/"),
            target.host.range(of: "^[A-Za-z0-9_][A-Za-z0-9_.@:-]*$", options: .regularExpression) != nil,
            !target.sessionRoot.isEmpty,
            !target.sessionRoot.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }
            )
        else { throw HuantaiError.invalidConfiguration("请填写名称、有效 SSH 主机和 Codex 数据目录。") }
        if target.botmuxEnabled, let root = target.botmuxRoot {
            guard root.count <= 4096, root.hasPrefix("/") || root == "~" || root.hasPrefix("~/"),
                !root.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { throw HuantaiError.invalidConfiguration("Botmux 数据目录需为远端绝对路径或 ~/ 路径。") }
        }
    }

    static func read(_ target: RemoteTarget, topics: BotmuxTopics = .shared) throws -> [SessionRecord] {
        try validate(target)
        let input = try JSONEncoder().encode(target).base64EncodedString()
        let program =
            "import base64\nargs = __import__('json').loads(base64.b64decode('\(input)'))\nroot_arg = args['sessionRoot']\nbotmux_root_arg = (args.get('botmuxRoot') or '~/.botmux/data') if args['botmuxEnabled'] else None\n"
            + RemoteCodexProgram.script
        return try decode(run(program, target: target), target: target, topics: topics)
    }

    static func search(
        _ target: RemoteTarget, query: String, isCancelled: @escaping () -> Bool
    ) throws -> SessionSearchResult {
        try validate(target)
        let arguments = try JSONEncoder().encode(["root": target.sessionRoot, "query": query]).base64EncodedString()
        let program = "import base64, json\nargs = json.loads(base64.b64decode('\(arguments)'))\n"
            + RemoteSessionSearchProgram.script
        struct Result: Decodable { var ids: [String]; var unreadable: Int }
        let result = try JSONDecoder().decode(
            Result.self, from: run(program, target: target, timeout: 120, isCancelled: isCancelled))
        return SessionSearchResult(
            matchingIDs: Set(result.ids.filter { UUID(uuidString: $0) != nil }.map { prefix(target) + $0 }),
            warnings: result.unreadable > 0 ? ["\(target.name) \(result.unreadable) 个会话正文不可读"] : [])
    }

    private static func run(
        _ program: String, target: RemoteTarget, timeout: TimeInterval = 20,
        isCancelled: () -> Bool = { false }
    ) throws -> Data {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputURL = directory.appendingPathComponent("input")
        let outputURL = directory.appendingPathComponent("output")
        try Data(program.utf8).write(to: inputURL)
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let stdin = try FileHandle(forReadingFrom: inputURL)
        let stdout = try FileHandle(forWritingTo: outputURL)
        defer {
            try? stdin.close()
            try? stdout.close()
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o",
            "ServerAliveInterval=5", "-o", "ServerAliveCountMax=1", target.host, "python3 -",
        ]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            let size = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if isCancelled() || Date() >= deadline || size > 16 * 1024 * 1024 {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
                throw HuantaiError.sourceUnavailable("远端读取超时或结果过大；请检查 SSH 连接。")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw HuantaiError.sourceUnavailable("SSH 读取失败，请确认免交互登录、python3 和 Codex 索引可用。")
        }
        let output = try Data(contentsOf: outputURL)
        guard output.count <= 16 * 1024 * 1024 else { throw HuantaiError.sourceUnavailable("远端结果过大。") }
        return output
    }

    static func applyingBotmuxPreference(_ session: SessionRecord, target: RemoteTarget) -> SessionRecord {
        guard !target.botmuxEnabled || session.source == "Codex" else { return session }
        var value = session
        value.source = "Codex"
        value.openURL = SourceOpening.codexURL(sessionID: value.nativeSessionID, remoteHost: target.host)
        value.openUnavailableReason = nil
        return value
    }

    static func prefix(_ target: RemoteTarget) -> String {
        // Host and root form the identity; renaming a target never transfers task state to another host.
        let identity = SHA256.hash(data: Data((target.host + "\n" + target.sessionRoot).utf8)).map {
            String(format: "%02x", $0)
        }.joined()
        return "remote:" + identity + ":"
    }

    static func decode(_ data: Data, target: RemoteTarget, topics: BotmuxTopics? = nil) throws
        -> [SessionRecord]
    {
        struct Row: Decodable {
            var id: String
            var title: String
            var cwd: String
            var reply: Double?
            var preview: String?
            var tokenUsage: SessionTokenUsage?
            var botmux: [RemoteBotmuxRoute]?
        }
        let rows = try JSONDecoder().decode([Row].self, from: data)
        var seen = Set<String>()
        return rows.filter { UUID(uuidString: $0.id) != nil && seen.insert($0.id).inserted }.map {
            let routes = target.botmuxEnabled ? ($0.botmux ?? []) : []
            let opening = RemoteBotmuxRoute.opening(routes, topics: topics)
            return SessionRecord(
                id: prefix(target) + $0.id, title: $0.title, cwd: $0.cwd,
                source: routes.isEmpty ? "Codex" : "Botmux", machine: target.name,
                lastAIReplyAt: $0.reply.map { Date(timeIntervalSince1970: $0) },
                lastAIReplyPreview: $0.preview.map { String($0.prefix(320)) },
                openURL: routes.isEmpty ? SourceOpening.codexURL(sessionID: $0.id, remoteHost: target.host) : opening.url,
                openUnavailableReason: routes.isEmpty
                    ? nil : opening.reason,
                tokenUsage: $0.tokenUsage)
        }
    }

}
