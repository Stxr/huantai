import HuantaiCore
import SwiftUI

/// Keep stale remote data visible, but make its effect on session ordering explicit.
struct SourceSyncWarningView: View {
    let sources: [SourceStatus]
    let openSettings: () -> Void

    static func affectedSources(in sources: [SourceStatus]) -> [SourceStatus] {
        sources.filter {
            $0.id.hasPrefix("remote-")
                && ($0.status.hasPrefix("未连接") || $0.status.contains("显示上次缓存"))
        }
    }

    var body: some View {
        let affected = Self.affectedSources(in: sources)
        if !affected.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("远端会话未同步，最新会话可能缺失", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
                ForEach(affected, id: \.id) { source in
                    Text("\(source.name)：\(source.status)")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .top) {
                    Text("缓存中的会话和排序可能已过时；连接恢复后自动更新。")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("检查连接", action: openSettings)
                        .buttonStyle(.link).font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.orange.opacity(0.45)))
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("source-sync-warning")
        }
    }
}
