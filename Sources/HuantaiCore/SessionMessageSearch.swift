import Foundation

/// Streams from the beginning, including archived histories and valid final lines without a newline.
/// Tool output, instructions, reasoning and progress messages are not search documents.
enum SessionMessageSearch {
    // JSON type values have exact quoted spellings. Escaped Unicode falls back to decoding,
    // so this fast path never drops an eligible event merely because of its encoding.
    private static let messageMarkers = [
        "\"message\"", "\"user_message\"", "\"task_complete\"",
        "\"user/message\"", "\"assistant/message\"",
        "\"user\\/message\"", "\"assistant\\/message\"", "\\u",
    ].map { Data($0.utf8) }

    static func contains(_ query: String, in url: URL, isCancelled: () -> Bool) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var buffer = Data()
        let newline = Data([10])
        var searchedBytes = 0
        while !isCancelled(), let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            buffer.append(chunk)
            while let end = buffer.range(
                of: newline,
                in: buffer.index(buffer.startIndex, offsetBy: searchedBytes)..<buffer.endIndex
            )?.lowerBound {
                if isCancelled() { return false }
                if matches(query, line: buffer.prefix(upTo: end)) { return true }
                buffer.removeSubrange(...end)
                searchedBytes = 0
            }
            searchedBytes = buffer.count
            if buffer.count > 32 * 1024 * 1024 {
                throw HuantaiError.sourceUnavailable("会话单条消息过大")
            }
        }
        return !isCancelled() && matches(query, line: buffer)
    }

    static func matches(_ query: String, line: Data) -> Bool {
        let mayBeSentMessage = line.range(of: Data("\"item_completed\"".utf8)) != nil
            && line.range(of: Data("botmux".utf8)) != nil
        guard mayBeSentMessage || messageMarkers.contains(where: { line.range(of: $0) != nil }) else { return false }
        guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            return false
        }
        return texts(event).contains { $0.localizedCaseInsensitiveContains(query) }
    }

    static func texts(_ event: [String: Any]) -> [String] {
        let type = event["type"] as? String
        let payload = event["payload"] as? [String: Any] ?? [:]
        if type == "response_item", payload["type"] as? String == "message" {
            let role = payload["role"] as? String
            let phase = payload["phase"] as? String
            if role == "user" || (role == "assistant" && (phase == nil || phase == "final_answer" || phase == "final")) {
                return [contentText(payload["content"])]
            }
        }
        if type == "event_msg" {
            if let sent = BotmuxSentMessage.text(in: payload) { return [sent] }
            if payload["type"] as? String == "user_message" { return [payload["message"] as? String ?? ""] }
            if payload["type"] as? String == "task_complete" { return [payload["last_agent_message"] as? String ?? ""] }
        }
        if type == "user/message" || type == "assistant/message",
            let data = event["data"] as? [String: Any] {
            let message = data["message"] as? [String: Any] ?? data
            return [contentText(message["content"])]
        }
        return []
    }

    private static func contentText(_ value: Any?) -> String {
        if let text = value as? String { return text }
        return (value as? [[String: Any]] ?? []).compactMap { part -> String? in
            guard [nil, "text", "input_text", "output_text"].contains(part["type"] as? String) else { return nil }
            return part["text"] as? String
        }.joined(separator: "\n")
    }
}
