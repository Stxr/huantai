import Foundation

/// One in-flight read per target. Network work never runs under SessionStore's file lock.
final class RemoteCodexScanner: @unchecked Sendable {
    typealias Reader = (RemoteTarget) throws -> [SessionRecord]
    struct Result {
        var sessions: [SessionRecord]
        var status: String
    }
    private struct Entry {
        var target: RemoteTarget
        var result: Result
        var attemptedAt = Date.distantPast
        var pending: DispatchGroup?
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let reader: Reader

    init(reader: @escaping Reader = RemoteCodexReader.read) { self.reader = reader }

    func scan(_ target: RemoteTarget, cached: [SessionRecord], wait: Bool = false) -> Result {
        lock.lock()
        let key = RemoteCodexReader.prefix(target) + (target.botmuxRoot ?? "~/.botmux/data")
        var entry =
            entries[key]
            ?? Entry(
                target: target,
                result: Result(
                    sessions: cached, status: cached.isEmpty ? "正在连接…" : "显示上次缓存；正在连接…"))
        if entry.pending == nil && Date().timeIntervalSince(entry.attemptedAt) >= 30 {
            let group = DispatchGroup()
            group.enter()
            entry.pending = group
            entry.attemptedAt = Date()
            entries[key] = entry
            DispatchQueue.global(qos: .utility).async { [self] in
                let result: Result
                do {
                    let sessions = try reader(target)
                    result = Result(sessions: sessions, status: "已连接（SSH 只读）；\(sessions.count) 个会话")
                } catch {
                    lock.lock()
                    let previous = entries[key]?.result.sessions ?? cached
                    lock.unlock()
                    result = Result(
                        sessions: previous,
                        status: "未连接；\(previous.isEmpty ? "暂无缓存" : "显示上次缓存")。\(error.localizedDescription)")
                }
                lock.lock()
                entries[key]?.result = result
                entries[key]?.pending = nil
                lock.unlock()
                group.leave()
            }
        }
        lock.unlock()
        if wait { entry.pending?.wait() }
        lock.lock()
        defer { lock.unlock() }
        var result = entries[key]?.result ?? entry.result
        for index in result.sessions.indices { result.sessions[index].machine = target.name }
        return result
    }
}
