//
//  HotKey.swift
//  Mio
//
//  Codable hotkey representation. Pure value type; lives in Domain/
//  because it is shared across HotKeyManager (Services), HotKeySettings
//  (Settings), and SettingsView (Views) — placing it in any single
//  layer would create reverse-dependency between consumer layers.
//

import Foundation
import AppKit

nonisolated public struct HotKey: Codable, Equatable, Sendable {
    public var keyCode: UInt16
    public var modifiers: UInt
    public var characters: String?

    public static let supportedModifierMask: NSEvent.ModifierFlags = [.command, .option, .shift, .control]

    /// Sentinel meaning "no hotkey configured" — `keyCode == 0` with no
    /// modifiers is treated as unset by HotKeyManager (skip matching).
    public static let unset = HotKey(keyCode: 0, modifiers: 0, characters: nil)

    public static let defaultWindowCapture = HotKey(
        keyCode: 1,
        modifiers: NSEvent.ModifierFlags([.option, .command]).rawValue,
        characters: "s"
    )

    public static let defaultFullScreen = HotKey(
        keyCode: 1,
        modifiers: NSEvent.ModifierFlags([.option, .command, .shift]).rawValue,
        characters: "s"
    )

    public init(keyCode: UInt16, modifiers: UInt, characters: String?) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.characters = characters
    }

    public var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers).intersection(Self.supportedModifierMask)
    }

    /// True when this hotkey represents the "no shortcut configured"
    /// state. HotKeyManager skips matching for unset hotkeys.
    public var isUnset: Bool {
        keyCode == 0 && modifiers == 0
    }

    public var displayKey: String {
        Self.displayKey(for: keyCode, characters: characters)
    }

    public var displayParts: [String] {
        var parts: [String] = []
        if modifierFlags.contains(.control) { parts.append("Ctrl") }
        if modifierFlags.contains(.option) { parts.append("Opt") }
        if modifierFlags.contains(.shift) { parts.append("Shift") }
        if modifierFlags.contains(.command) { parts.append("Cmd") }
        parts.append(displayKey)
        return parts
    }

    public var displayString: String {
        displayParts.joined(separator: "+")
    }

    public var keyEquivalent: String {
        guard let chars = characters, !chars.isEmpty else {
            return ""
        }
        return chars.lowercased()
    }

    public static func normalizedModifiers(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection(Self.supportedModifierMask)
    }

    private static func displayKey(for keyCode: UInt16, characters: String?) -> String {
        if let special = specialKeyDisplay[keyCode] {
            return special
        }

        guard let chars = characters, !chars.isEmpty else {
            return String(format: NSLocalizedString("hotkey.key.code", comment: ""), keyCode)
        }

        if chars == " " {
            return NSLocalizedString("hotkey.key.space", comment: "")
        }

        return chars.uppercased()
    }

    private static let specialKeyDisplay: [UInt16: String] = [
        36: NSLocalizedString("hotkey.key.return", comment: ""),
        48: NSLocalizedString("hotkey.key.tab", comment: ""),
        49: NSLocalizedString("hotkey.key.space", comment: ""),
        51: NSLocalizedString("hotkey.key.delete", comment: ""),
        53: NSLocalizedString("hotkey.key.escape", comment: ""),
        117: NSLocalizedString("hotkey.key.forward_delete", comment: ""),
        115: NSLocalizedString("hotkey.key.home", comment: ""),
        119: NSLocalizedString("hotkey.key.end", comment: ""),
        116: NSLocalizedString("hotkey.key.page_up", comment: ""),
        121: NSLocalizedString("hotkey.key.page_down", comment: ""),
        123: NSLocalizedString("hotkey.key.left", comment: ""),
        124: NSLocalizedString("hotkey.key.right", comment: ""),
        125: NSLocalizedString("hotkey.key.down", comment: ""),
        126: NSLocalizedString("hotkey.key.up", comment: ""),
        122: "F1",
        120: "F2",
        99: "F3",
        118: "F4",
        96: "F5",
        97: "F6",
        98: "F7",
        100: "F8",
        101: "F9",
        109: "F10",
        103: "F11",
        111: "F12",
        105: "F13",
        107: "F14",
        113: "F15",
        106: "F16",
        64: "F17",
        79: "F18",
        80: "F19",
        90: "F20"
    ]
}
