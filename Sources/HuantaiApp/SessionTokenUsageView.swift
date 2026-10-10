import HuantaiCore
import SwiftUI

struct SessionTokenUsageView: View {
    let usage: SessionTokenUsage?
    var body: some View {
        HStack(spacing: 12) {
            Label(usage?.compactTotal ?? "—", systemImage: "number")
                .help("累计 Token（含缓存输入）")
            HStack(spacing: 4) {
                Image(systemName: "chart.pie")
                Text(usage?.compactContext ?? "—")
                if let percent = usage?.percent { Text(String(format: "%.0f%%", percent)) }
            }
            .foregroundStyle(
                (usage?.percent ?? 0) >= 85
                    ? Color.red : (usage?.percent ?? 0) >= 65 ? Color.orange : Color.secondary)
        }
        .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
        .help(usage?.summary ?? "暂无 Token 用量数据")
        .accessibilityLabel(usage?.summary ?? "暂无 Token 用量数据")
    }
}
