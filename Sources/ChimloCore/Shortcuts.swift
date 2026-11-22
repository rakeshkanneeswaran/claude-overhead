import Foundation

/// Things a global shortcut can trigger.
public enum ShortcutAction: String, Codable, Sendable, CaseIterable, Identifiable {
    case togglePanel
    case showSessions
    case nextSession
    case previousSession
    case focusTerminal
    case openHistory
    case toggleFocusMode
    case openSettings
    case toggleGitHubMode

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .togglePanel: "Toggle panel"
        case .showSessions: "Show sessions"
        case .nextSession: "Next session"
        case .previousSession: "Previous session"
        case .focusTerminal: "Focus terminal"
        case .openHistory: "Open history"
        case .toggleFocusMode: "Toggle Focus mode"
        case .openSettings: "Open settings"
        case .toggleGitHubMode: "Toggle GitHub Mode"
        }
    }
}

/// Modifier keys, with Overhead's own bit values. They are not AppKit or Carbon
/// constants, so the saved settings never depend on a framework's numbering;
/// `carbonFlags` converts for hot-key registration.
public struct KeyModifiers: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let option = KeyModifiers(rawValue: 1 << 1)
    public static let control = KeyModifiers(rawValue: 1 << 2)
    public static let shift = KeyModifiers(rawValue: 1 << 3)

    /// Carbon `RegisterEventHotKey` modifier mask (cmdKey, shiftKey, optionKey,
    /// controlKey). Hard-coded because Core does not import Carbon.
    public var carbonFlags: UInt32 {
        var flags: UInt32 = 0
        if contains(.command) { flags |= 0x0100 }
        if contains(.shift) { flags |= 0x0200 }
        if contains(.option) { flags |= 0x0800 }
        if contains(.control) { flags |= 0x1000 }
        return flags
    }

    /// Symbols in the order macOS menus use: ⌃⌥⇧⌘.
    public var symbols: String {
        var result = ""
        if contains(.control) { result += "⌃" }
        if contains(.option) { result += "⌥" }
        if contains(.shift) { result += "⇧" }
        if contains(.command) { result += "⌘" }
        return result
    }
}

/// macOS virtual key codes (Carbon `kVK_*`) for the keys Overhead names.
public enum VirtualKey {
    public static let a: UInt16 = 0
    public static let s: UInt16 = 1
    public static let f: UInt16 = 3
    public static let h: UInt16 = 4
    public static let m: UInt16 = 46
    public static let o: UInt16 = 31
    public static let g: UInt16 = 5
    public static let q: UInt16 = 12
    public static let t: UInt16 = 17
    public static let w: UInt16 = 13
    public static let three: UInt16 = 20
    public static let four: UInt16 = 21
    public static let five: UInt16 = 23
    public static let rightBracket: UInt16 = 30
    public static let leftBracket: UInt16 = 33
    public static let comma: UInt16 = 43
    public static let tab: UInt16 = 48
    public static let space: UInt16 = 49
    public static let grave: UInt16 = 50
    public static let escape: UInt16 = 53
    public static let leftArrow: UInt16 = 123
    public static let rightArrow: UInt16 = 124
    public static let downArrow: UInt16 = 125
    public static let upArrow: UInt16 = 126

    /// The label a key shows in a shortcut. ANSI layout names: shortcuts are
    /// matched by physical key, so the label describes the physical key too.
    static func label(for keyCode: UInt16) -> String {
        if let name = names[keyCode] { return name }
        return "Key \(keyCode)"
    }

    private static let names: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space", 50: "`", 51: "⌫", 53: "⎋",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        105: "F13", 106: "F16", 107: "F14", 109: "F10", 111: "F12", 113: "F15",
        115: "↖", 116: "⇞", 117: "⌦", 118: "F4", 119: "↘", 120: "F2", 121: "⇟", 122: "F1",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
}

/// One key plus modifiers.
public struct KeyCombo: Codable, Equatable, Sendable, Hashable {
    /// macOS virtual key code (`kVK_*`).
    public let keyCode: UInt16
    public let modifiers: KeyModifiers

    public init(keyCode: UInt16, modifiers: KeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// For example "⌃⌥O", modifiers in ⌃⌥⇧⌘ order.
    public var displayString: String {
        modifiers.symbols + VirtualKey.label(for: keyCode)
    }
}

public enum ShortcutDefaults {
    /// ⌃⌥ plus a mnemonic letter: rarely claimed by macOS or common apps, and
    /// reachable with one hand.
    public static let bindings: [ShortcutAction: KeyCombo] = [
        .togglePanel: KeyCombo(keyCode: VirtualKey.o, modifiers: base),
        .showSessions: KeyCombo(keyCode: VirtualKey.s, modifiers: base),
        .nextSession: KeyCombo(keyCode: VirtualKey.rightBracket, modifiers: base),
        .previousSession: KeyCombo(keyCode: VirtualKey.leftBracket, modifiers: base),
        .focusTerminal: KeyCombo(keyCode: VirtualKey.t, modifiers: base),
        .openHistory: KeyCombo(keyCode: VirtualKey.h, modifiers: base),
        .toggleFocusMode: KeyCombo(keyCode: VirtualKey.f, modifiers: base),
        .openSettings: KeyCombo(keyCode: VirtualKey.comma, modifiers: base),
        .toggleGitHubMode: KeyCombo(keyCode: VirtualKey.g, modifiers: base),
    ]

    private static let base: KeyModifiers = [.control, .option]
}

public enum ShortcutConflict: Equatable, Sendable {
    /// Another action already uses this combination.
    case duplicate(ShortcutAction)
    /// macOS uses this combination; the associated value names the feature.
    case reservedBySystem(String)
    /// A global shortcut without ⌘, ⌃ or ⌥ would fire while typing.
    case needsModifier
}

/// A combination macOS keeps for itself.
public struct ReservedShortcut: Equatable, Sendable {
    public let combo: KeyCombo
    public let feature: String

    public init(combo: KeyCombo, feature: String) {
        self.combo = combo
        self.feature = feature
    }
}

public enum ShortcutValidator {
    /// System shortcuts a global hot key would shadow or never receive.
    public static let reservedShortcuts: [ReservedShortcut] = [
        reserved(VirtualKey.space, [.command], "Spotlight"),
        reserved(VirtualKey.space, [.control], "Input source switching"),
        reserved(VirtualKey.tab, [.command], "App switcher"),
        reserved(VirtualKey.q, [.command], "Quit"),
        reserved(VirtualKey.w, [.command], "Close window"),
        reserved(VirtualKey.h, [.command], "Hide app"),
        reserved(VirtualKey.m, [.command], "Minimize window"),
        reserved(VirtualKey.three, [.command, .shift], "Screenshot"),
        reserved(VirtualKey.four, [.command, .shift], "Screenshot of selection"),
        reserved(VirtualKey.five, [.command, .shift], "Screenshot and recording options"),
        reserved(VirtualKey.upArrow, [.control], "Mission Control"),
        reserved(VirtualKey.downArrow, [.control], "App Exposé"),
        reserved(VirtualKey.leftArrow, [.control], "Move left a space"),
        reserved(VirtualKey.rightArrow, [.control], "Move right a space"),
        reserved(VirtualKey.escape, [.command, .option], "Force Quit"),
        reserved(VirtualKey.grave, [.command], "Cycle windows"),
    ]

    /// Problems with binding `combo` to `action`, in a stable order:
    /// missing modifier, system reservation, then clashing actions in
    /// `ShortcutAction.allCases` order. Empty means the binding is safe.
    public static func conflicts(
        for combo: KeyCombo,
        action: ShortcutAction,
        in bindings: [ShortcutAction: KeyCombo]
    ) -> [ShortcutConflict] {
        var result: [ShortcutConflict] = []
        if combo.modifiers.isDisjoint(with: [.command, .control, .option]) {
            result.append(.needsModifier)
        }
        if let reserved = reservedShortcuts.first(where: { $0.combo == combo }) {
            result.append(.reservedBySystem(reserved.feature))
        }
        for other in ShortcutAction.allCases where other != action && bindings[other] == combo {
            result.append(.duplicate(other))
        }
        return result
    }

    private static func reserved(_ keyCode: UInt16, _ modifiers: KeyModifiers, _ feature: String) -> ReservedShortcut {
        ReservedShortcut(combo: KeyCombo(keyCode: keyCode, modifiers: modifiers), feature: feature)
    }
}
