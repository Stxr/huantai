import Foundation
import HuantaiCore

/// A rolling interval measured from the last visible AI reply, matching list ordering.
enum SessionRecency: String, CaseIterable {
    case day, threeDays, week, all

    var days: Int? {
        switch self {
        case .day: return 1
        case .threeDays: return 3
        case .week: return 7
        case .all: return nil
        }
    }

    var label: String { days.map { "\($0) 日" } ?? "所有" }
    var title: String { days.map { "只看近 \($0) 日" } ?? "所有消息" }

    func includes(_ session: SessionRecord, now: Date = .now) -> Bool {
        guard let days else { return true }
        guard let reply = session.lastAIReplyAt else { return false }
        return reply >= now.addingTimeInterval(-Double(days) * 24 * 60 * 60)
    }
}
