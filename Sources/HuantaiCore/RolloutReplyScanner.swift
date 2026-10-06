import Foundation

/// Extracts visible AI reply timestamps and a bounded plain-text preview (progress and final replies).
public enum RolloutReplyScanner {
    struct Result {
        var lastAIReplyAt: Date?
        var preview: String?
        var committedOffset: UInt64
        var bytesRead: UInt64
    }

    public static func lastAIReply(in url: URL) throws -> Date? {
        try scan(in: url).lastAIReplyAt
    }

    /// Persist only a complete-line offset. A partial trailing JSON event is re-read next time.
    static func scan(
        in url: URL, startingAt: UInt64 = 0, previousReply: Date? = nil, previousPreview: String? = nil,
        limit: UInt64? = nil
    ) throws -> Result {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: startingAt)
        let decoder = JSONDecoder()
        let dates = ISO8601DateCodec()
        var buffer = Data()
        var latest = previousReply
        var preview = previousPreview
        var baseOffset = startingAt
        var committedOffset = startingAt
        var bytesRead: UInt64 = 0
        var droppingOversizedLine = false
        let maximumLineBytes = 32 * 1024 * 1024
        while true {
            let remaining = limit.map { $0 > startingAt + bytesRead ? $0 - startingAt - bytesRead : 0 }
            let count = Int(min(64 * 1024, remaining ?? 64 * 1024))
            guard count > 0, let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { break }
            bytesRead += UInt64(chunk.count)
            buffer.append(chunk)
            while let boundary = buffer.firstIndex(of: 10) {
                if !droppingOversizedLine,
                    let reply = visibleReply(
                        in: buffer.prefix(upTo: boundary), decoder: decoder, dates: dates),
                    latest == nil || reply.date >= latest!
                {
                    latest = reply.date
                    preview = reply.preview
                }
                baseOffset += UInt64(buffer.distance(from: buffer.startIndex, to: boundary) + 1)
                buffer.removeSubrange(...boundary)
                committedOffset = baseOffset
                droppingOversizedLine = false
            }
            if buffer.count > maximumLineBytes {
                baseOffset += UInt64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                droppingOversizedLine = true
            }
        }
        // A valid JSON event without a newline is usable, but its offset remains replayable.
        if !droppingOversizedLine, !buffer.isEmpty,
            let reply = visibleReply(in: buffer, decoder: decoder, dates: dates),
            latest == nil || reply.date >= latest!
        {
            latest = reply.date
            preview = reply.preview
        }
        return Result(
            lastAIReplyAt: latest, preview: preview, committedOffset: committedOffset, bytesRead: bytesRead)
    }

    public static func replyDate(in data: Data) -> Date? {
        visibleReply(in: data, decoder: JSONDecoder(), dates: ISO8601DateCodec())?.date
    }

    private static func visibleReply(in data: Data, decoder: JSONDecoder, dates: ISO8601DateCodec)
        -> (date: Date, preview: String?)?
    {
        guard let event = try? decoder.decode(Event.self, from: data) else { return nil }
        if event.type == "response_item", event.payload?.type == "message",
            event.payload?.role == "assistant",
            event.payload?.phase == nil
                || ["commentary", "final_answer", "final"].contains(event.payload?.phase ?? "")
        {
            guard let date = event.timestamp?.date(using: dates) else { return nil }
            return (date, previewText(event.payload?.content?.compactMap(\.text).joined(separator: " ")))
        }
        if event.type == "event_msg", event.payload?.type == "task_complete",
            event.payload?.lastAgentMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        {
            guard
                let date = event.payload?.completedAt?.date(using: dates)
                    ?? event.timestamp?.date(using: dates)
            else { return nil }
            return (date, previewText(event.payload?.lastAgentMessage))
        }
        return nil
    }

    private static func previewText(_ text: String?) -> String? {
        guard let text else { return nil }
        let plain = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !plain.isEmpty else { return nil }
        return String(plain.prefix(320))
    }

    private struct Event: Decodable {
        var timestamp: FlexibleDate?
        var type: String
        var payload: Payload?
    }
    private struct Payload: Decodable {
        var type: String?
        var role: String?
        var phase: String?
        var completedAt: FlexibleDate?
        var lastAgentMessage: String?
        var content: [TextPart]?
        struct TextPart: Decodable { var text: String? }
        private enum CodingKeys: String, CodingKey {
            case type, role, phase, content
            case completedAt = "completed_at"
            case lastAgentMessage = "last_agent_message"
        }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decodeIfPresent(String.self, forKey: .type)
            role = try container.decodeIfPresent(String.self, forKey: .role)
            phase = try container.decodeIfPresent(String.self, forKey: .phase)
            completedAt = try container.decodeIfPresent(FlexibleDate.self, forKey: .completedAt)
            lastAgentMessage = try container.decodeIfPresent(String.self, forKey: .lastAgentMessage)
            content = try? container.decodeIfPresent([TextPart].self, forKey: .content)
        }
    }
    private enum FlexibleDate: Decodable {
        case seconds(Double)
        case iso(String)
        case invalid
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self), number.isFinite {
                self = .seconds(number)
            } else if let text = try? container.decode(String.self) {
                self = .iso(text)
            } else {
                self = .invalid
            }
        }
        func date(using codec: ISO8601DateCodec) -> Date? {
            switch self {
            case .seconds(let value): return Date(timeIntervalSince1970: value)
            case .iso(let value): return codec.date(from: value)
            case .invalid: return nil
            }
        }
    }
}
