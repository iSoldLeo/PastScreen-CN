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
            UserDefaults.standard.set(globalHotkeyEnabled, forKey: "globalHotkeyEnabled")
        }
    }

    @Published var globalHotkey: HotKey {
        didSet {
            if let encoded = try? JSONEncoder().encode(globalHotkey) {
                UserDefaults.standard.set(encoded, forKey: "globalHotkey")
            }
        }
    }

    init() {
        self.globalHotkeyEnabled = UserDefaults.standard.object(forKey: "globalHotkeyEnabled") as? Bool ?? true

        if let data = UserDefaults.standard.data(forKey: "globalHotkey"),
           let decoded = try? JSONDecoder().decode(HotKey.self, from: data) {
            self.globalHotkey = decoded
        } else {
            self.globalHotkey = .defaultCapture
        }
    }
}
