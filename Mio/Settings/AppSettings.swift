//
//  AppSettings.swift
//  Mio
//
//  Aggregate root for all user preferences. Holds three theme-scoped
//  sub-stores under `Settings/`:
//
//    - appearance — launch-at-login
//    - hotkey     — global capture hotkey
//    - capture    — save destination, sound, security-scoped bookmark
//
//  Each sub-store is an independent `@MainActor ObservableObject`.
//  SwiftUI views inject only the relevant sub-store via
//  `@EnvironmentObject` for fine-grained redraws — `AppSettings`
//  itself is not an `ObservableObject` because it owns no observable
//  fields of its own.
//
//  Cross-store boundaries:
//    - The on-disk filename sequence counter lives in `FileOutputService`
//      (UserDefaults key `screenshotSequence`).
//    - The security-scoped save-folder bookmark lives in `CaptureSettings`
//      because it pairs with `saveFolderPath`.
//

import Foundation

@MainActor
final class AppSettings {
    static let shared = AppSettings()

    let appearance: AppearanceSettings
    let hotkey: HotKeySettings
    let capture: CaptureSettings

    private init() {
        self.appearance = AppearanceSettings()
        self.hotkey = HotKeySettings()
        self.capture = CaptureSettings()
    }
}
