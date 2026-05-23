//
//  SaveFolderBookmarkStore.swift
//  Mio
//
//  Owns the security-scoped bookmark for the user-selected save
//  folder, the modal NSOpenPanel, and the folder-creation helper.
//  Localises the App Store sandbox surface area (Apple guideline
//  2.4.5(i)) into one place so other settings stores don't need to
//  know about security-scoped resources.
//
//  Bookmark resolution and `startAccessingSecurityScopedResource`
//  perform synchronous I/O and must operate on the same URL (only
//  the resolved security-scoped URL carries the sandbox extension
//  token). To avoid blocking init on the main actor, the public
//  restore entry point is async and runs both calls inside a single
//  detached utility-priority task; the URL never crosses an actor
//  boundary.
//

import Foundation
import AppKit

@MainActor
final class SaveFolderBookmarkStore {

    /// The path component that AppSettings persists. The store does not
    /// own the path itself (AppSettings drives `@Published var saveFolderPath`),
    /// only the bookmark blob and the modal/IO flow.
    private var saveFolderBookmark: Data? {
        get { UserDefaults.standard.data(forKey: SettingsKeys.saveFolderBookmark) }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.saveFolderBookmark) }
    }

    var hasValidBookmark: Bool { saveFolderBookmark != nil }

    /// Resolves the persisted bookmark and re-arms the security-scoped
    /// access if any. Silent on failure so a missing bookmark is not fatal.
    ///
    /// Both the bookmark resolution and `startAccessingSecurityScopedResource`
    /// must be performed against the same URL — the latter only works on a
    /// URL produced by `URL(resolvingBookmarkData:.withSecurityScope)`. We
    /// therefore run both calls inside one detached utility-priority task
    /// and return only a Sendable summary. Once `startAccessing` succeeds
    /// the sandbox extension is consumed at the process level, so subsequent
    /// file IO from any actor against that path works without further setup.
    func restoreFolderAccess() async {
        guard let bookmarkData = saveFolderBookmark else { return }

        // SAFETY: `bookmarkData` is Foundation.Data (value-type Sendable).
        // The detached task captures only Sendable values and returns a
        // Sendable summary (`BookmarkResolution`). The non-Sendable URL
        // never crosses the actor boundary; it lives only inside the task
        // long enough to call `startAccessingSecurityScopedResource()`.
        _ = await Task.detached(priority: .utility) {
            BookmarkResolution.resolveAndStartAccessing(bookmarkData: bookmarkData)
        }.value
    }

    /// Best-effort creation of the configured folder. Sandbox can prevent
    /// success when the bookmark has not been re-armed yet.
    func ensureFolderExists(at saveFolderPath: String) {
        let fileManager = FileManager.default
        // For Sandbox, we rely on restoreFolderAccess(). Creating directory might fail if permission is lost.
        if !fileManager.fileExists(atPath: saveFolderPath) {
            // Only try to create if it's the temp directory or we have permission
            try? fileManager.createDirectory(
                atPath: saveFolderPath,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }
    }

    /// Opens an NSOpenPanel for folder selection and stores the resulting
    /// security-scoped bookmark. Returns the selected path with a trailing
    /// slash, mirroring the previous behaviour of `AppSettings.selectFolder`.
    func selectFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = NSLocalizedString("settings.select_folder.prompt", comment: "")
        panel.message = NSLocalizedString("settings.select_folder.message", comment: "")

        if panel.runModal() == .OK {
            if let url = panel.url {
                // Create security scoped bookmark
                do {
                    let bookmarkData = try url.bookmarkData(
                        options: .withSecurityScope,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                    self.saveFolderBookmark = bookmarkData
                    startAccessing(url: url)
                } catch {
                    // Bookmark creation failed silently
                }

                return url.path + "/"
            }
        }
        return nil
    }

    private func startAccessing(url: URL) {
        _ = url.startAccessingSecurityScopedResource()
    }
}

/// Sendable result of resolving a security-scoped bookmark off-main.
private struct BookmarkResolution: Sendable {
    let isStale: Bool
    let didStartAccessing: Bool

    /// Resolves a bookmark blob *and* starts security-scoped access against
    /// the same URL — the only URL on which `startAccessingSecurityScopedResource`
    /// is documented to work. Returns a Sendable summary, or nil on failure.
    ///
    /// Once the call returns the sandbox extension is consumed at the
    /// process level, so any later file IO targeting the bookmarked path
    /// will succeed regardless of which actor performs it.
    nonisolated static func resolveAndStartAccessing(bookmarkData: Data) -> BookmarkResolution? {
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            let didStart = url.startAccessingSecurityScopedResource()
            return BookmarkResolution(isStale: isStale, didStartAccessing: didStart)
        } catch {
            return nil
        }
    }
}
