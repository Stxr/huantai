import AppKit
import HuantaiCore
import SwiftUI

struct PopoverView: View {
    @ObservedObject var model: AppModel
    var contentSize = PopoverLayout.preferredSize
    @State private var searching = false
    @State private var showingResetCredits = false
    @FocusState private var searchFocused: Bool

    private var sessions: [SessionRecord] {
        model.visibleSessions
    }
    var body: some View {
        Group {
            if model.page == .settings {
                SettingsView(model: model)
            } else {
                sessionPage
            }
        }
        .frame(width: contentSize.width, height: contentSize.height, alignment: .top)
        .onAppear { model.refresh() }
    }

    private var sessionPage: some View {
        VStack(spacing: 0) {
            header.fixedSize(horizontal: false, vertical: true)
            if searching {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索标题或目录", text: $model.sessionQuery)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .accessibilityIdentifier("session-search")
                    if !model.sessionQuery.isEmpty {
                        Button {
                            model.sessionQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清空搜索")
                    }
                }
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
            if showingResetCredits {
                ResetCreditsView(usage: model.snapshot.usage)
                    .padding(10)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                    .accessibilityIdentifier("reset-credits-details")
            }
            WeeklyUsageView(usage: model.snapshot.usage)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                .fixedSize(horizontal: false, vertical: true)
            Divider().padding(.horizontal, 20)
            if sessions.isEmpty {
                emptyState.frame(minHeight: 0, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(sessions) { session in
                            SessionRow(session: session, model: model)
                            Divider().padding(.leading, 20).padding(.trailing, 20)
                        }
                    }
                }
                .frame(minHeight: 0, maxHeight: .infinity)
            }
            if let notice = model.notice {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                    Text(notice).font(.caption).lineLimit(3).help(notice)
                    Spacer(minLength: 0)
                    Button {
                        model.notice = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭提示")
                }
                .foregroundStyle(.secondary)
                .padding(12)
                .background(.quaternary)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .fixedSize(horizontal: false, vertical: true)
            }
            footer.fixedSize(horizontal: false, vertical: true)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text("换台").font(.system(size: 18, weight: .semibold))
            Spacer()
            Button {
                model.setShowsCompleted(!model.showsCompleted)
            } label: {
                Image(systemName: model.showsCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(model.showsCompleted ? Color.green : .secondary)
            }
            .buttonStyle(.plain)
            .help("任务状态：\(model.showsCompleted ? "已完成" : "未完成")")
            .accessibilityLabel("筛选未完成或已完成任务")
            Button {
                model.setFavoritesOnly(!model.favoritesOnly)
            } label: {
                Image(systemName: model.favoritesOnly ? "star.fill" : "star")
                    .foregroundStyle(model.favoritesOnly ? Color.orange : .secondary)
            }
            .help(model.favoritesOnly ? "收藏筛选已开启，点击查看全部" : "只看收藏")
            .accessibilityLabel("收藏筛选")
            .accessibilityValue(model.favoritesOnly ? "开启" : "关闭")
            Button {
                showingResetCredits.toggle()
            } label: {
                Image(systemName: "ticket")
                    .foregroundStyle(showingResetCredits ? Color.accentColor : .secondary)
                    .overlay(alignment: .topTrailing) {
                        if let count = model.snapshot.usage.resetCount, count > 0 {
                            Text("\(count)")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 3)
                                .frame(minWidth: 13, minHeight: 13)
                                .background(Color.red, in: Capsule())
                                .fixedSize()
                                .offset(x: 7, y: -7)
                        }
                    }
            }
            .help(showingResetCredits ? "收起重置卡详情" : "展开重置卡详情")
            .accessibilityLabel("重置卡")
            .accessibilityValue(model.snapshot.usage.resetCount.map { "\($0) 张" } ?? "未连接")
            .accessibilityIdentifier("reset-credits-toggle")
            Button {
                searching.toggle()
                if !searching { model.sessionQuery = "" }
                searchFocused = searching
            } label: {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(searching ? Color.accentColor : .secondary)
            }
            .help("展开搜索")
            .accessibilityLabel("展开搜索")
            Button {
                model.showSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .frame(width: 19)
            .help("设置（⌘,）")
            .accessibilityLabel("打开设置")
            .keyboardShortcut(",", modifiers: .command)
        }
        .font(.system(size: 14))
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 20)
    }

    private var emptyState: some View {
        VStack(spacing: 11) {
            Image(systemName: model.sessionQuery.isEmpty ? "rectangle.stack" : "magnifyingglass")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text(
                !model.sessionQuery.isEmpty
                    ? "没有匹配的会话"
                    : model.showsCompleted ? "没有已完成的会话" : model.favoritesOnly ? "没有未完成的收藏" : "没有未完成的会话"
            )
            .font(.system(size: 14, weight: .medium))
            if model.favoritesOnly && model.sessionQuery.isEmpty {
                Text("点会话右侧星标收藏，随时从这里换台。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("查看全部会话") { model.setFavoritesOnly(false) }
                    .buttonStyle(.link)
            } else if model.sessionQuery.isEmpty {
                Text(model.snapshot.sources.first?.status ?? "正在读取本地索引…")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 5) {
                if model.refreshing {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle().fill(model.snapshot.sessions.isEmpty ? Color.secondary : Color.green).frame(
                        width: 5, height: 5)
                }
                Text(
                    model.isTestEnvironment
                        ? "测试数据 · \(sessions.count) 个会话" : model.refreshing ? "正在刷新" : "\(sessions.count) 个会话"
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !model.snapshot.sources.isEmpty {
                Text("最新更新 \(model.snapshot.updatedAt.formatted(.dateTime.hour().minute().second()))")
                    .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                    .help("最近完成会话扫描的时间；每5秒刷新，按AI最后一条可见回复排序")
                    .accessibilityLabel("最近扫描更新时间")
            }
            Button {
                model.openWeb()
            } label: {
                Image(systemName: "globe")
            }
            .buttonStyle(.plain)
            .font(.system(size: 15))
            .foregroundStyle(model.webReady ? Color.accentColor : .secondary)
            .help("打开本地 Web 详情")
            .accessibilityLabel("打开 Web 详情")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
    }
}

struct SessionRow: View {
    let session: SessionRecord
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 9) {
                Button {
                    model.openSession(session)
                } label: {
                    Text(session.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .help(session.openURL == nil ? "尚未配置来源链接；右键可设置" : "打开来源会话")
                .contextMenu {
                    Button("设置来源链接…") { model.configureLink(session) }
                    Button(session.isCompleted ? "恢复为未完成" : "标为已完成") {
                        model.setCompleted(session, value: !session.isCompleted)
                    }
                    Button("复制会话 ID") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(session.id, forType: .string)
                    }
                }
                Text(session.lastAIReplyPreview ?? "暂无可显示的回复")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("session-last-reply")
                HStack(spacing: 6) {
                    chip(session.source)
                    chip(session.machine)
                    Spacer(minLength: 0)
                    if let date = session.lastAIReplyAt {
                        Text(date, style: .relative).font(.system(size: 10)).foregroundStyle(.secondary)
                            .help("AI最后回复：\(date.formatted(date: .abbreviated, time: .standard))")
                    } else {
                        Text("暂无 AI 回复").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 6) {
                Button {
                    model.toggleFavorite(session)
                } label: {
                    Image(systemName: session.isFavorite ? "star.fill" : "star")
                        .font(.system(size: 13))
                        .foregroundStyle(session.isFavorite ? Color.orange : .secondary.opacity(0.55))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help(session.isFavorite ? "取消收藏" : "收藏")
                .accessibilityLabel(session.isFavorite ? "取消收藏" : "收藏")
                Button {
                    model.setCompleted(session, value: !session.isCompleted)
                } label: {
                    Image(systemName: session.isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 13))
                        .foregroundStyle(session.isCompleted ? Color.green : .secondary.opacity(0.55))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help(session.isCompleted ? "恢复为未完成" : "标为已完成")
                .accessibilityLabel(session.isCompleted ? "恢复为未完成" : "标记完成")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
    }
    private func chip(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
    }
}

private struct WeeklyUsageView: View {
    let usage: UsageSummary
    var body: some View {
        let projection = UsageProjection.calculate(window: usage.weekly)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("周额度").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                if let window = usage.weekly {
                    Text("剩余 \(percent(remaining(window.usedPercent)))")
                        .font(.system(size: 12, weight: .semibold))
                } else {
                    Text("未连接").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    if let window = usage.weekly {
                        Capsule().fill(
                            (projection.todayReferenceRemainingPercent ?? 0) < 0 ? Color.red : Color.green
                        )
                        .frame(width: width * bounded(remaining(window.usedPercent)))
                        if let budget = projection.referenceBudgetPercent {
                            Path { path in
                                let position = width * bounded(remaining(budget))
                                path.move(to: CGPoint(x: position, y: -3))
                                path.addLine(to: CGPoint(x: position, y: 13))
                            }
                            .stroke(.primary.opacity(0.65), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                        }
                    }
                }
            }
            .frame(height: 10)
            HStack(alignment: .top) {
                if let today = projection.todayReferenceRemainingPercent {
                    Text(today < 0 ? "今日超出 \(dailyPercent(-today))" : "今日参考剩余 \(dailyPercent(today))")
                        .monospacedDigit()
                        .foregroundStyle(today < 0 ? Color.red : Color.green)
                        .help("每日按均匀节奏分配，前几天未用的参考额度累计到今天；百分比以全周总额度为100%，按本机时区今日结束计算。")
                } else {
                    Text(usage.weekly == nil ? "用量来源待配置" : "今日参考待更新")
                }
                Spacer(minLength: 8)
                Text(UsageDate.resetText(resetsAt: usage.weekly?.resetsAt))
                    .monospacedDigit()
                    .accessibilityLabel("周额度重置时间")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
        .help(
            usage.status
                + "；进度条表示周剩余额度，超出截至今日的累计参考时变红；虚线为均匀节奏参考剩余。参考节奏不是官方日额度。")
    }
    private func dailyPercent(_ value: Double) -> String {
        value > 0 && value < 0.1 ? "<0.1%" : String(format: "%.1f%%", value)
    }
    private func remaining(_ used: Double) -> Double { min(100, max(0, 100 - used)) }
    private func bounded(_ value: Double) -> Double { min(100, max(0, value)) / 100 }
    private func percent(_ value: Double) -> String { String(format: "%.0f%%", value) }
}
