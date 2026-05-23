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
