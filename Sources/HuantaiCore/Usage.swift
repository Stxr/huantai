import Foundation

public enum UsageDate {
    public static func resetText(resetsAt: Date?, timeZone: TimeZone = .current) -> String {
        guard let resetsAt, resetsAt.timeIntervalSince1970.isFinite else { return "重置时间未连接" }
        return format(resetsAt, pattern: "MM-dd(EEE) HH:mm 重置", timeZone: timeZone)
    }

    public static func creditExpiryText(_ credit: ResetCreditExpiry, timeZone: TimeZone = .current) -> String
    {
        guard credit.expirationKnown else { return "有效期未知" }
        guard let date = credit.expiresAt else { return "不过期" }
        guard date.timeIntervalSince1970.isFinite else { return "有效期未知" }
        return format(date, pattern: "yyyy-MM-dd HH:mm", timeZone: timeZone) + "到期"
    }

    private static func format(_ date: Date, pattern: String, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

public enum UsageResetCountdown {
    /// The countdown describes the weekly window reset, independently of reset credits.
    public static func text(resetsAt: Date?, now: Date = Date()) -> String {
        guard let resetsAt else { return "重置时间未连接" }
        let interval = resetsAt.timeIntervalSince(now)
        guard interval.isFinite, interval < Double(Int.max) else { return "重置时间未连接" }
        guard interval > 0 else { return "等待额度刷新" }
        let seconds = Int(ceil(interval))
        let days = seconds / 86400
        let clock = String(
            format: "%02d:%02d:%02d", seconds % 86400 / 3600, seconds % 3600 / 60, seconds % 60)
        return "重置 " + (days > 0 ? "\(days)天 " : "") + clock
    }
}

public struct UsageProjection: Codable, Sendable, Equatable {
    public var referenceBudgetPercent: Double?
    public var estimatedEndPercent: Double?
    public var greenPercent: Double
    public var overBudgetPercent: Double
    public var status: String
    public var todayReferenceBudgetPercent: Double? = nil
    public var todayReferenceRemainingPercent: Double? = nil
    public var todayReferenceEndsAt: Date? = nil
    public var todayReferenceTimeZone: String? = nil

    /// User reference pace, not an official daily allowance.
    public static func calculate(
        window: UsageWindow?, now: Date = Date(), calendar: Calendar = .current
    ) -> UsageProjection {
        guard let window, window.usedPercent.isFinite, window.usedPercent >= 0,
            window.windowDurationMins > 0
        else {
            return .init(
                referenceBudgetPercent: nil, estimatedEndPercent: nil,
                greenPercent: 0, overBudgetPercent: 0, status: "无用量数据")
        }
        let used = min(window.usedPercent, 100)
        let duration = Double(window.windowDurationMins) * 60
        let elapsed = now.timeIntervalSince(window.resetsAt.addingTimeInterval(-duration))
        guard elapsed >= 0, elapsed < duration else {
            return .init(
                referenceBudgetPercent: nil, estimatedEndPercent: nil,
                greenPercent: used, overBudgetPercent: 0, status: "快照周期已过期或尚未开始")
        }
        let budget = min(100, max(0, elapsed / duration * 100))
        var projection = UsageProjection(
            referenceBudgetPercent: budget, estimatedEndPercent: nil,
            greenPercent: min(used, budget), overBudgetPercent: max(0, used - budget),
            status: "用户自定参考节奏")
        if let day = calendar.dateInterval(of: .day, for: now) {
            let cutoff = min(day.end, window.resetsAt)
            let start = window.resetsAt.addingTimeInterval(-duration)
            let todayBudget = min(100, max(0, cutoff.timeIntervalSince(start) / duration * 100))
            // Unspent reference allowance carries forward. This is a cumulative day-end
            // allowance, not an invented measurement of consumption since midnight.
            projection.todayReferenceBudgetPercent = todayBudget
            projection.todayReferenceRemainingPercent = todayBudget - window.usedPercent
            projection.todayReferenceEndsAt = cutoff
            projection.todayReferenceTimeZone = calendar.timeZone.identifier
        }
        return projection
    }
}

/// A minimal decoder ignores account identity, credit IDs, banners and descriptions.
/// JSON-RPC envelopes and the documented direct response are both accepted.
public enum UsageSnapshotImporter {
    public static func decode(_ data: Data, importedAt: Date = Date()) throws -> UsageSummary {
        guard data.count <= 2 * 1024 * 1024 else { throw HuantaiError.invalidUsageSnapshot }
        let response = try JSONDecoder().decode(Response.self, from: data)
        let payload = response.result ?? response
        let metered = payload.rateLimitsByLimitId?["codex"] ?? payload.rateLimits
        let windows = [metered?.primary, metered?.secondary].compactMap { $0 }
        let weekly = windows.first {
            $0.windowDurationMins == 10080 && ($0.resetsAt ?? 0) > 0 && $0.usedPercent.isFinite
                && $0.usedPercent >= 0
        }.flatMap { value -> UsageWindow? in
            guard let duration = value.windowDurationMins, let reset = value.resetsAt else { return nil }
            return UsageWindow(
                usedPercent: value.usedPercent, windowDurationMins: duration,
                resetsAt: Date(timeIntervalSince1970: reset))
        }
        let count = payload.rateLimitResetCredits?.availableCount
        guard weekly != nil || count != nil else { throw HuantaiError.invalidUsageSnapshot }
        return UsageSummary(
            weekly: weekly, resetCount: count, resetCredits: payload.rateLimitResetCredits?.credits,
            observedAt: importedAt,
            status: "离线快照（导入时间，非实时）", source: "offline-import")
    }

    private final class Response: Decodable {
        var result: Response?
        var rateLimits: Limits?
        var rateLimitsByLimitId: [String: Limits]?
        var rateLimitResetCredits: ResetCreditsPayload?
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

struct ResetCreditsPayload: Decodable {
    var availableCount: Int?
    var credits: [ResetCreditExpiry]?
    enum CodingKeys: String, CodingKey { case availableCount, credits }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? container.decode(Int.self, forKey: .availableCount), value >= 0 {
            availableCount = value
        } else if let value = try? container.decode(String.self, forKey: .availableCount),
            let count = Int(value), count >= 0
        {
            availableCount = count
        } else {
            availableCount = nil
        }
        credits = (try? container.decodeIfPresent([ExpiryPayload].self, forKey: .credits))?
            .prefix(128).map(\.value)
    }

    private struct ExpiryPayload: Decodable {
        let value: ResetCreditExpiry
        enum CodingKeys: String, CodingKey { case expiresAt }
        init(from decoder: Decoder) throws {
            guard let container = try? decoder.container(keyedBy: CodingKeys.self),
                container.contains(.expiresAt)
            else {
                value = ResetCreditExpiry(expirationKnown: false)
                return
            }
            if (try? container.decodeNil(forKey: .expiresAt)) == true {
                value = ResetCreditExpiry()
            } else if let stamp = try? container.decode(Double.self, forKey: .expiresAt),
                stamp.isFinite, stamp > 0, stamp <= Date.distantFuture.timeIntervalSince1970
            {
                value = ResetCreditExpiry(expiresAt: Date(timeIntervalSince1970: stamp))
            } else {
                value = ResetCreditExpiry(expirationKnown: false)
            }
        }
    }
}
