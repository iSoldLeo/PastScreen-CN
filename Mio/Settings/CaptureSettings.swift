//
//  CaptureSettings.swift
//  Mio
//
//  Capture-pipeline-scoped settings: where to save, whether to play the
//  camera shutter sound. Owns the security-scoped bookmark store because
//  the bookmark is bound to `saveFolderPath` semantically.
//

import Foundation
import SwiftUI
import Combine

/// 画框输出主题（capture-frame-spec.md v2.1 §4.3）。
///
/// `.auto` 在渲染时（CaptureCoordinator）解析为 `.light` 或 `.dark`——
/// 读 NSAppearance 是 main-actor 操作，不能在 nonisolated FrameRenderer 里做。
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

@MainActor
final class CaptureSettings: ObservableObject {

    /// Owns the security-scoped bookmark for the save folder and the
    /// NSOpenPanel modal. CaptureSettings persists the folder *path*; the
    /// store persists the *access grant*.
    private let bookmarkStore = SaveFolderBookmarkStore()

    @Published var saveFolderPath: String {
        didSet {
            UserDefaults.standard.set(saveFolderPath, forKey: SettingsKeys.saveFolderPath)
            ensureFolderExists()
        }
    }

    @Published var playSoundOnCapture: Bool {
        didSet {
            UserDefaults.standard.set(playSoundOnCapture, forKey: SettingsKeys.playSoundOnCapture)
        }
    }

    /// When false, captures are copied to the clipboard only and never
    /// written to disk — useful for "throwaway" screenshots aimed at AI
    /// chat / messaging where the file would be deleted right after.
    /// Defaults to `true` so existing users see no behavioural change
    /// after this setting is reintroduced.
    @Published var saveToFile: Bool {
        didSet {
            UserDefaults.standard.set(saveToFile, forKey: SettingsKeys.saveToFile)
        }
    }

    // MARK: - 画框输出（v6 新增，spec capture-frame-spec.md v2.1）

    /// 是否给窗口截图（路径 A 直出 / 路径 D 编辑器 finish）套画框。默认 false。
    /// onboarding 完成后引导首次开启。
    @Published var captureFrameEnabled: Bool {
        didSet {
            UserDefaults.standard.set(captureFrameEnabled, forKey: SettingsKeys.captureFrameEnabled)
        }
    }

    /// 用户自定义签名（footer 右下显示）。空字符串则不显示。最多 40 字符，
    /// 超出由 FrameRenderer 自动截断 + 省略号。
    @Published var captureFrameCustomText: String {
        didSet {
            UserDefaults.standard.set(captureFrameCustomText, forKey: SettingsKeys.captureFrameCustomText)
        }
    }

    /// 画框主题。.auto = 跟随系统外观（渲染时绑定，与接收方设备无关）。
    @Published var captureFrameTheme: CaptureFrameTheme {
        didSet {
            UserDefaults.standard.set(captureFrameTheme.rawValue, forKey: SettingsKeys.captureFrameTheme)
        }
    }

    var hasValidBookmark: Bool { bookmarkStore.hasValidBookmark }

    /// True when both a folder path and a valid security-scoped bookmark are
    /// available (App Store compliance — Apple guideline 2.4.5(i)).
    var hasValidSaveFolder: Bool {
        !saveFolderPath.isEmpty && hasValidBookmark
    }

    init() {
        // No default path - user MUST select a folder via NSOpenPanel
        // This complies with Apple guideline 2.4.5(i) - user-accessible storage
        self.saveFolderPath = UserDefaults.standard.string(forKey: SettingsKeys.saveFolderPath) ?? ""

        self.playSoundOnCapture = UserDefaults.standard.object(forKey: SettingsKeys.playSoundOnCapture) as? Bool ?? true
        self.saveToFile = UserDefaults.standard.object(forKey: SettingsKeys.saveToFile) as? Bool ?? true

        self.captureFrameEnabled = UserDefaults.standard.object(forKey: SettingsKeys.captureFrameEnabled) as? Bool ?? false
        self.captureFrameCustomText = UserDefaults.standard.string(forKey: SettingsKeys.captureFrameCustomText) ?? ""
        let storedTheme = UserDefaults.standard.string(forKey: SettingsKeys.captureFrameTheme)
            ?? CaptureFrameTheme.auto.rawValue
        self.captureFrameTheme = CaptureFrameTheme(rawValue: storedTheme) ?? .auto

        // Restore the security-scoped bookmark off the main actor, then
        // re-create the configured folder once access is armed. The
        // detached task lives inside `bookmarkStore.restoreFolderAccess()`;
        // we await its result here on the main actor to chain
        // `ensureFolderExists`.
        //
        // Known limitation: this task is fire-and-forget — the first
        // capture can still race with bookmark resolution if it triggers
        // before this completes. File output silently fails in that
        // window. Functional fix is out of scope for the settings layer.
        Task { [bookmarkStore] in
            await bookmarkStore.restoreFolderAccess()
            self.ensureFolderExists()
        }
    }

    /// Opens NSOpenPanel; returns the chosen path with a trailing slash
    /// (caller is expected to assign to `saveFolderPath`).
    func selectFolder() -> String? {
        bookmarkStore.selectFolder()
    }

    private func ensureFolderExists() {
        bookmarkStore.ensureFolderExists(at: saveFolderPath)
    }
}
