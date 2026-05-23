//
//  HotKeySettings.swift
//  Mio
//
//  Hotkey-scoped settings: the global capture hotkey and its enabled
//  flag. HotKeyManager subscribes to `$globalHotkeyEnabled` for
//  enable/disable propagation, and reads `globalHotkey` when matching
//  events.
//

import Foundation
import SwiftUI
import Combine

@MainActor
final class HotKeySettings: ObservableObject {

    @Published var globalHotkeyEnabled: Bool {
        didSet {
            UserDefaults.standard.set(globalHotkeyEnabled, forKey: SettingsKeys.globalHotkeyEnabled)
        }
    }

    @Published var globalHotkey: HotKey {
        didSet {
            if let encoded = try? JSONEncoder().encode(globalHotkey) {
                UserDefaults.standard.set(encoded, forKey: SettingsKeys.globalHotkey)
            }
        }
    }

    init() {
        self.globalHotkeyEnabled = UserDefaults.standard.object(forKey: SettingsKeys.globalHotkeyEnabled) as? Bool ?? true

        if let data = UserDefaults.standard.data(forKey: SettingsKeys.globalHotkey),
           let decoded = try? JSONDecoder().decode(HotKey.self, from: data) {
            self.globalHotkey = decoded
        } else {
            self.globalHotkey = .defaultCapture
        }
    }
}
