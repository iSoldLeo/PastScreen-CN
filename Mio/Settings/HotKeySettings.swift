//
//  HotKeySettings.swift
//  Mio
//
//  Hotkey-scoped settings: two independent global hotkeys for window
//  capture and full-screen capture. Each hotkey can be in an "unset"
//  state (HotKey.isUnset) which disables matching for that hotkey only.
//
//  HotKeyManager subscribes to both `$windowCaptureHotkey` and
//  `$fullScreenHotkey`, reinstalling its monitors when either changes.
//
//  Migration (one-shot, on init):
//    legacy `globalHotkey`         → `windowCaptureHotkey`
//    legacy `globalHotkeyEnabled`  → discarded (per-hotkey unset replaces it)
//

import Foundation
import SwiftUI
import Combine

@MainActor
final class HotKeySettings: ObservableObject {

    @Published var windowCaptureHotkey: HotKey {
        didSet {
            persist(windowCaptureHotkey, forKey: SettingsKeys.windowCaptureHotkey)
        }
    }

    @Published var advancedWindowCaptureHotkey: HotKey {
        didSet {
            persist(advancedWindowCaptureHotkey, forKey: SettingsKeys.advancedWindowCaptureHotkey)
        }
    }

    @Published var fullScreenHotkey: HotKey {
        didSet {
            persist(fullScreenHotkey, forKey: SettingsKeys.fullScreenHotkey)
        }
    }

    init() {
        // Migration from single-hotkey schema to two-hotkey schema.
        // Runs at most once per legacy install; the legacy keys are
        // removed afterwards so subsequent launches go straight to the
        // new keys. The decode probe before transferring the data
        // prevents corrupt JSON (cross-version schema drift / crash
        // residue) from being silently re-pickled into the new key —
        // a corrupt blob would otherwise persist forever and only
        // surface when the user manually reassigns the shortcut.
        let defaults = UserDefaults.standard
        if let legacyData = defaults.data(forKey: SettingsKeys.legacyGlobalHotkey),
           defaults.data(forKey: SettingsKeys.windowCaptureHotkey) == nil,
           (try? JSONDecoder().decode(HotKey.self, from: legacyData)) != nil {
            defaults.set(legacyData, forKey: SettingsKeys.windowCaptureHotkey)
        }
        // Always purge legacy keys, even on cross-version rollback when
        // the new key already exists or the legacy data is corrupt.
        defaults.removeObject(forKey: SettingsKeys.legacyGlobalHotkey)
        defaults.removeObject(forKey: SettingsKeys.legacyGlobalHotkeyEnabled)

        self.windowCaptureHotkey = Self.load(forKey: SettingsKeys.windowCaptureHotkey)
            ?? .defaultWindowCapture
        self.advancedWindowCaptureHotkey = Self.load(forKey: SettingsKeys.advancedWindowCaptureHotkey)
            ?? .defaultAdvancedWindow
        self.fullScreenHotkey = Self.load(forKey: SettingsKeys.fullScreenHotkey)
            ?? .defaultFullScreen
    }

    // MARK: - Private

    private func persist(_ hotkey: HotKey, forKey key: String) {
        if let encoded = try? JSONEncoder().encode(hotkey) {
            UserDefaults.standard.set(encoded, forKey: key)
        }
    }

    private static func load(forKey key: String) -> HotKey? {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return nil
        }
        return try? JSONDecoder().decode(HotKey.self, from: data)
    }
}
