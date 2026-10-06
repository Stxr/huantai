import AppKit

/// Observe outside mouse clicks only while our popover is shown; no keyboard monitoring.
final class PopoverDismissalMonitor {
    private var local: Any?
    private var global: Any?
    private var deactivation: NSObjectProtocol?

    static func shouldDismiss(
        point: NSPoint, popoverFrame: NSRect, statusButtonFrame: NSRect?, hasModalWindow: Bool
    ) -> Bool {
        !hasModalWindow && !popoverFrame.contains(point)
            && !(statusButtonFrame?.contains(point) ?? false)
    }

    func start(
        window: @escaping () -> NSWindow?, statusButtonFrame: @escaping () -> NSRect?,
        close: @escaping () -> Void
    ) {
        stop()
        let outsideClick: (NSEvent) -> Void = { event in
            guard let popover = window() else { return }
            let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
            if Self.shouldDismiss(
                point: point, popoverFrame: popover.frame, statusButtonFrame: statusButtonFrame(),
                hasModalWindow: NSApplication.shared.modalWindow != nil)
            {
                close()
            }
        }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        local = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            outsideClick(event)
            return event
        }
        global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: outsideClick)
        deactivation = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: NSApplication.shared, queue: .main
        ) { _ in
            if window() != nil && NSApplication.shared.modalWindow == nil { close() }
        }
    }

    func stop() {
        if let local { NSEvent.removeMonitor(local) }
        if let global { NSEvent.removeMonitor(global) }
        if let deactivation { NotificationCenter.default.removeObserver(deactivation) }
        local = nil
        global = nil
        deactivation = nil
    }

    deinit { stop() }
}
