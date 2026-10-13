import AppKit
import HuantaiCore
import HuantaiFeishu
import SwiftUI
import XCTest

@testable import HuantaiApp

final class FeishuBotSettingsTests: XCTestCase {
    @MainActor
    func testSettingsObserveCLIConfigurationAndPersistFiltersAndUnbind() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "huantai-feishu-ui-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(
            dataDirectory: root, codexDirectory: root, botmuxDirectory: root, deepSeekHarnessDirectory: root)
        let config = FeishuBotConfiguration(dataDirectory: root)
        let manager = FeishuBotManager(store: store, startServices: false)
        XCTAssertNil(manager.binding)
        try config.bind(appID: "cli_fixture", secret: "SYNTHETIC_SECRET")
        manager.reload()
        XCTAssertEqual(manager.binding?.appID, "cli_fixture")
        var filter = FeishuDashboardFilter()
        filter.days = 3
        filter.favoritesOnly = true
        manager.setFilter(filter)
        XCTAssertEqual(try config.binding()?.filter, filter)
        let controller = NSHostingController(
            rootView: FeishuBotSettingsView(manager: manager).frame(width: 390))
        let size = controller.sizeThatFits(in: NSSize(width: 390, height: 1500))
        XCTAssertEqual(size.width, 390, accuracy: 1)
        XCTAssertLessThan(size.height, 900)
        if let path = ProcessInfo.processInfo.environment["HUANTAI_RENDER_FEISHU_DIR"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for theme in ["light", "dark"] {
                let host = NSHostingController(
                    rootView: FeishuBotSettingsView(manager: manager)
                        .padding(20).frame(width: 430)
                        .environment(\.colorScheme, theme == "dark" ? .dark : .light)
                        .background(theme == "dark" ? Color(white: 0.14) : Color(white: 0.97)))
                let size = host.sizeThatFits(in: NSSize(width: 430, height: 1500))
                let window = NSWindow(
                    contentRect: NSRect(origin: NSPoint(x: -2000, y: -2000), size: size),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentViewController = host
                window.appearance = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
                window.orderBack(nil)
                defer { window.orderOut(nil) }
                window.layoutIfNeeded()
                host.view.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
                host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
                    to: directory.appendingPathComponent("feishu-\(theme).png"))
            }
        }
        manager.unbind()
        XCTAssertNil(manager.binding)
        XCTAssertNil(try config.binding())
        XCTAssertEqual(manager.status, "未绑定")
    }
}
