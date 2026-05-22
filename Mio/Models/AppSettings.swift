//
//  AppSettings.swift
//  Mio
//
//  Aggregate root for all user preferences. After Phase 6A all settings
//  fields live in theme-scoped sub-stores under `Settings/`:
//
//    - AppSettings.shared.appearance — language, Dock, launch-at-login
//    - AppSettings.shared.hotkey     — global capture hotkey
//    - AppSettings.shared.ui         — window border, frozen-window limit
//    - AppSettings.shared.capture    — save destination, image format,
//                                       clipboard format, sound, bookmark
//
//  Each sub-store is an independent `@MainActor ObservableObject`. SwiftUI
//  views inject only the relevant sub-store via `@EnvironmentObject` for
//  fine-grained redraws — `AppSettings` itself is no longer an
//  `ObservableObject` because it owns no observable fields of its own.
//
//  Cross-store concerns:
//    - The on-disk filename sequence counter lives in `FileOutputService`
//      (Phase 5). UserDefaults key `"screenshotSequence"` is preserved.
//    - The security-scoped save-folder bookmark belongs to
//      `CaptureSettings` (Phase 6A.4) because it pairs with `saveFolderPath`.
//

import Foundation

@MainActor
final class AppSettings {
    static let shared = AppSettings()

    // Theme-scoped sub-stores (Phase 6A). Each is an independent
    // @MainActor ObservableObject; SwiftUI views inject the relevant one
    // directly via @EnvironmentObject for fine-grained redraws.
    let appearance: AppearanceSettings
    let hotkey: HotKeySettings
    let ui: UISettings
    let capture: CaptureSettings

    private init() {
        // Sub-stores load their own state from UserDefaults during init.
        self.appearance = AppearanceSettings()
        self.hotkey = HotKeySettings()
        self.ui = UISettings()
        self.capture = CaptureSettings()
    }
}
