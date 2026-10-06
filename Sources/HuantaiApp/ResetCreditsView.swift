import HuantaiCore
import SwiftUI

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
