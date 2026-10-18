import Darwin
import Foundation

/// Codo-compatible, optional enrichment. Only supplemental IDs belong to Huantai;
/// Botmux databases and credentials are never modified or opened by this resolver.
final class BotmuxTopics: @unchecked Sendable {
    static let shared = BotmuxTopics(
        directory: ProcessInfo.processInfo.environment["HUANTAI_HOME"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/huantai"))
    private let directory: URL
    private let lookup: @Sendable ([String]) throws -> Data
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "huantai.botmux-topics")
    private var ids: [String: String]
    private var attempted: [String: Date] = [:]
    private var pending = Set<String>()
    private var scheduled = false

    init(
        directory: URL,
        lookup: @escaping @Sendable ([String]) throws -> Data = { try LarkTopicLookup.fetch($0) }
    ) {
        self.directory = directory
        self.lookup = lookup
        ids =
            (try? JSONDecoder().decode(
                [String: String].self,
                from: Data(contentsOf: directory.appendingPathComponent("botmux-topics.json")))) ?? [:]
    }

    func topic(root: String) -> String? {
        guard Self.validRoot(root) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let id = ids[root], Self.validTopic(id) { return id }
        if Date().timeIntervalSince(attempted[root] ?? .distantPast) >= 30 {
            pending.insert(root)
            if !scheduled {
                scheduled = true
                queue.asyncAfter(deadline: .now() + 0.1) { self.resolvePending() }
            }
        }
        return nil
    }

    private func resolvePending() {
        lock.lock()
        let batch = Array(pending.sorted().prefix(50))
        for root in batch {
            pending.remove(root)
            attempted[root] = Date()
        }
        lock.unlock()
        if let data = try? lookup(batch) {
            let found = Self.parse(data, requested: Set(batch))
            lock.lock()
            ids.merge(found) { _, new in new }
            let snapshot = ids
            lock.unlock()
            if !found.isEmpty, let encoded = try? JSONEncoder().encode(snapshot) {
                try? FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                let file = directory.appendingPathComponent("botmux-topics.json")
                // Atomic protected write; no message bodies or tokens are cached.
                try? encoded.write(to: file, options: [.atomic, .completeFileProtection])
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
        }
        lock.lock()
        scheduled = !pending.isEmpty
        if scheduled { queue.asyncAfter(deadline: .now() + 0.1) { self.resolvePending() } }
        lock.unlock()
    }

    static func parse(_ data: Data, requested: Set<String>) -> [String: String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let body = object["data"] as? [String: Any], let rows = body["messages"] as? [[String: Any]]
        else { return [:] }
        var result: [String: String] = [:]
        for row in rows {
            guard let root = row["message_id"] as? String, requested.contains(root), validRoot(root),
                let topic = row["thread_id"] as? String, validTopic(topic)
            else { continue }
            result[root] = topic
        }
        return result
    }
    static func validRoot(_ value: String) -> Bool {
        value.count <= 128 && value.range(of: "^om_[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }
    static func validTopic(_ value: String) -> Bool {
        value.count <= 128 && value.range(of: "^omt_[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }
}

private enum LarkTopicLookup {
    static func fetch(_ roots: [String]) throws -> Data {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var directories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(
            String.init)
        directories += [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        let nvm = URL(fileURLWithPath: home + "/.local/share/nvm")
        directories +=
            ((try? FileManager.default.contentsOfDirectory(at: nvm, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent > $1.lastPathComponent }.map {
                $0.appendingPathComponent("bin").path
            }
        guard
            let executable = directories.map({ $0 + "/lark-cli" }).first(where: {
                FileManager.default.isExecutableFile(atPath: $0)
            })
        else { throw CocoaError(.fileNoSuchFile) }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [
            "im", "+messages-mget", "--as", "user", "--message-ids", roots.joined(separator: ","),
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = directories.joined(separator: ":")
        process.environment = environment
        try process.run()
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }
        let fd = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        var result = Data()
        var bytes = [UInt8](repeating: 0, count: 8192)
        while ProcessInfo.processInfo.systemUptime < deadline {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count > 0 {
                result.append(contentsOf: bytes.prefix(count))
                if result.count > 64 * 1024 * 1024 { throw CocoaError(.fileReadTooLarge) }
            } else if count == 0 {
                while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                guard !process.isRunning else { throw CocoaError(.fileReadUnknown) }
                guard process.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
                return result
            } else if errno == EAGAIN || errno == EINTR {
                Thread.sleep(forTimeInterval: 0.01)
            } else {
                throw CocoaError(.fileReadUnknown)
            }
        }
        throw CocoaError(.fileReadUnknown)
    }
}
