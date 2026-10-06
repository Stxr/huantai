import AppKit

// App-local recording scoped to the existing popover (or explicit review window).
// No global event tap, input monitoring or additional settings window is needed.
final class SettingsKeyMonitor {
    private let model: AppModel
    private var monitor: Any?

    init(model: AppModel, installMonitor: Bool = true, window: @escaping () -> NSWindow?) {
        self.model = model
        if installMonitor {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return self.handle(event, in: window())
            }
        }
    }

    func handle(_ event: NSEvent, in window: NSWindow?) -> NSEvent? {
        guard let window, event.window === window, model.page == .settings else { return event }
        if let action = model.recordingAction {
            if event.keyCode == 53 {
                model.endRecording()
            } else {
                model.updateShortcut(action, binding: ShortcutBinding(event: event))
            }
            return nil
        }
        if event.keyCode == 53 {
            model.showSessions()
            return nil
        }
        return event
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
