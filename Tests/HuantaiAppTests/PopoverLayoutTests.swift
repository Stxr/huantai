import AppKit
import HuantaiCore
import SwiftUI
import XCTest

@testable import HuantaiApp

final class PopoverLayoutTests: XCTestCase {
    func testDismissalProtectsPopoverAnchorAndModalAndClosesOutside() {
        let popover = NSRect(x: -400, y: 200, width: 430, height: 560)
        let anchor = NSRect(x: -220, y: 765, width: 24, height: 24)
        func dismiss(_ point: NSPoint, modal: Bool = false) -> Bool {
            PopoverDismissalMonitor.shouldDismiss(
                point: point, popoverFrame: popover, statusButtonFrame: anchor, hasModalWindow: modal)
        }
        XCTAssertFalse(dismiss(NSPoint(x: -300, y: 300)))
        XCTAssertFalse(dismiss(NSPoint(x: -208, y: 777)))
        XCTAssertTrue(dismiss(NSPoint(x: 100, y: 300)))
        XCTAssertTrue(dismiss(NSPoint(x: -300, y: 100)))
        XCTAssertFalse(dismiss(NSPoint(x: 100, y: 300), modal: true))
    }

    @MainActor
    func testThemeChangesUpdateNativePopoverAndHostIncludingRestoringSystemTheme() throws {
        let suite = "huantai.theme.fixture." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set("light", forKey: "appearance")
        let model = AppModel(startServices: false, preferences: preferences)
        let controller = NSHostingController(rootView: PopoverView(model: model))
        let popover = NSPopover()
        popover.contentViewController = controller
        let binding = PopoverAppearance.bind(model: model, popover: popover, controller: controller)
        withExtendedLifetime(binding) {
            XCTAssertEqual(popover.appearance?.name, .aqua)
            XCTAssertEqual(controller.view.appearance?.name, .aqua)
            model.setAppearance("dark")
            XCTAssertEqual(popover.appearance?.name, .darkAqua)
            XCTAssertEqual(controller.view.appearance?.name, .darkAqua)
            model.setAppearance("system")
            XCTAssertNil(popover.appearance)
            XCTAssertNil(controller.view.appearance)
            XCTAssertEqual(preferences.string(forKey: "appearance"), "system")
        }
    }
    func testBottomEdgeRespectsBothCoordinateSystems() {
        XCTAssertEqual(PopoverLayout.bottomEdge(isFlipped: true), .maxY)
        XCTAssertEqual(PopoverLayout.bottomEdge(isFlipped: false), .minY)
    }

    func testContentFitsBelowMenuBarOnSmallAndOffsetDisplays() {
        for frame in [
            NSRect(x: 0, y: 24, width: 1440, height: 852),
            NSRect(x: -800, y: -480, width: 800, height: 480),
            NSRect(x: 1440, y: 0, width: 390, height: 432),
        ] {
            let anchor = NSRect(x: frame.midX, y: frame.maxY, width: 24, height: 24)
            let size = PopoverLayout.contentSize(visibleFrame: frame, anchor: anchor)
            XCTAssertLessThanOrEqual(size.width + 2 * PopoverLayout.screenMargin, frame.width)
            XCTAssertLessThanOrEqual(
                size.height + PopoverLayout.chromeAllowance + PopoverLayout.screenMargin,
                anchor.minY - frame.minY)
            XCTAssertGreaterThan(size.height, 0)
        }
    }

    @MainActor
    func testLoadingSessionsAndNoticeCannotGrowPopoverPastItsViewport() {
        let model = AppModel(startServices: false)
        let controller = NSHostingController(rootView: PopoverView(model: model))
        let proposal = NSSize(width: 430, height: 560)
        let emptySize = controller.sizeThatFits(in: proposal)
        model.snapshot.sessions = (0..<30).map { index in
            SessionRecord(
                id: "fixture-\(index)", title: "合成测试会话 \(index)", cwd: "/fixture",
                source: "Codex", machine: "本机", isFavorite: true)
        }
        controller.view.layoutSubtreeIfNeeded()
        let loadedSize = controller.sizeThatFits(in: proposal)
        model.snapshot.usage = UsageSummary(
            weekly: UsageWindow(
                usedPercent: 80, windowDurationMins: 10080,
                resetsAt: Date().addingTimeInterval(4 * 86400)), source: "synthetic")
        controller.view.layoutSubtreeIfNeeded()
        let dailyUsageSize = controller.sizeThatFits(in: proposal)
        model.notice = String(repeating: "合成提示用于检验长消息不推动弹窗越界。", count: 12)
        controller.view.layoutSubtreeIfNeeded()
        let noticeSize = controller.sizeThatFits(in: proposal)
        XCTAssertEqual(emptySize.height, 560, accuracy: 1)
        XCTAssertEqual(loadedSize.height, emptySize.height, accuracy: 1)
        XCTAssertEqual(dailyUsageSize.height, emptySize.height, accuracy: 1)
        XCTAssertEqual(noticeSize.height, emptySize.height, accuracy: 1)
    }

    @MainActor
    func testSmallViewportStaysWithinScreenWhileNoticeIsShown() {
        let model = AppModel(startServices: false)
        model.notice = String(repeating: "合成提示", count: 40)
        let size = NSSize(width: 366, height: 400)
        let controller = NSHostingController(rootView: PopoverView(model: model, contentSize: size))
        XCTAssertEqual(controller.sizeThatFits(in: size).width, size.width, accuracy: 1)
        XCTAssertEqual(controller.sizeThatFits(in: size).height, size.height, accuracy: 1)
    }

    @MainActor
    func testContinuousSettingsFitsSmallScreensAndScrollsToBottomIncludingLongSourceStatus() throws {
        let suite = "huantai.settings.layout." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = AppModel(startServices: false, preferences: preferences)
        model.snapshot.sources = [
            SourceStatus(
                id: "local", name: "本机 Codex", status: String(repeating: "合成来源暂不可读；显示上次缓存。", count: 16)),
            SourceStatus(id: "botmux", name: "本机 Botmux", status: "合成关联状态"),
        ]
        model.notice = String(repeating: "合成提示", count: 40)
        model.showSettings()
        for size in [PopoverLayout.preferredSize, NSSize(width: 366, height: 400)] {
            let controller = NSHostingController(rootView: PopoverView(model: model, contentSize: size))
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size), styleMask: [], backing: .buffered,
                defer: false)
            window.contentViewController = controller
            controller.view.setFrameSize(size)
            let fitted = controller.sizeThatFits(in: size)
            XCTAssertEqual(fitted.width, size.width, accuracy: 1)
            XCTAssertEqual(fitted.height, size.height, accuracy: 1)
            controller.view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            func scrollViews(in view: NSView) -> [NSScrollView] {
                (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
            }
            let views = scrollViews(in: controller.view)
            XCTAssertEqual(views.count, 1, "所有设置应共用一个滚动区域")
            let scroll = try XCTUnwrap(views.first)
            let document = try XCTUnwrap(scroll.documentView)
            document.layoutSubtreeIfNeeded()
            let viewport = scroll.contentView.bounds.height
            XCTAssertGreaterThan(document.bounds.height, viewport)
            let bottom = document.isFlipped ? document.bounds.maxY - viewport : document.bounds.minY
            scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
            scroll.reflectScrolledClipView(scroll.contentView)
            XCTAssertEqual(scroll.contentView.bounds.minY, bottom, accuracy: 1)
        }
    }

    @MainActor
    func testSettingsUsesPopoverThemeAndCanRenderSyntheticNativePreviews() throws {
        let suite = "huantai.settings.preview." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = AppModel(startServices: false, preferences: preferences)
        model.snapshot.sources = [
            SourceStatus(id: "local", name: "本机 Codex", status: "已连接（只读） · 合成预览"),
            SourceStatus(id: "botmux", name: "本机 Botmux", status: "已关联 · 合成预览"),
        ]
        model.showSettings()
        let controller = NSHostingController(rootView: PopoverView(model: model))
        let popover = NSPopover()
        let binding = PopoverAppearance.bind(model: model, popover: popover, controller: controller)
        withExtendedLifetime(binding) {
            model.setAppearance("dark")
            XCTAssertEqual(popover.appearance?.name, .darkAqua)
            model.setAppearance("light")
            XCTAssertEqual(popover.appearance?.name, .aqua)
        }
        guard let path = ProcessInfo.processInfo.environment["HUANTAI_RENDER_SETTINGS_DIR"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for theme in ["dark", "light"] {
            model.setAppearance(theme)
            // ImageRenderer omits AppKit-backed ScrollView. Render the same production
            // components in a clipped viewport; hosting size tests above cover scrolling.
            let renderer = ImageRenderer(
                content: SettingsView(model: model, scrollContent: false)
                    .frame(width: 430, height: 560)
                    .environment(\.colorScheme, theme == "dark" ? .dark : .light)
                    .background(theme == "dark" ? Color(white: 0.14) : Color(white: 0.97)))
            renderer.scale = 2
            let rendered = try XCTUnwrap(renderer.nsImage)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(rendered.tiffRepresentation)))
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("settings-\(theme)-continuous.png"))
        }
    }
}
