//
//  CaptureSettings.swift
//  Mio
//
//  Capture-pipeline-scoped settings: where to save, what format,
//  what to copy to the clipboard, whether to play the camera shutter
//  sound. Owns the security-scoped bookmark store because the bookmark
//  is bound to `saveFolderPath` semantically.
//
//  Phase 6A theme split: aggregated under `AppSettings.shared.capture`.
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

    @Published var saveToFile: Bool {
        didSet {
            UserDefaults.standard.set(saveToFile, forKey: "saveToFile")
        }
    }

    @Published var saveFolderPath: String {
        didSet {
            UserDefaults.standard.set(saveFolderPath, forKey: "saveFolderPath")
            ensureFolderExists()
        }
    }

    @Published var imageFormat: ImageFormat {
        didSet {
            UserDefaults.standard.set(imageFormat.rawValue, forKey: "imageFormat")
        }
    }

    @Published var playSoundOnCapture: Bool {
        didSet {
            UserDefaults.standard.set(playSoundOnCapture, forKey: "playSoundOnCapture")
        }
    }

    @Published var captureClipboardFormat: CaptureClipboardFormat {
        didSet {
            UserDefaults.standard.set(captureClipboardFormat.rawValue, forKey: "captureClipboardFormat")
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
        self.saveFolderPath = UserDefaults.standard.string(forKey: "saveFolderPath") ?? ""

        self.saveToFile = UserDefaults.standard.object(forKey: "saveToFile") as? Bool ?? true  // Default: enabled
        self.imageFormat = ImageFormat.fromLegacyString(UserDefaults.standard.string(forKey: "imageFormat")) ?? .png
        self.playSoundOnCapture = UserDefaults.standard.object(forKey: "playSoundOnCapture") as? Bool ?? true

        if let raw = UserDefaults.standard.string(forKey: "captureClipboardFormat"),
           let format = CaptureClipboardFormat(rawValue: raw) {
            self.captureClipboardFormat = format
        } else {
            self.captureClipboardFormat = .image
        }

        // Restore the security-scoped bookmark off the main actor, then
        // re-create the configured folder once access is armed. This
        // unblocks cold launch — `URL(resolvingBookmarkData:)` performs
        // synchronous I/O that previously executed in `init` on the main
        // actor.
        //
        // Owner: CaptureSettings (held by AppSettings.shared, process-lifetime).
        // Priority: utility (inherits from BookmarkResolution.resolve).
        // Cancellation: not propagated; folder access must be re-armed
        // before the first capture lands, otherwise file output silently
        // fails. Process-lifetime singleton means the task always runs to
        // completion or is terminated with the app.
        Task { @MainActor [bookmarkStore] in
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
