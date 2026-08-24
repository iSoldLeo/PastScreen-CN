//
//  CaptureSettings.swift
//  Mio
//
//  Module 10's only owner for ordinary capture preferences. Folder
//  authorization is intentionally owned by SaveFolderAccess instead.
//

import Combine
import Foundation
import OSLog

/// 画框输出主题。`.auto` 保持语义值，直到真正构造最终渲染请求时才解析。
nonisolated enum CaptureFrameTheme: String, Codable, CaseIterable, Sendable, Identifiable {
    case auto
    case alwaysLight
    case alwaysDark

    var id: String { rawValue }

    var localizedLabel: String {
        switch self {
        case .auto:        return NSLocalizedString("settings.frame.theme.auto", comment: "")
        case .alwaysLight: return NSLocalizedString("settings.frame.theme.alwaysLight", comment: "")
        case .alwaysDark:  return NSLocalizedString("settings.frame.theme.alwaysDark", comment: "")
        }
    }
}

nonisolated struct CaptureFramePreference: Sendable, Equatable {
    let isEnabled: Bool
    let signature: String
    let theme: CaptureFrameTheme
}

/// Frozen once when a capture command is accepted. Folder authorization is
/// deliberately absent: every file operation resolves the current bookmark.
nonisolated struct CapturePreferencesSnapshot: Sendable, Equatable {
    let playSoundOnCapture: Bool
    let saveToFile: Bool
    let organizeByMonth: Bool
    let frame: CaptureFramePreference
}

@MainActor
final class CaptureSettings: ObservableObject {
    private enum Keys {
        static let playSoundOnCapture = "playSoundOnCapture"
        static let saveToFile = "saveToFile"
        static let organizeByMonth = "organizeByMonth"
        static let captureFrameEnabled = "captureFrameEnabled"
        static let captureFrameCustomText = "captureFrameCustomText"
        static let captureFrameTheme = "captureFrameTheme"
    }

    private static let signatureLimit = 40
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.iSoldLeo.Mio",
        category: "Settings.Capture"
    )
    private let defaults: UserDefaults

    @Published var playSoundOnCapture: Bool {
        didSet {
            persistIfChanged(
                playSoundOnCapture,
                oldValue: oldValue,
                key: Keys.playSoundOnCapture,
                field: "play_sound"
            )
        }
    }

    @Published var saveToFile: Bool {
        didSet { persistIfChanged(saveToFile, oldValue: oldValue, key: Keys.saveToFile, field: "save_to_file") }
    }

    @Published var organizeByMonth: Bool {
        didSet { persistIfChanged(organizeByMonth, oldValue: oldValue, key: Keys.organizeByMonth, field: "organize_by_month") }
    }

    @Published var captureFrameEnabled: Bool {
        didSet { persistIfChanged(captureFrameEnabled, oldValue: oldValue, key: Keys.captureFrameEnabled, field: "frame_enabled") }
    }

    @Published private(set) var captureFrameCustomText: String

    @Published var captureFrameTheme: CaptureFrameTheme {
        didSet {
            guard captureFrameTheme != oldValue else { return }
            defaults.set(captureFrameTheme.rawValue, forKey: Keys.captureFrameTheme)
            logChange(field: "frame_theme")
        }
    }

    init(defaults: UserDefaults) {
        let startedAt = ContinuousClock().now
        self.defaults = defaults
        self.playSoundOnCapture = defaults.object(forKey: Keys.playSoundOnCapture) as? Bool ?? true
        self.saveToFile = defaults.object(forKey: Keys.saveToFile) as? Bool ?? true
        self.organizeByMonth = defaults.object(forKey: Keys.organizeByMonth) as? Bool ?? false
        self.captureFrameEnabled = defaults.object(forKey: Keys.captureFrameEnabled) as? Bool ?? false

        let storedSignature = defaults.string(forKey: Keys.captureFrameCustomText) ?? ""
        self.captureFrameCustomText = Self.canonicalSignature(storedSignature)

        let storedTheme = defaults.string(forKey: Keys.captureFrameTheme)
        self.captureFrameTheme = storedTheme.flatMap(CaptureFrameTheme.init(rawValue:)) ?? .auto
        // Load-time canonicalization is intentionally in-memory only. Unknown
        // historical raw values and overlong text are not overwritten until a
        // real user mutation occurs.
        let correctedTheme = storedTheme.map { CaptureFrameTheme(rawValue: $0) == nil } ?? false
        let correctedFieldCount = (storedSignature.count > Self.signatureLimit ? 1 : 0)
            + (correctedTheme ? 1 : 0)
        Self.logger.info(
            "event=settings.capture.loaded corrected_field_count=\(correctedFieldCount, privacy: .public) duration_ms=\(Self.durationMilliseconds(since: startedAt), privacy: .public)"
        )
    }

    func snapshot() -> CapturePreferencesSnapshot {
        CapturePreferencesSnapshot(
            playSoundOnCapture: playSoundOnCapture,
            saveToFile: saveToFile,
            organizeByMonth: organizeByMonth,
            frame: CaptureFramePreference(
                isEnabled: captureFrameEnabled,
                signature: Self.canonicalSignature(captureFrameCustomText),
                theme: captureFrameTheme
            )
        )
    }

    func setCaptureFrameCustomText(_ value: String) {
        let canonical = Self.canonicalSignature(value)
        guard canonical != captureFrameCustomText else { return }
        captureFrameCustomText = canonical
        defaults.set(canonical, forKey: Keys.captureFrameCustomText)
        logChange(field: "frame_signature")
    }

    private func persistIfChanged(_ value: Bool, oldValue: Bool, key: String, field: StaticString) {
        guard value != oldValue else { return }
        defaults.set(value, forKey: key)
        logChange(field: field)
    }

    private static func canonicalSignature(_ value: String) -> String {
        String(value.prefix(signatureLimit))
    }

    private func logChange(field: StaticString) {
        Self.logger.info(
            "event=settings.capture.changed field=\(field, privacy: .public) result=persisted"
        )
    }

    private static func durationMilliseconds(since start: ContinuousClock.Instant) -> Int64 {
        let components = start.duration(to: ContinuousClock().now).components
        return components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
    }
}
