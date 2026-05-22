//
//  AppLanguage.swift
//  Mio
//
//  Application language selection used by AppSettings and the
//  SwiftUI settings UI. Includes the Antarctic easter-egg sound
//  trigger because the resource ships in `aq.lproj/` and is
//  conceptually owned by this enum.
//

import Foundation
import AppKit

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system = "system"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case classicalChinese = "lzh"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"
    case german = "de"
    case french = "fr"
    case spanish = "es"
    case dutch = "nl"
    case antarctic = "aq"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:
            return NSLocalizedString("settings.general.language.system", value: "跟随系统", comment: "")
        case .simplifiedChinese:
            return NSLocalizedString("settings.general.language.zh_hans", value: "简体中文", comment: "")
        case .traditionalChinese:
            return NSLocalizedString("settings.general.language.zh_hant", value: "繁體中文", comment: "")
        case .classicalChinese:
            return NSLocalizedString("settings.general.language.classical_chinese", value: "文言文", comment: "")
        case .english:
            return NSLocalizedString("settings.general.language.english", value: "English", comment: "")
        case .japanese:
            return NSLocalizedString("settings.general.language.japanese", value: "日本語", comment: "")
        case .korean:
            return NSLocalizedString("settings.general.language.korean", value: "한국어", comment: "")
        case .german:
            return NSLocalizedString("settings.general.language.german", value: "Deutsch", comment: "")
        case .french:
            return NSLocalizedString("settings.general.language.french", value: "Français", comment: "")
        case .spanish:
            return NSLocalizedString("settings.general.language.spanish", value: "Español", comment: "")
        case .dutch:
            return NSLocalizedString("settings.general.language.dutch", value: "Nederlands", comment: "")
        case .antarctic:
            return NSLocalizedString("settings.general.language.antarctic", value: "南极语", comment: "")
        }
    }

    var localeIdentifier: String? {
        switch self {
        case .system:
            return nil
        default:
            return rawValue
        }
    }

    /// Plays the antarctic-language easter-egg chirp. The resource ships in
    /// `aq.lproj/` and is loaded via `Bundle.main.url(...)`. Marked
    /// `@MainActor` because `NSSound` is documented main-thread affine.
    @MainActor
    static func playAntarcticChirp() {
        guard let url = Bundle.main.url(
            forResource: "gugugaga🐧🐧🐧",
            withExtension: "m4a",
            subdirectory: "aq.lproj"
        ) else {
            return
        }

        guard let sound = NSSound(contentsOf: url, byReference: true) else {
            return
        }

        sound.volume = 0.3 // Respect system output; still obeys mute/system volume.
        sound.play()
    }
}
