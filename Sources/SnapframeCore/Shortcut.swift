import Foundation

/// Values match Carbon's modifier masks so they can be passed straight to `RegisterEventHotKey`.
public struct ShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let command = ShortcutModifiers(rawValue: 256)
    public static let shift = ShortcutModifiers(rawValue: 512)
    public static let option = ShortcutModifiers(rawValue: 2048)
    public static let control = ShortcutModifiers(rawValue: 4096)
}

public struct Shortcut: Codable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: ShortcutModifiers

    public init(keyCode: UInt32, modifiers: ShortcutModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    private static let keyNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N",
        46: "M", 47: ".", 50: "`",
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    private static let functionKeys: [UInt32: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    public var keyName: String {
        Self.keyNames[keyCode] ?? Self.functionKeys[keyCode] ?? "Key \(keyCode)"
    }

    public var displayString: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + keyName
    }

    /// The character to show in an `NSMenuItem`, when the key has a plain one.
    public var menuKeyEquivalent: String? {
        guard let name = Self.keyNames[keyCode], name.count == 1,
              name.unicodeScalars.first?.isASCII == true
        else { return nil }
        return name.lowercased()
    }

    /// Shift alone, or no modifier at all, would steal ordinary typing.
    public var isValidGlobalShortcut: Bool {
        if Self.functionKeys[keyCode] != nil { return true }
        return !modifiers.isDisjoint(with: [.command, .control, .option])
    }
}

public enum ShortcutAction: String, CaseIterable, Codable, Sendable {
    case allInOne, area, previousArea, window, fullscreen, selfTimer

    public var title: String {
        switch self {
        case .allInOne: return "All-In-One"
        case .area: return "Capture Area"
        case .previousArea: return "Capture Previous Area"
        case .window: return "Capture Window"
        case .fullscreen: return "Capture Fullscreen"
        case .selfTimer: return "Self-Timer"
        }
    }

    /// Control-Option defaults leave the macOS Command-Shift screenshot shortcuts untouched.
    public var defaultShortcut: Shortcut {
        let modifiers: ShortcutModifiers = [.control, .option]
        switch self {
        case .allInOne: return Shortcut(keyCode: 18, modifiers: modifiers)  // 1
        case .area: return Shortcut(keyCode: 21, modifiers: modifiers)  // 4
        case .previousArea: return Shortcut(keyCode: 35, modifiers: modifiers)  // P
        case .window: return Shortcut(keyCode: 23, modifiers: modifiers)  // 5
        case .fullscreen: return Shortcut(keyCode: 20, modifiers: modifiers)  // 3
        case .selfTimer: return Shortcut(keyCode: 17, modifiers: modifiers)  // T
        }
    }
}

/// Reads the shortcuts macOS itself has reserved, from the `com.apple.symbolichotkeys` preferences.
public enum SystemShortcuts {
    /// macOS leaves these out of its preferences until the user changes them, so they start as enabled.
    private static let builtInScreenshotShortcuts: [String: Shortcut] = [
        "28": Shortcut(keyCode: 20, modifiers: [.shift, .command]),
        "29": Shortcut(keyCode: 20, modifiers: [.control, .shift, .command]),
        "30": Shortcut(keyCode: 21, modifiers: [.shift, .command]),
        "31": Shortcut(keyCode: 21, modifiers: [.control, .shift, .command]),
        "184": Shortcut(keyCode: 23, modifiers: [.shift, .command]),
    ]

    public static func reserved(from symbolicHotKeys: [String: Any]?) -> Set<Shortcut> {
        var active = builtInScreenshotShortcuts
        for (id, rawEntry) in symbolicHotKeys ?? [:] {
            guard let entry = rawEntry as? [String: Any] else { continue }
            guard (entry["enabled"] as? Bool) ?? ((entry["enabled"] as? Int) == 1) else {
                active[id] = nil
                continue
            }
            guard let value = entry["value"] as? [String: Any],
                  let parameters = value["parameters"] as? [Int],
                  parameters.count >= 3, parameters[1] != 65535
            else { continue }
            active[id] = Shortcut(
                keyCode: UInt32(parameters[1]),
                modifiers: modifiers(fromEventFlags: parameters[2])
            )
        }
        return Set(active.values)
    }

    private static func modifiers(fromEventFlags flags: Int) -> ShortcutModifiers {
        var result: ShortcutModifiers = []
        if flags & 131072 != 0 { result.insert(.shift) }
        if flags & 262144 != 0 { result.insert(.control) }
        if flags & 524288 != 0 { result.insert(.option) }
        if flags & 1048576 != 0 { result.insert(.command) }
        return result
    }
}
