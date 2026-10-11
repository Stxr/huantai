import AppKit
import Combine
import HuantaiCore
import SwiftUI

enum SessionToastKind { case navigation, completed, warning }

struct SessionToast: Identifiable {
    let id = UUID()
    var session: SessionRecord
    var position: Int?
    var total: Int = 0
    var message: String
    var completionShortcut: String?
    var completionDeadline: TimeInterval?
    var kind: SessionToastKind = .navigation

    var showsCompletionHint: Bool {
        kind == .navigation && completionShortcut != nil && completionDeadline != nil
    }

    var statusSymbol: String {
        switch kind {
        case .navigation: return "arrow.up.right"
        case .completed: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.circle"
        }
    }

    var statusColor: Color {
        switch kind {
        case .navigation: return .accentColor
        case .completed: return .green
        case .warning: return .orange
        }
    }
}

struct SessionToastView: View {
    let toast: SessionToast

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.accentColor)
                Text("换台").font(.system(size: 12, weight: .semibold))
                Spacer()
                if let position = toast.position {
                    Text("第 \(position) / \(toast.total) 项")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Text(toast.session.title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 5) {
                Text("\(toast.session.source) · \(toast.session.machine)")
                Spacer(minLength: 0)
                if let date = toast.session.lastAIReplyAt {
                    Text("AI 回复")
                    Text(date, style: .relative)
                        .help(date.formatted(date: .abbreviated, time: .standard))
                } else {
                    Text("暂无 AI 回复")
                }
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
            SessionTokenUsageView(usage: toast.session.tokenUsage)
            if toast.showsCompletionHint {
                Text(toast.message).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                Divider().opacity(0.6)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let seconds =
                        toast.completionDeadline.map {
                            max(0, Int(ceil($0 - ProcessInfo.processInfo.systemUptime)))
                        } ?? 0
                    HStack(spacing: 6) {
                        Image(systemName: toast.statusSymbol).foregroundStyle(toast.statusColor)
                        if seconds > 0, let key = toast.completionShortcut {
                            Text("\(key) 完成并切换下一项")
                            Spacer(minLength: 0)
                            Text("\(seconds)s").monospacedDigit().foregroundStyle(.secondary)
                        } else {
                            Text("完成快捷键已过期")
                        }
                    }
                    .font(.system(size: 11))
                }
            } else {
                Label(toast.message, systemImage: toast.statusSymbol)
                    .font(.system(size: 11)).foregroundStyle(toast.statusColor)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.primary.opacity(0.1), lineWidth: 0.7)
        }
        .accessibilityElement(children: .combine)
    }
}

enum SessionToastLayout {
    static let preferredHeight: CGFloat = 206
    static func frame(in visibleFrame: NSRect) -> NSRect {
        let margin: CGFloat = 20
        let width = min(360, max(0, visibleFrame.width - margin * 2))
        let height = min(preferredHeight, max(0, visibleFrame.height - margin * 2))
        return NSRect(
            x: visibleFrame.maxX - width - margin, y: visibleFrame.minY + margin,
            width: width, height: height)
    }
}

private final class SessionToastPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// This is an app-owned, click-through panel. Showing it never activates the app or changes focus.
final class SessionToastController {
    let panel: NSPanel
    private var binding: AnyCancellable?
    private var dismissal: DispatchWorkItem?
    private var displayedID: UUID?

    init(model: AppModel, observeChanges: Bool = true) {
        panel = SessionToastPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        guard observeChanges else { return }
        binding = model.$toast.combineLatest(model.$appearance).sink { [weak self] toast, appearance in
            self?.update(toast, appearance: appearance)
        }
    }

    deinit {
        dismissal?.cancel()
        panel.orderOut(nil)
    }

    private func update(_ toast: SessionToast?, appearance: String) {
        guard let toast else {
            panel.orderOut(nil)
            dismissal?.cancel()
            panel.contentViewController = nil
            displayedID = nil
            return
        }
        guard displayedID != toast.id || panel.isVisible else { return }
        panel.appearance = PopoverAppearance.nativeAppearance(appearance)
        let scheme: ColorScheme? = appearance == "dark" ? .dark : appearance == "light" ? .light : nil
        let controller = NSHostingController(
            rootView: SessionToastView(toast: toast).preferredColorScheme(scheme))
        controller.sizingOptions = []
        panel.contentViewController = controller
        if displayedID != toast.id {
            // Mouse location chooses the current display without inspecting other apps or windows.
            guard
                let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                    ?? NSScreen.main
            else { return }
            panel.setFrame(SessionToastLayout.frame(in: screen.visibleFrame), display: true)
            displayedID = toast.id
            dismissal?.cancel()
            let delay =
                toast.completionDeadline.map { max(0, $0 - ProcessInfo.processInfo.systemUptime) } ?? 4
            let item = DispatchWorkItem { [weak self] in
                guard self?.displayedID == toast.id else { return }
                self?.panel.orderOut(nil)
                self?.panel.contentViewController = nil
            }
            dismissal = item
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
        panel.orderFrontRegardless()
    }
}
