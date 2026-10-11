import AppKit
import HuantaiCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    // Native previews use the same content without AppKit's non-renderable scroll view.
    var scrollContent = true

    var body: some View {
        VStack(spacing: 0) {
            header
            if scrollContent {
                ScrollView { content }
                    .frame(minHeight: 0, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    content.frame(width: geometry.size.width, alignment: .top)
                }.clipped()
            }
            footer
        }
        .onDisappear { model.endRecording() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 28) {
            startup
            general
            taskHooks
            shortcuts
            connections
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 20)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                model.showSessions()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 32)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .help("返回会话（Esc）")
            .accessibilityLabel("返回会话列表")
            VStack(alignment: .leading, spacing: 3) {
                Text("设置").font(.system(size: 19, weight: .semibold))
                Text("把换台调整成你的习惯").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 18)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeading("外观", subtitle: "主题与菜单栏图标，即刻生效。")
            card {
                HStack(spacing: 10) {
                    themeOption("system", title: "跟随系统", symbol: "desktopcomputer")
                    themeOption("light", title: "浅色", symbol: "sun.max")
                    themeOption("dark", title: "深色", symbol: "moon")
                }
            }
            card(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("菜单栏图标").font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 4)
                    ForEach(MenuBarIconMode.allCases) { mode in
                        menuBarIconOption(mode)
                        if mode != MenuBarIconMode.allCases.last {
                            Divider().padding(.horizontal, 14)
                        }
                    }
                }
            }
        }
    }

    private var startup: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeading("通用", subtitle: "让换台随登录自动运行。")
            card(padding: 0) { LoginItemSettingView(manager: model.loginItem) }
        }
    }

    private var taskHooks: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeading("任务音效", subtitle: "任务开始、完成或失败时，播放你选的声音。")
            TaskHookSettingView(manager: model.taskHook, sources: model.taskHookSources)
        }
    }

    private func menuBarIconOption(_ mode: MenuBarIconMode) -> some View {
        let selected = model.menuBarIconMode == mode
        return Button {
            model.setMenuBarIconMode(mode)
        } label: {
            SettingsOptionRow(
                symbol: mode == .logo ? "rectangle.on.rectangle" : "circle.dashed.inset.filled",
                title: mode.title, subtitle: mode.subtitle, selected: selected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("菜单栏图标：\(mode.title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func themeOption(_ value: String, title: String, symbol: String) -> some View {
        let selected = model.appearance == value
        let previewDark = value == "dark" || (value == "system" && colorScheme == .dark)
        return Button {
            model.setAppearance(value)
        } label: {
            VStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 3) {
                        Circle().fill(Color.accentColor).frame(width: 5, height: 5)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(previewDark ? .white.opacity(0.45) : .black.opacity(0.25))
                            .frame(width: 19, height: 3)
                        Spacer(minLength: 0)
                    }
                    Capsule().fill(Color.green.opacity(0.9)).frame(height: 3)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(previewDark ? .white.opacity(0.18) : .black.opacity(0.1)).frame(height: 9)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(previewDark ? .white.opacity(0.18) : .black.opacity(0.1)).frame(height: 9)
                }
                .padding(9)
                .background(previewDark ? Color(white: 0.16) : .white, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.secondary.opacity(0.15)))
                HStack(spacing: 4) {
                    Image(systemName: symbol)
                    Text(title)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(selected ? Color.accentColor : .secondary)
            }
            .padding(9)
            .frame(maxWidth: .infinity)
            .background(
                selected ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 11)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)主题")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeading("全局快捷键", subtitle: "点击键位录入新组合，在其他应用中也能使用。")
            card(padding: 0) { shortcutRow(.showPopover) }
            Text("按一次打开，再按一次关闭；保留当前页面。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            card(padding: 0) { shortcutRow(.completeCurrent) }
            Text("通过换台成功打开会话后 15 秒内，标记当前任务完成并打开下一条。已完成任务会从默认列表隐藏，可在列表状态筛选中查看并恢复。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            card(padding: 0) { shortcutRow(.undoCompletion) }
            Text("撤回本次运行中最近一次完成，并返回该会话；连续按可依次撤回，不受 15 秒限制。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let warning = model.shortcutMigrationWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(ShortcutAction.navigationActions, id: \.self) { action in
                        shortcutRow(action)
                        if action != ShortcutAction.navigationActions.last {
                            Divider().padding(.horizontal, 14)
                        }
                    }
                }
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: model.recordingAction == nil ? "info.circle" : "keyboard")
                Text(
                    model.recordingAction == nil
                        ? model.shortcutStatus : "按下新的组合键，Esc 取消。\n\(model.shortcutStatus)"
                )
                .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 11))
            .foregroundStyle(model.recordingAction == nil ? Color.secondary : .accentColor)
            HStack {
                Button("恢复默认") { model.restoreDefaultShortcuts() }.buttonStyle(.bordered)
                Spacer()
                if model.recordingAction != nil {
                    Button("取消录入") { model.endRecording() }.buttonStyle(.bordered)
                }
            }
            .controlSize(.small)
            card {
                VStack(alignment: .leading, spacing: 8) {
                    Label("像 IDE 一样前后跳转", systemImage: "arrow.uturn.backward")
                        .font(.system(size: 12, weight: .medium))
                    Text("上下切换与回到第一项沿用当前排序和筛选。后退、前进记住通过换台打开的会话；从第七项跳到第一项后，后退即可返回第七项。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func shortcutRow(_ action: ShortcutAction) -> some View {
        let recording = model.recordingAction == action
        return HStack(spacing: 12) {
            Text(action.title).font(.system(size: 12, weight: .medium))
            Spacer(minLength: 12)
            HStack(spacing: 12) {
                Button {
                    model.beginRecording(action)
                } label: {
                    keycap(model.shortcuts[action], active: recording)
                }
                .buttonStyle(.plain)
                .help("点击录入快捷键；按 Esc 取消")
                .accessibilityLabel("设置\(action.title)快捷键")
                Button {
                    model.updateShortcut(action, binding: nil)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary).frame(width: 28, height: 28)
                        .background(Color.secondary.opacity(0.08), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).disabled(model.shortcuts[action] == nil)
                .help("取消此快捷键").accessibilityLabel("取消\(action.title)快捷键")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var connections: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeading("连接与数据", subtitle: "查看来源状态，管理数据更新。")
            card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(SessionSource.allCases, id: \.self) { source in
                        sessionSourceRow(source)
                        if source != SessionSource.allCases.last { Divider().padding(.horizontal, 14) }
                    }
                }
            }
            card { RemoteConnectionsView(model: model) }
            Text("默认同时读取 Codex 和官方 DeepSeek Harness。选择各自数据主目录；DeepSeek Harness 默认 ~/.dsh。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            card(padding: 0) {
                VStack(spacing: 0) {
                    if model.snapshot.sources.isEmpty {
                        Label("正在读取来源状态…", systemImage: "externaldrive")
                            .font(.system(size: 12)).foregroundStyle(.secondary).padding(16)
                    } else {
                        ForEach(model.snapshot.sources, id: \.id) { source in
                            HStack(alignment: .top, spacing: 12) {
                                icon(
                                    source.id == "botmux" ? "bubble.left.and.bubble.right" : "terminal",
                                    color: .accentColor)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(source.name).font(.system(size: 12, weight: .medium))
                                    Text(source.status).font(.system(size: 11)).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(14)
                            if source.id != model.snapshot.sources.last?.id {
                                Divider().padding(.horizontal, 14)
                            }
                        }
                    }
                }
            }
            card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("会话同步", systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text("每 5 秒").font(.system(size: 11, weight: .medium)).foregroundStyle(
                            Color.accentColor)
                    }
                    HStack {
                        Text("最新更新").foregroundStyle(.secondary)
                        Spacer()
                        Text(model.snapshot.updatedAt.formatted(.dateTime.hour().minute().second()))
                            .monospacedDigit()
                    }.font(.system(size: 11))
                    if let scan = model.snapshot.scan {
                        HStack {
                            Text("最近扫描耗时").foregroundStyle(.secondary)
                            Spacer()
                            Text(String(format: "%.1f ms", scan.durationMilliseconds)).monospacedDigit()
                        }.font(.system(size: 11))
                    }
                    Button {
                        model.refresh()
                    } label: {
                        Label(model.refreshing ? "正在刷新…" : "刷新会话", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).disabled(model.refreshing)
                }
            }
            card {
                VStack(alignment: .leading, spacing: 10) {
                    Label("账户额度", systemImage: "chart.bar").font(.system(size: 12, weight: .medium))
                    Text(model.snapshot.usage.status).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("每 5 分钟自动更新").font(.system(size: 11)).foregroundStyle(.tertiary)
                    Button {
                        model.refreshUsage()
                    } label: {
                        Label("刷新账户额度", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered)
                }
            }
            Button {
                model.openWeb()
            } label: {
                Label("打开 Web 详情", systemImage: "globe").frame(maxWidth: .infinity)
            }.buttonStyle(.bordered).disabled(!model.webReady)
            if CommandLine.arguments.contains("--review") {
                Button("保存界面截图") { model.saveReviewScreenshot() }
            }
            if let notice = model.notice {
                Label(notice, systemImage: "info.circle")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .controlSize(.small)
    }

    private func sessionSourceRow(_ source: SessionSource) -> some View {
        let path = model.sessionDirectory(source)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let displayPath = path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                model.setSessionSource(source, enabled: !model.sourceEnabled(source))
            } label: {
                SettingsOptionRow(
                    symbol: source == .codex ? "terminal" : "sparkles", title: source.title,
                    subtitle: model.sourceEnabled(source) ? "已启用 · 只读会话索引" : "已关闭",
                    selected: model.sourceEnabled(source))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(source.title) 会话来源")
            .accessibilityAddTraits(model.sourceEnabled(source) ? .isSelected : [])
            VStack(alignment: .leading, spacing: 8) {
                Text(displayPath).font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(path)
                HStack {
                    Button("选择目录…") { model.chooseSessionDirectory(source) }
                        .accessibilityLabel("选择 \(source.title) 数据目录")
                    Button("恢复默认目录") { model.setSessionDirectory(source, path: nil) }
                        .accessibilityLabel("恢复 \(source.title) 默认目录")
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
            .padding(.horizontal, 14).padding(.bottom, 14)
        }
        .disabled(model.savingSourceConfiguration)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider().padding(.horizontal, 20)
            HStack {
                Image(systemName: "rectangle.on.rectangle").foregroundStyle(Color.accentColor)
                Text("换台").foregroundStyle(.secondary)
                Spacer()
                Button("退出换台") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .font(.system(size: 11)).padding(.horizontal, 20).padding(.vertical, 14)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func sectionHeading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func card<Content: View>(padding: CGFloat = 14, @ViewBuilder content: () -> Content) -> some View
    {
        content().padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(
                colorScheme == .dark ? Color.white.opacity(0.045) : Color.white.opacity(0.6),
                in: RoundedRectangle(cornerRadius: 15)
            )
            .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(.secondary.opacity(0.12)))
    }

    private func icon(_ symbol: String, color: Color) -> some View {
        Image(systemName: symbol).font(.system(size: 15))
            .foregroundStyle(color).frame(width: 34, height: 34)
            .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    private func keycap(_ binding: ShortcutBinding?, active: Bool = false) -> some View {
        let text: String
        if active {
            text = "按下组合键…"
        } else if let binding {
            let modifiers: [(NSEvent.ModifierFlags, String)] = [
                (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"),
            ]
            let symbols = modifiers.filter { binding.flags.contains($0.0) }.map { $0.1 }
            text = (symbols + [binding.keyLabel]).joined(separator: "\u{2009}")
        } else {
            text = "未设置"
        }
        return Text(text).font(.system(size: 13, weight: .medium, design: .monospaced))
            .foregroundStyle(active ? Color.accentColor : .primary)
            .lineLimit(1).minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12).frame(width: 132, height: 36)
            .background(
                active ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(active ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.18)))
    }
}

private struct LoginItemSettingView: View {
    @ObservedObject var manager: LoginItemManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                manager.setEnabled(!manager.isRegistered)
            } label: {
                SettingsOptionRow(
                    symbol: "power", title: "开机运行", subtitle: manager.statusDescription,
                    selected: manager.isRegistered,
                    subtitleColor: manager.status == .requiresApproval ? .orange : .secondary)
            }
            .buttonStyle(.plain)
            .help(manager.isRegistered ? "点击关闭开机运行" : "点击开启开机运行")
            .accessibilityLabel("开机运行")
            .accessibilityValue(manager.statusDescription)
            .accessibilityAddTraits(manager.isRegistered ? .isSelected : [])
            if manager.status == .requiresApproval || manager.errorMessage != nil {
                VStack(alignment: .leading, spacing: 8) {
                    if manager.status == .requiresApproval {
                        Button("打开登录项设置") { manager.showSystemSettings() }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                    if let error = manager.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11)).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 14)
            }
        }
        .onAppear { manager.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) {
            _ in manager.refresh()
        }
    }
}

struct SettingsOptionRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    let selected: Bool
    var subtitleColor = Color.secondary

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 16)).frame(width: 22)
                .foregroundStyle(selected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.primary)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(subtitleColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? Color.accentColor : .secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
}
