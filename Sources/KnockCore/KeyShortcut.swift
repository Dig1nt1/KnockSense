import Foundation

/// A keyboard shortcut such as "cmd+shift+a", with the macOS virtual key code to press it.
/// Key codes are for the US (ANSI) layout, the same physical keys on other layouts.
public struct KeyShortcut: Equatable, Sendable {
    public enum Modifier: String, CaseIterable, Sendable {
        case control, option, shift, command

        var symbol: String {
            switch self {
            case .control: return "⌃"
            case .option: return "⌥"
            case .shift: return "⇧"
            case .command: return "⌘"
            }
        }
    }

    public let modifiers: Set<Modifier>
    public let key: String
    public let keyCode: UInt16

    /// Parses "cmd+shift+a", "ctrl+opt+space", "⌘T" style text. Needs exactly one non-modifier key.
    public static func parse(_ text: String) -> KeyShortcut? {
        var rest = text.lowercased().replacingOccurrences(of: " ", with: "")
        var modifiers = Set<Modifier>()
        // Leading symbols like ⌘⇧A.
        for (symbol, modifier) in [("⌘", Modifier.command), ("⇧", .shift), ("⌥", .option), ("⌃", .control)] {
            if rest.contains(symbol) {
                modifiers.insert(modifier)
                rest = rest.replacingOccurrences(of: symbol, with: "")
            }
        }
        var key: String?
        let parts = rest.split(separator: "+", omittingEmptySubsequences: true).map(String.init)
        // "cmd++" means the plus key.
        let tokens = rest.hasSuffix("++") ? parts + ["+"] : parts
        for token in tokens {
            if let modifier = modifierAliases[token] {
                modifiers.insert(modifier)
            } else if key == nil {
                key = keyAliases[token] ?? token
            } else {
                return nil
            }
        }
        guard let name = key, let code = keyCodes[name] else { return nil }
        return KeyShortcut(modifiers: modifiers, key: name, keyCode: code)
    }

    /// Builds a shortcut from a pressed key (e.g. while recording one).
    public static func from(keyCode: UInt16, modifiers: Set<Modifier>) -> KeyShortcut? {
        guard let name = keyCodes.first(where: { $0.value == keyCode })?.key else { return nil }
        return KeyShortcut(modifiers: modifiers, key: name, keyCode: keyCode)
    }

    /// Canonical text form, e.g. "cmd+shift+a".
    public var string: String {
        let order: [Modifier] = [.control, .option, .shift, .command]
        let names: [Modifier: String] = [.control: "ctrl", .option: "opt", .shift: "shift", .command: "cmd"]
        return (order.filter(modifiers.contains).compactMap { names[$0] } + [key]).joined(separator: "+")
    }

    /// Mac-style display, e.g. "⇧⌘A".
    public var display: String {
        let order: [Modifier] = [.control, .option, .shift, .command]
        let symbols = order.filter(modifiers.contains).map(\.symbol).joined()
        return symbols + (Self.keySymbols[key] ?? key.uppercased())
    }

    // MARK: - Tables

    static let modifierAliases: [String: Modifier] = [
        "cmd": .command, "command": .command, "shift": .shift,
        "opt": .option, "option": .option, "alt": .option,
        "ctrl": .control, "control": .control,
    ]

    static let keyAliases: [String: String] = [
        "enter": "return", "esc": "escape", "backspace": "delete", "del": "delete",
        "plus": "=", "minus": "-", "arrowleft": "left", "arrowright": "right", "arrowup": "up", "arrowdown": "down",
    ]

    static let keySymbols: [String: String] = [
        "return": "↩", "tab": "⇥", "space": "Space", "delete": "⌫", "forwarddelete": "⌦", "escape": "⎋",
        "left": "←", "right": "→", "up": "↑", "down": "↓", "home": "↖", "end": "↘", "pageup": "⇞", "pagedown": "⇟",
    ]

    static let keyCodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
        "p": 35, "return": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50, "delete": 51, "escape": 53,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101,
        "f10": 109, "f11": 103, "f12": 111, "home": 115, "pageup": 116, "forwarddelete": 117, "end": 119,
        "pagedown": 121, "left": 123, "right": 124, "down": 125, "up": 126,
    ]
}
