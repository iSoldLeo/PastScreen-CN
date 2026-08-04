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
    static let windowCaptureHotkey = "windowCaptureHotkey"
    static let advancedWindowCaptureHotkey = "advancedWindowCaptureHotkey"
    static let fullScreenHotkey = "fullScreenHotkey"

    /// Legacy key — present in pre-2 hotkey users' UserDefaults. Migrated
    /// to `windowCaptureHotkey` on first launch and then removed.
    static let legacyGlobalHotkey = "globalHotkey"
    /// Legacy key — present in pre-2 hotkey users' UserDefaults. Removed
    /// on first launch (replaced by per-hotkey "unset" state).
    static let legacyGlobalHotkeyEnabled = "globalHotkeyEnabled"

    /// CaptureSettings.
    static let saveFolderPath = "saveFolderPath"
    static let playSoundOnCapture = "playSoundOnCapture"
    static let saveToFile = "saveToFile"
    /// 按年月归档：写盘时落到 `<saveFolder>/YYYY/MM/` 而不是根目录。
    static let organizeByMonth = "organizeByMonth"

    /// CaptureSettings — 画框输出（capture-frame-spec.md v2.1）
    static let captureFrameEnabled = "captureFrameEnabled"
    static let captureFrameCustomText = "captureFrameCustomText"
    static let captureFrameTheme = "captureFrameTheme"

    /// SaveFolderBookmarkStore (paired with `saveFolderPath`).
    static let saveFolderBookmark = "saveFolderBookmark"

    /// FileOutputService inside Capture.swift — owns the on-disk
    /// filename counter, not a user preference.
    static let screenshotSequence = "screenshotSequence"
}
