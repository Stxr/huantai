import Foundation

public enum CodexTaskState: String, CaseIterable, Codable, Sendable {
    case started, completed, failed
}

public struct CodexTaskEvent: Equatable, Sendable {
    public let sessionID: String
    public let turnID: String
    public let state: CodexTaskState
}

/// Tails lifecycle metadata only. Historical events, tool output and assistant text never notify.
/// Used alongside native hooks because Codex has no terminal-error command hook.
public final class CodexTaskMonitor {
    private struct Cursor {
        var offset: UInt64 = 0
        var inode: UInt64 = 0
        var buffer = Data()
        var droppingLine = false
        var sessionID: String
        var activeTurn: String?
        var terminalTurn: String?
    }
    private let root: URL
    private let enabledAt: Date
    private let dates = ISO8601DateFormatter()
    private let wholeDates = ISO8601DateFormatter()
    private var cursors: [URL: Cursor] = [:]
    private var lastDiscovery = Date.distantPast
    private var paths = Set<URL>()
    private var delivered = Set<String>()
    private var deliveryOrder: [String] = []

    public init(root: URL, enabledAt: Date = Date()) {
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        self.enabledAt = enabledAt
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        _ = poll(baseline: true)
    }

    /// Hook callbacks can discover resumed transcripts without waiting for directory discovery.
    public func includeTranscript(_ url: URL) {
        if allowed(url) { paths.insert(url.standardizedFileURL) }
    }

    public func poll() -> [CodexTaskEvent] { poll(baseline: false) }

    private func allowed(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return ["sessions", "archived_sessions"].contains {
            path.hasPrefix(root.appendingPathComponent($0).path + "/")
        } && url.pathExtension == "jsonl"
    }

    private func poll(baseline: Bool) -> [CodexTaskEvent] {
        let now = Date()
        if now.timeIntervalSince(lastDiscovery) >= 5 {
            for directory in ["sessions", "archived_sessions"] {
                let folder = root.appendingPathComponent(directory)
                if let enumerator = FileManager.default.enumerator(
                    at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                {
                    for case let url as URL in enumerator where allowed(url) { paths.insert(url) }
                }
            }
            lastDiscovery = now
        }
        var events: [CodexTaskEvent] = []
        for url in paths.sorted(by: { $0.path < $1.path }) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                let size = (attributes[.size] as? NSNumber)?.uint64Value,
                let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
            else { continue }
            var cursor =
                cursors[url]
                ?? Cursor(sessionID: String(url.deletingPathExtension().lastPathComponent.suffix(36)))
            if cursor.inode != inode || size < cursor.offset {
                cursor = Cursor(inode: inode, sessionID: cursor.sessionID)
            }
            if baseline && size > 64 * 1024 {
                cursor.offset = size - 64 * 1024
                cursor.droppingLine = true
            }
            guard size > cursor.offset, let handle = try? FileHandle(forReadingFrom: url) else {
                cursors[url] = cursor
                continue
            }
            defer { try? handle.close() }
            do {
                try handle.seek(toOffset: cursor.offset)
                // Bound work per tick even when a tool appends a very large output.
                let end = min(size, cursor.offset + 4 * 1024 * 1024)
                while cursor.offset < end {
                    guard let chunk = try handle.read(upToCount: Int(min(64 * 1024, end - cursor.offset))),
                        !chunk.isEmpty
                    else { break }
                    cursor.offset += UInt64(chunk.count)
                    cursor.buffer.append(chunk)
                    while let boundary = cursor.buffer.firstIndex(of: 10) {
                        if !cursor.droppingLine {
                            consume(
                                Data(cursor.buffer.prefix(upTo: boundary)), cursor: &cursor,
                                silent: baseline, events: &events)
                        }
                        cursor.buffer.removeSubrange(...boundary)
                        cursor.droppingLine = false
                    }
                    if cursor.buffer.count > 1024 * 1024 {
                        cursor.buffer.removeAll(keepingCapacity: true)
                        cursor.droppingLine = true
                    }
                }
            } catch {
                // Unavailable or partially replaced files are retried next tick.
            }
            cursors[url] = cursor
        }
        return events
    }

    private func consume(
        _ line: Data, cursor: inout Cursor, silent: Bool, events: inout [CodexTaskEvent]
    ) {
        guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let payload = event["payload"] as? [String: Any]
        else { return }
        if event["type"] as? String == "session_meta" {
            if let id = payload["id"] as? String { cursor.sessionID = id }
            return
        }
        guard event["type"] as? String == "event_msg", let type = payload["type"] as? String else { return }
        let explicitTurn = payload["turn_id"] as? String
        var state: CodexTaskState?
        switch type {
        case "task_started":
            guard let turn = explicitTurn else { return }
            cursor.activeTurn = turn
            if cursor.terminalTurn != turn { state = .started }
        case "task_complete":
            // Current Codex also persists failed turns as task_complete with an error object.
            state = payload["error"] as? [String: Any] == nil ? .completed : .failed
        case "error":
            // Codex's history replay excludes these errors from turn failure.
            let info = payload["codex_error_info"]
            let name = info as? String ?? (info as? [String: Any])?.keys.first ?? ""
            guard !["thread_rollback_failed", "active_turn_not_steerable"].contains(name),
                payload["will_retry"] as? Bool != true
            else { return }
            state = .failed
        case "turn_aborted":
            if payload["error"] as? [String: Any] != nil {
                state = .failed
            } else {
                cursor.activeTurn = nil
                return
            }
        default: return
        }
        guard let state, let turn = explicitTurn ?? cursor.activeTurn else { return }
        if state != .started {
            guard cursor.terminalTurn != turn else { return }
            cursor.terminalTurn = turn
            cursor.activeTurn = nil
        }
        guard !silent, let stamp = event["timestamp"] as? String,
            let date = dates.date(from: stamp) ?? wholeDates.date(from: stamp), date >= enabledAt
        else { return }
        let key = cursor.sessionID + ":" + turn + ":" + state.rawValue
        guard delivered.insert(key).inserted else { return }
        deliveryOrder.append(key)
        if deliveryOrder.count > 2048 { delivered.remove(deliveryOrder.removeFirst()) }
        events.append(CodexTaskEvent(sessionID: cursor.sessionID, turnID: turn, state: state))
    }
}
