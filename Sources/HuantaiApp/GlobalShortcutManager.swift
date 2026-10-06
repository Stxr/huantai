import AppKit
import Carbon
import HuantaiCore

final class ShortcutRegistration {
    private let cancel: () -> Void
    init(cancel: @escaping () -> Void) { self.cancel = cancel }
    deinit { cancel() }
}

/// Carbon registers specific combinations; it does not monitor arbitrary typing or require Accessibility.
final class GlobalShortcutManager {
    typealias Register = (ShortcutBinding, UInt32) throws -> ShortcutRegistration
    private static let signature: OSType = 0x4874_5449
    private let register: Register
    private let onAction: (ShortcutAction) -> Void
    private var handler: EventHandlerRef?
    private var registrations: [ShortcutAction: ShortcutRegistration] = [:]
    private var bindings: [ShortcutAction: ShortcutBinding] = [:]
    private var completionKeyHeld = false

    init(register: Register? = nil, onAction: @escaping (ShortcutAction) -> Void) throws {
        self.onAction = onAction
        self.register = register ?? Self.registerNative
        if register == nil {
            var eventTypes = [kEventHotKeyPressed, kEventHotKeyReleased].map {
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32($0))
            }
            let status = eventTypes.withUnsafeMutableBufferPointer {
                InstallEventHandler(
                    GetApplicationEventTarget(), huantaiHotKeyHandler, $0.count,
                    $0.baseAddress, Unmanaged.passUnretained(self).toOpaque(), &handler)
            }
            guard status == noErr else { throw ShortcutError.message("全局快捷键初始化失败（\(status)）。") }
        }
    }

    deinit {
        registrations.removeAll()
        if let handler { RemoveEventHandler(handler) }
    }

    func replace(with proposed: [ShortcutAction: ShortcutBinding]) throws {
        try ShortcutBinding.validate(proposed)
        let previous = bindings
        registrations.removeAll()
        completionKeyHeld = false
        do {
            registrations = try registerAll(proposed)
            bindings = proposed
        } catch {
            let original = error
            do { registrations = try registerAll(previous) } catch {
                throw ShortcutError.message(original.localizedDescription + " 原快捷键恢复失败，请在设置中重新保存。")
            }
            throw original
        }
    }

    func suspend() {
        registrations.removeAll()
        completionKeyHeld = false
    }

    fileprivate func handle(_ id: EventHotKeyID, pressed: Bool) {
        guard id.signature == Self.signature, id.id > 0,
            Int(id.id) <= ShortcutAction.allCases.count
        else { return }
        let action = ShortcutAction.allCases[Int(id.id) - 1]
        handle(action, pressed: pressed)
    }

    func handle(_ action: ShortcutAction, pressed: Bool) {
        if action == .completeCurrent {
            if !pressed {
                completionKeyHeld = false
                return
            }
            guard !completionKeyHeld, registrations[action] != nil else { return }
            completionKeyHeld = true
        }
        if pressed { dispatch(action) }
    }

    func dispatch(_ action: ShortcutAction) {
        guard registrations[action] != nil else { return }
        onAction(action)
    }

    private func registerAll(_ bindings: [ShortcutAction: ShortcutBinding]) throws
        -> [ShortcutAction: ShortcutRegistration]
    {
        var result: [ShortcutAction: ShortcutRegistration] = [:]
        for (index, action) in ShortcutAction.allCases.enumerated() {
            if let binding = bindings[action] { result[action] = try register(binding, UInt32(index + 1)) }
        }
        return result
    }

    private static func registerNative(_ binding: ShortcutBinding, _ id: UInt32) throws
        -> ShortcutRegistration
    {
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            binding.keyCode, binding.carbonModifiers,
            EventHotKeyID(signature: signature, id: id), GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else {
            throw ShortcutError.message("\(binding.display) 注册失败，可能已被系统或其他应用占用（\(status)）；请选择其他组合。")
        }
        return ShortcutRegistration { UnregisterEventHotKey(reference) }
    }
}

private let huantaiHotKeyHandler: EventHandlerUPP = { _, event, context in
    guard let event, let context else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard status == noErr else { return status }
    Unmanaged<GlobalShortcutManager>.fromOpaque(context).takeUnretainedValue().handle(
        id,
        pressed: GetEventKind(event) == UInt32(kEventHotKeyPressed))
    return noErr
}
