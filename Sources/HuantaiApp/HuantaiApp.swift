import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var model: AppModel?
    private var reviewWindow: NSWindow?
    private var popoverController: NSHostingController<PopoverView>?
    private var appearanceBinding: AnyCancellable?
    private var statusIconBinding: AnyCancellable?
    private var settingsKeyMonitor: SettingsKeyMonitor?
    private var shortcutManager: GlobalShortcutManager?
    private var toastController: SessionToastController?
    private let dismissalMonitor = PopoverDismissalMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let testing = ProcessInfo.processInfo.environment["HUANTAI_TEST_MODE"] == "1"
        let reviewing = CommandLine.arguments.contains("--review")
        NSApplication.shared.setActivationPolicy(testing || reviewing ? .regular : .accessory)
        let model = AppModel(store: AppLaunchConfiguration.store())
        self.model = model
        toastController = SessionToastController(model: model)
        model.onSettingsRequested = { [weak self] in self?.presentPopover() }
        model.onPopoverToggleRequested = { [weak self] in self?.togglePopover() }
        configureApplicationMenu()
        configureShortcuts(model)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        let controller = NSHostingController(rootView: PopoverView(model: model))
        controller.sizingOptions = []
        controller.preferredContentSize = PopoverLayout.preferredSize
        controller.view.setFrameSize(PopoverLayout.preferredSize)
        popover.contentViewController = controller
        popover.contentSize = PopoverLayout.preferredSize
        self.popoverController = controller
        self.popover = popover
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        self.statusItem = item
        if let button = item.button {
            statusIconBinding = MenuBarIcon.bind(model: model, button: button)
        }
        if reviewing {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 430, height: 560),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "换台 · 原生界面审阅"
            window.contentViewController = NSHostingController(rootView: PopoverView(model: model))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            window.makeKeyAndOrderFront(nil)
            self.reviewWindow = window
            NSApplication.shared.activate(ignoringOtherApps: true)
        } else if CommandLine.arguments.contains("--show") && !CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.async { self.togglePopover() }
        }
        appearanceBinding = PopoverAppearance.bind(
            model: model, popover: popover, controller: controller, reviewWindow: reviewWindow)
        settingsKeyMonitor = SettingsKeyMonitor(model: model) { [weak self] in
            self?.reviewWindow ?? self?.popoverController?.view.window
        }
        if CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.async { self.showSettings() }
        }
    }

    private func configureApplicationMenu() {
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "换台")
        let settings = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settings.keyEquivalentModifierMask = .command
        settings.target = self
        applicationMenu.addItem(settings)
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(
            NSMenuItem(title: "退出换台", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)
        NSApplication.shared.mainMenu = mainMenu
    }

    private func configureShortcuts(_ model: AppModel) {
        do {
            let manager = try GlobalShortcutManager { [weak model] action in model?.performShortcut(action) }
            shortcutManager = manager
            model.onShortcutConfiguration = { [weak manager, weak model] bindings in
                guard let manager else { throw ShortcutError.message("全局快捷键服务未运行。") }
                defer { if model?.recordingAction != nil { manager.suspend() } }
                try manager.replace(with: bindings)
            }
            model.onRecordingChanged = { [weak manager, weak model] recording in
                guard let manager, let model else { return }
                if recording {
                    manager.suspend()
                } else {
                    do { try manager.replace(with: model.shortcuts) } catch {
                        model.reportShortcutStatus(error.localizedDescription)
                    }
                }
            }
            do {
                // Keep existing navigation available if the newly added wake key is occupied.
                if model.shortcuts.keys.contains(where: { $0.navigationAction == nil }) {
                    try manager.replace(with: model.shortcuts.filter { $0.key.navigationAction != nil })
                }
                try manager.replace(with: model.shortcuts)
                model.reportShortcutStatus(
                    model.shortcuts.isEmpty ? "全局快捷键已关闭" : "已启用 \(model.shortcuts.count) 项全局快捷键")
            } catch { model.reportShortcutStatus(error.localizedDescription) }
        } catch {
            model.reportShortcutStatus(error.localizedDescription)
            model.onShortcutConfiguration = { _ in throw error }
        }
    }

    @objc private func showSettings() {
        model?.showSettings()
    }

    private func presentPopover() {
        if let reviewWindow {
            reviewWindow.makeKeyAndOrderFront(nil)
        } else if popover?.isShown == true {
            popoverController?.view.window?.makeKeyAndOrderFront(nil)
        } else {
            togglePopover()
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func popoverDidShow(_ notification: Notification) {
        dismissalMonitor.start(
            window: { [weak self] in
                guard self?.popover?.isShown == true else { return nil }
                return self?.popoverController?.view.window
            },
            statusButtonFrame: { [weak self] in
                guard let button = self?.statusItem?.button, let window = button.window else { return nil }
                return window.convertToScreen(button.convert(button.bounds, to: nil))
            }, close: { [weak self] in self?.popover?.performClose(nil) })
    }

    func popoverDidClose(_ notification: Notification) {
        dismissalMonitor.stop()
        model?.popoverClosed()
    }

    func windowWillClose(_ notification: Notification) { model?.popoverClosed() }

    @objc private func togglePopover() {
        if let reviewWindow {
            if reviewWindow.isVisible {
                reviewWindow.orderOut(nil)
                model?.popoverClosed()
            } else {
                reviewWindow.makeKeyAndOrderFront(nil)
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            return
        }
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            if let window = button.window, let screen = window.screen, let model,
                let controller = popoverController
            {
                let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
                let size = PopoverLayout.contentSize(visibleFrame: screen.visibleFrame, anchor: anchor)
                if controller.rootView.contentSize != size {
                    controller.rootView = PopoverView(model: model, contentSize: size)
                }
                controller.preferredContentSize = size
                controller.view.setFrameSize(size)
                popover.contentSize = size
            }
            popover.show(
                relativeTo: button.bounds, of: button,
                preferredEdge: PopoverLayout.bottomEdge(isFlipped: button.isFlipped))
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let reviewWindow {
            reviewWindow.makeKeyAndOrderFront(nil)
            return false
        }
        if popover?.isShown != true { togglePopover() }
        return false
    }
}

@main
struct HuantaiApplication {
    static func main() {
        let application = NSApplication.shared
        if CommandLine.arguments.contains("--check-login-item") {
            let loginItem = LoginItemManager()
            print("开机运行：\(loginItem.statusDescription)")
            return
        }
        if CommandLine.arguments.contains("--check-shortcuts") {
            do {
                let model = AppModel(startServices: false)
                let manager = try GlobalShortcutManager { _ in }
                try manager.replace(with: model.shortcuts)
                print("全局快捷键注册成功：\(model.shortcuts.count) 项。")
                withExtendedLifetime(manager) {}
            } catch {
                fputs(error.localizedDescription + "\n", stderr)
                exit(1)
            }
            return
        }
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
