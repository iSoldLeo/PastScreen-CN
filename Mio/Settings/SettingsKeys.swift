//
//  SettingsKeys.swift
//  Mio
//
//  Single source of truth for all UserDefaults key strings used by the
//  settings sub-stores, the security-scoped bookmark store, and the
//  file output sequence counter.
//
//  Compile-time spelling protection: typos no longer silently lose
//  user configuration on the next app launch.
//

import Foundation

nonisolated enum SettingsKeys {
    /// AppearanceSettings → renamed to GeneralSettings in this batch.
    static let launchAtLogin = "launchAtLogin"

    /// HotKeySettings.
    static let globalHotkeyEnabled = "globalHotkeyEnabled"
    static let globalHotkey = "globalHotkey"

    /// CaptureSettings.
    static let saveFolderPath = "saveFolderPath"
    static let playSoundOnCapture = "playSoundOnCapture"
    static let saveToFile = "saveToFile"

    /// SaveFolderBookmarkStore (paired with `saveFolderPath`).
    static let saveFolderBookmark = "saveFolderBookmark"

    /// FileOutputService inside Capture.swift — owns the on-disk
    /// filename counter, not a user preference.
    static let screenshotSequence = "screenshotSequence"
}
