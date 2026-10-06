import AppKit
import Carbon
import HuantaiCore

// Application actions stay separate from the Core's session-navigation history.
enum ShortcutAction: String, Codable, CaseIterable {
    case previous, next, first, back, forward, showPopover, completeCurrent, undoCompletion

    var navigationAction: SessionNavigationAction? { SessionNavigationAction(rawValue: rawValue) }
    static var navigationActions: [Self] { allCases.filter { $0.navigationAction != nil } }
}

struct ShortcutBinding: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt
    var keyLabel: String

    static let allowedFlags: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
    var flags: NSEvent.ModifierFlags { .init(rawValue: modifiers) }
    var identity: String { "\(keyCode):\(modifiers)" }
    var display: String {
        (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + keyLabel
    }
    var carbonModifiers: UInt32 {
        (flags.contains(.command) ? UInt32(cmdKey) : 0)
            | (flags.contains(.shift) ? UInt32(shiftKey) : 0)
            | (flags.contains(.option) ? UInt32(optionKey) : 0)
            | (flags.contains(.control) ? UInt32(controlKey) : 0)
    }

    init(keyCode: UInt32, flags: NSEvent.ModifierFlags, keyLabel: String) {
        self.keyCode = keyCode
        modifiers = flags.intersection(Self.allowedFlags).rawValue
        self.keyLabel = keyLabel
    }

    init(event: NSEvent) {
        let labels: [UInt16: String] = [
            123: "←", 124: "→", 125: "↓", 126: "↑", 42: "\\", 43: ",",
            36: "↩", 48: "⇥", 49: "空格", 51: "⌫", 53: "⎋",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
            105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
            115: "Home", 119: "End", 116: "Page Up", 121: "Page Down", 117: "⌦",
        ]
        self.init(
            keyCode: UInt32(event.keyCode), flags: event.modifierFlags,
            keyLabel: labels[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased()
                ?? "键\(event.keyCode)")
    }

    static var defaults: [ShortcutAction: ShortcutBinding] {
        [
            .previous: .init(keyCode: 126, flags: [.command, .shift], keyLabel: "↑"),
            .next: .init(keyCode: 125, flags: [.command, .shift], keyLabel: "↓"),
            .first: .init(keyCode: 42, flags: [.command, .shift], keyLabel: "\\"),
            .back: .init(keyCode: 123, flags: [.command, .shift], keyLabel: "←"),
            .forward: .init(keyCode: 124, flags: [.command, .shift], keyLabel: "→"),
            .showPopover: .init(keyCode: 43, flags: [.command, .option], keyLabel: ","),
            .completeCurrent: .init(keyCode: 2, flags: [.command, .shift], keyLabel: "D"),
            .undoCompletion: .init(keyCode: 6, flags: [.command, .shift], keyLabel: "Z"),
        ]
    }

    static func validate(_ bindings: [ShortcutAction: ShortcutBinding]) throws {
        var seen = Set<String>()
        for action in ShortcutAction.allCases {
            guard let binding = bindings[action] else { continue }
            guard binding.keyCode < 128, binding.modifiers & ~allowedFlags.rawValue == 0,
                !binding.flags.intersection([.command, .control, .option]).isEmpty,
                !binding.keyLabel.isEmpty, binding.keyLabel.count <= 12,
                !binding.keyLabel.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            else { throw ShortcutError.message("请使用包含 ⌘、⌃ 或 ⌥ 的快捷键组合。") }
            guard !(binding.keyCode == 43 && binding.flags == .command) else {
                throw ShortcutError.message("⌘, 用于打开设置，请为其他操作选择不同组合。")
            }
            guard seen.insert(binding.identity).inserted else {
                throw ShortcutError.message("\(binding.display) 已分配给其他会话操作，请使用不同组合。")
            }
        }
    }
}

enum ShortcutError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}

extension ShortcutAction {
    var title: String {
        switch self {
        case .previous: return "上一个会话"
        case .next: return "下一个会话"
        case .first: return "第一个会话"
        case .back: return "后退"
        case .forward: return "前进"
        case .showPopover: return "打开 / 关闭浮窗"
        case .completeCurrent: return "完成并切换下一项"
        case .undoCompletion: return "撤回完成并返回会话"
        }
    }
}
