//
//  OCRLanguageOption.swift
//  PastScreen
//
//  Recommended OCR languages (BCP-47) for Vision text recognition.
//

import Foundation

struct OCRLanguageOption: Identifiable, Hashable {
    let code: String

    var id: String { code }

    var displayName: String {
        Locale.current.localizedString(forIdentifier: code) ?? code
    }

    static let recommended: [OCRLanguageOption] = [
        OCRLanguageOption(code: "en-US"),
        OCRLanguageOption(code: "zh-Hans"),
        OCRLanguageOption(code: "zh-Hant"),
        OCRLanguageOption(code: "ja-JP"),
        OCRLanguageOption(code: "ko-KR"),
        OCRLanguageOption(code: "fr-FR"),
        OCRLanguageOption(code: "de-DE"),
        OCRLanguageOption(code: "es-ES"),
        OCRLanguageOption(code: "pt-BR"),
        OCRLanguageOption(code: "it-IT"),
        OCRLanguageOption(code: "ru-RU"),
    ]
}

