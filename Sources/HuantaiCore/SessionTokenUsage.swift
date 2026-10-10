import CoreFoundation
import Foundation

/// Matches Codo's token_count semantics: the latest cumulative sample, never a sum of samples.
public struct SessionTokenUsage: Codable, Sendable, Equatable {
    public var totalTokens: Int?
    public var contextTokens: Int?
    public var contextWindow: Int?
    public var measuredAt: String?
    public var compacted: Bool

    public var percent: Double? {
        guard let contextTokens, let contextWindow, contextWindow > 0 else { return nil }
        return Double(contextTokens) / Double(contextWindow) * 100
    }
    public var compactTotal: String { totalTokens.map(Self.format) ?? "—" }
    public var compactContext: String {
        compacted
            ? "↻" : (contextTokens.map(Self.format) ?? "—") + " / " + (contextWindow.map(Self.format) ?? "—")
    }
    public var summary: String {
        "累计 \(totalTokens.map(String.init) ?? "未知") token（含缓存输入）；"
            + (compacted ? "上下文压缩后待更新" : "上下文约 \(compactContext)")
            + "。上下文为最近一次请求的输入，包含系统提示、历史、工具结果和缓存；采样：\(measuredAt ?? "未知")。"
    }
    private static func format(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.2fM", Double(value) / 1_000_000) }
        if value >= 1000 { return String(format: "%.1fK", Double(value) / 1000) }
        return String(value)
    }

    static func normalize(info: [String: Any], measuredAt: String?, compacted: Bool) -> Self? {
        let total = number((info["total_token_usage"] as? [String: Any])?["total_tokens"])
        let context = compacted ? nil : number((info["last_token_usage"] as? [String: Any])?["input_tokens"])
        guard total != nil || context != nil else { return nil }
        let window = number(info["model_context_window"])
        return Self(
            totalTokens: total, contextTokens: context,
            contextWindow: window == 0 ? nil : window, measuredAt: measuredAt, compacted: compacted)
    }

    private static func number(_ value: Any?) -> Int? {
        guard let value = value as? NSNumber,
            CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue >= 0,
            value.doubleValue <= 9_007_199_254_740_991,
            value.doubleValue.rounded(.towardZero) == value.doubleValue
        else { return nil }
        return value.intValue
    }
}

/// Bounded reverse scan cached by file identity, size and modification time, like Codo's item usage.
final class SessionTokenUsageScanner {
    private struct Entry {
        var size: UInt64
        var modified: Date?
        var inode: UInt64?
        var usage: SessionTokenUsage?
    }
    private var cache: [String: Entry] = [:]
    func scan(_ url: URL) -> SessionTokenUsage? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            let modified = attributes[.modificationDate] as? Date
            let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
            if let old = cache[url.path], old.size == size, old.modified == modified, old.inode == inode {
                return old.usage
            }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let start = size > 8 * 1024 * 1024 ? size - 8 * 1024 * 1024 : 0
            try file.seek(toOffset: start)
            let data = try file.read(upToCount: Int(size - start)) ?? Data()
            let usage = Self.decodeTail(data, startsMidFile: start > 0)
            if cache.count >= 2048 { cache.removeAll(keepingCapacity: true) }
            cache[url.path] = Entry(size: size, modified: modified, inode: inode, usage: usage)
            return usage
        } catch { return nil }
    }

    static func decodeTail(_ data: Data, startsMidFile: Bool = false) -> SessionTokenUsage? {
        let lines = data.split(separator: 10, omittingEmptySubsequences: false)
        var compacted = false
        for line in (startsMidFile ? Array(lines.dropFirst()) : lines).reversed() {
            guard let event = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else {
                continue
            }
            let payload = event["payload"] as? [String: Any] ?? [:]
            if event["type"] as? String == "compacted"
                || (event["type"] as? String == "event_msg"
                    && payload["type"] as? String == "context_compacted")
            {
                compacted = true
            }
            if event["type"] as? String == "event_msg", payload["type"] as? String == "token_count",
                let info = payload["info"] as? [String: Any],
                let usage = SessionTokenUsage.normalize(
                    info: info, measuredAt: event["timestamp"] as? String, compacted: compacted)
            {
                return usage
            }
        }
        return nil
    }
}
