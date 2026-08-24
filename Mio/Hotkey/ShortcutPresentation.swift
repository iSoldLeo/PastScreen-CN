//
//  ShortcutPresentation.swift
//  Mio
//
//  Converts layout-independent shortcut identity into user-facing text.
//

import Carbon.HIToolbox
import Foundation

nonisolated struct ShortcutPresentation: Equatable, Sendable {
    let compactLabel: String
    let accessibilityLabel: String
}

@MainActor
final class ShortcutLabelFormatter {
    func presentation(for shortcut: Shortcut) -> ShortcutPresentation {
        let keyLabel = specialKeyLabel(for: shortcut.keyCode)
            ?? translatedKeyLabel(for: shortcut.keyCode)
            ?? fallbackKeyLabel(for: shortcut.keyCode)

        let compactLabel = modifierSymbols(for: shortcut.modifiers) + keyLabel
        let accessibilityLabel: String
        if shortcut.keyCode == 114 {
            accessibilityLabel = String(
                format: NSLocalizedString(
                    "hotkey.accessibility.insert_help",
                    comment: "Accessibility explanation for a PC Insert key reported as Help by macOS"
                ),
                accessibilityModifierPrefix(for: shortcut.modifiers)
            )
        } else {
            accessibilityLabel = accessibilityModifierPrefix(for: shortcut.modifiers) + keyLabel
        }

        return ShortcutPresentation(
            compactLabel: compactLabel,
            accessibilityLabel: accessibilityLabel
        )
    }

    private func modifierSymbols(for modifiers: ShortcutModifiers) -> String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result
    }

    private func accessibilityModifierPrefix(for modifiers: ShortcutModifiers) -> String {
        var names: [String] = []
        if modifiers.contains(.control) {
            names.append(NSLocalizedString("hotkey.modifier.control", comment: "Control modifier"))
        }
        if modifiers.contains(.option) {
            names.append(NSLocalizedString("hotkey.modifier.option", comment: "Option modifier"))
        }
        if modifiers.contains(.shift) {
            names.append(NSLocalizedString("hotkey.modifier.shift", comment: "Shift modifier"))
        }
        if modifiers.contains(.command) {
            names.append(NSLocalizedString("hotkey.modifier.command", comment: "Command modifier"))
        }
        guard !names.isEmpty else { return "" }
        return names.joined(separator: ", ") + ", "
    }

    private func specialKeyLabel(for keyCode: UInt16) -> String? {
        if keyCode == 114 {
            return NSLocalizedString("hotkey.key.insert", comment: "PC Insert key, reported as Help by macOS")
        }

        if let functionKey = Self.functionKeyLabels[keyCode] {
            return functionKey
        }

        let localizationKey: String?
        switch keyCode {
        case 36: localizationKey = "hotkey.key.return"
        case 48: localizationKey = "hotkey.key.tab"
        case 49: localizationKey = "hotkey.key.space"
        case 51: localizationKey = "hotkey.key.delete"
        case 53: localizationKey = "hotkey.key.escape"
        case 117: localizationKey = "hotkey.key.forward_delete"
        case 115: localizationKey = "hotkey.key.home"
        case 119: localizationKey = "hotkey.key.end"
        case 116: localizationKey = "hotkey.key.page_up"
        case 121: localizationKey = "hotkey.key.page_down"
        case 123: localizationKey = "hotkey.key.left"
        case 124: localizationKey = "hotkey.key.right"
        case 125: localizationKey = "hotkey.key.down"
        case 126: localizationKey = "hotkey.key.up"
        default: localizationKey = nil
        }

        guard let localizationKey else { return nil }
        return NSLocalizedString(localizationKey, comment: "Special keyboard key")
    }

    private func translatedKeyLabel(for keyCode: UInt16) -> String? {
        guard
            let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
            let layoutDataPointer = TISGetInputSourceProperty(
                source,
                kTISPropertyUnicodeKeyLayoutData
            )
        else {
            return nil
        }

        let layoutData = unsafeBitCast(layoutDataPointer, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }
        let keyboardLayout = UnsafeRawPointer(bytes)
            .assumingMemoryBound(to: UCKeyboardLayout.self)

        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(
            keyboardLayout,
            keyCode,
            UInt16(kUCKeyActionDisplay),
            0,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            characters.count,
            &length,
            &characters
        )

        guard status == noErr, length > 0 else { return nil }
        let value = String(utf16CodeUnits: characters, count: length).uppercased()
        guard
            !value.isEmpty,
            value.unicodeScalars.allSatisfy(Self.isPresentable)
        else {
            return nil
        }
        return value
    }

    private func fallbackKeyLabel(for keyCode: UInt16) -> String {
        String(
            format: NSLocalizedString(
                "hotkey.key.code",
                comment: "Fallback keyboard key label containing a decimal virtual key code"
            ),
            keyCode
        )
    }

    private static func isPresentable(_ scalar: Unicode.Scalar) -> Bool {
        guard !CharacterSet.controlCharacters.contains(scalar) else { return false }
        return !(0xE000...0xF8FF).contains(scalar.value)
            && !(0xF0000...0xFFFFD).contains(scalar.value)
            && !(0x100000...0x10FFFD).contains(scalar.value)
    }

    private static let functionKeyLabels: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5",
        97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"
    ]
}
