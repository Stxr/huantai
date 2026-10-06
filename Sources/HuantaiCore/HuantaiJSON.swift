import Foundation

/// Shared wire and persistence format. Fractional seconds preserve the ordering of replies
/// within one second; existing whole-second ISO 8601 indexes remain readable.
public enum HuantaiJSON {
    public static func encoder() -> JSONEncoder {
        let codec = ISO8601DateCodec()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(codec.string(from: date))
        }
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let codec = ISO8601DateCodec()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = codec.date(from: text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "无效 ISO 8601 日期")
            }
            return date
        }
        return decoder
    }
}

/// One codec per operation avoids repeatedly constructing formatters for every record.
final class ISO8601DateCodec {
    private let fractional = ISO8601DateFormatter()
    private let whole = ISO8601DateFormatter()
    init() { fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds] }
    func date(from text: String) -> Date? { fractional.date(from: text) ?? whole.date(from: text) }
    func string(from date: Date) -> String { fractional.string(from: date) }
}
