import HuantaiCore
import SwiftUI

struct ResetCreditsBadge: View {
    let usage: UsageSummary
    private static let availableColor = Color(red: 22 / 255, green: 115 / 255, blue: 71 / 255)

    static func isExpiringSoon(_ usage: UsageSummary, now: Date) -> Bool {
        guard let count = usage.resetCount, count > 0 else { return false }
        let deadline = now.addingTimeInterval(3 * 24 * 60 * 60)
        return (usage.resetCredits ?? []).prefix(count).contains { credit in
            guard credit.expirationKnown, let expiry = credit.expiresAt else { return false }
            return expiry > now && expiry <= deadline
        }
    }

    var body: some View {
        if let count = usage.resetCount, count > 0 {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let expiringSoon = Self.isExpiringSoon(usage, now: context.date)
                Text("\(count)")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .frame(minWidth: 13, minHeight: 13)
                    .background(expiringSoon ? Color.red : Self.availableColor, in: Capsule())
                    .fixedSize()
                    .help(expiringSoon ? "有重置卡将在 3 天内到期" : "可用重置卡 \(count) 张")
            }
        }
    }
}

struct ResetCreditsView: View {
    let usage: UsageSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(
                usage.resetCount.map { "重置卡 \($0) 张" } ?? "重置卡未连接", systemImage: "ticket"
            )
            .font(.system(size: 10, weight: .medium))
            if let count = usage.resetCount, count > 0 {
                if let credits = usage.resetCredits {
                    let visible = Array(credits.prefix(count))
                    if !visible.isEmpty {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(Array(visible.enumerated()), id: \.offset) { index, credit in
                                    Text("第\(index + 1)张 · \(UsageDate.creditExpiryText(credit))")
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .frame(height: CGFloat(min(visible.count, 3)) * 17)
                    }
                    if visible.count < count {
                        Text("另有 \(count - visible.count) 张，明细暂未返回")
                    }
                } else {
                    Text("有效期暂未返回")
                }
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }
}
