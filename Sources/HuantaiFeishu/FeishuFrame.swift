import Foundation

/// Wire fields follow the official larksuite/oapi-sdk-go ws/pbbp2 schema.
struct FeishuFrame: Equatable {
    var sequence: UInt64 = 0
    var logID: UInt64 = 0
    var service: UInt64 = 0
    var method: UInt64 = 0
    var headers: [String: String] = [:]
    var payload = Data()
    var encoding: String = ""
    var payloadType: String = ""
    var logIDNew: String = ""

    func encoded() -> Data {
        var data = Data()
        for (number, value) in [(1, sequence), (2, logID), (3, service), (4, method)] {
            data.appendVarint(UInt64(number << 3))
            data.appendVarint(value)
        }
        for key in headers.keys.sorted() {
            var header = Data()
            header.appendField(1, Data(key.utf8))
            header.appendField(2, Data(headers[key]!.utf8))
            data.appendField(5, header)
        }
        if !encoding.isEmpty { data.appendField(6, Data(encoding.utf8)) }
        if !payloadType.isEmpty { data.appendField(7, Data(payloadType.utf8)) }
        data.appendField(8, payload)
        if !logIDNew.isEmpty { data.appendField(9, Data(logIDNew.utf8)) }
        return data
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 4 * 1024 * 1024 else { throw invalidFrame }
        var frame = Self()
        var reader = ProtoReader(bytes: Array(data))
        while let field = try reader.next() {
            switch field.number {
            case 1: frame.sequence = field.integer ?? 0
            case 2: frame.logID = field.integer ?? 0
            case 3: frame.service = field.integer ?? 0
            case 4: frame.method = field.integer ?? 0
            case 5:
                var header = ProtoReader(bytes: Array(field.data ?? Data()))
                var key = ""
                var value = ""
                while let part = try header.next() {
                    if part.number == 1 { key = String(decoding: part.data ?? Data(), as: UTF8.self) }
                    if part.number == 2 { value = String(decoding: part.data ?? Data(), as: UTF8.self) }
                }
                frame.headers[key] = value
            case 6: frame.encoding = String(decoding: field.data ?? Data(), as: UTF8.self)
            case 7: frame.payloadType = String(decoding: field.data ?? Data(), as: UTF8.self)
            case 8: frame.payload = field.data ?? Data()
            case 9: frame.logIDNew = String(decoding: field.data ?? Data(), as: UTF8.self)
            default: break
            }
        }
        return frame
    }
}

private let invalidFrame = FeishuBotError.message("飞书长连接帧格式无效。")
private struct ProtoReader {
    var bytes: [UInt8]
    var position = 0
    struct Field {
        var number: Int
        var integer: UInt64?
        var data: Data?
    }
    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        for index in 0..<10 {
            guard position < bytes.count else { throw invalidFrame }
            let byte = bytes[position]
            position += 1
            if index == 9 && byte > 1 { throw invalidFrame }
            result |= UInt64(byte & 0x7f) << (index * 7)
            if byte < 128 { return result }
        }
        throw invalidFrame
    }
    mutating func next() throws -> Field? {
        guard position < bytes.count else { return nil }
        let tag = try varint()
        guard tag >> 3 > 0, tag >> 3 <= UInt64(Int.max) else { throw invalidFrame }
        let number = Int(tag >> 3)
        switch tag & 7 {
        case 0: return Field(number: number, integer: try varint())
        case 1, 2, 5:
            let length = tag & 7 == 2 ? try varint() : (tag & 7 == 1 ? 8 : 4)
            guard length <= UInt64(bytes.count - position) else { throw invalidFrame }
            let end = position + Int(length)
            let data = Data(bytes[position..<end])
            position = end
            return Field(number: number, data: data)
        default: throw invalidFrame
        }
    }
}

extension Data {
    fileprivate mutating func appendVarint(_ value: UInt64) {
        var value = value
        while value >= 128 {
            append(UInt8(value & 0x7f) | 0x80)
            value >>= 7
        }
        append(UInt8(value))
    }
    fileprivate mutating func appendField(_ number: Int, _ value: Data) {
        appendVarint(UInt64(number << 3 | 2))
        appendVarint(UInt64(value.count))
        append(value)
    }
}

struct FeishuFrameAssembler {
    private struct Group {
        var count: Int
        var parts: [Int: Data]
        var createdAt: Date
    }
    private var groups: [String: Group] = [:]

    mutating func receive(_ frame: FeishuFrame, now: Date = .now) throws -> Data? {
        groups = groups.filter { now.timeIntervalSince($0.value.createdAt) < 30 }
        let count = Int(frame.headers["sum"] ?? "1") ?? 0
        let index = Int(frame.headers["seq"] ?? "0") ?? -1
        guard (1...128).contains(count), (0..<count).contains(index), frame.payload.count <= 4 * 1024 * 1024
        else { throw invalidFrame }
        if count == 1 { return frame.payload }
        guard let id = frame.headers["message_id"], !id.isEmpty else { throw invalidFrame }
        guard groups[id] != nil || groups.count < 16 else { throw invalidFrame }
        var group = groups[id] ?? Group(count: count, parts: [:], createdAt: now)
        guard group.count == count else { throw invalidFrame }
        group.parts[index] = frame.payload
        guard group.parts.values.reduce(0, { $0 + $1.count }) <= 4 * 1024 * 1024 else {
            groups.removeValue(forKey: id)
            throw invalidFrame
        }
        groups[id] = group
        guard group.parts.count == count else { return nil }
        groups.removeValue(forKey: id)
        return (0..<count).reduce(into: Data()) { $0.append(group.parts[$1]!) }
    }
}
