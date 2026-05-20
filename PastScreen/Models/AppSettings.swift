//
//  AppSettings.swift
//  PastScreen
//
//  Settings management with UserDefaults persistence
//

import Foundation
import SwiftUI
import Combine

enum ClipboardFormat: String, Codable, CaseIterable, Identifiable {
    case auto = "Auto"
    case image = "Image"
    case path = "Path (Text)"

    var id: String { rawValue }
}

struct AppOverride: Codable, Identifiable, Equatable {
    var id: String { bundleIdentifier }
    let bundleIdentifier: String
    var appName: String
    var format: ClipboardFormat
}

class AppSettings: ObservableObject {
    static let shared = AppSettings()

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

    @Published var imageFormat: String {
        didSet {
            UserDefaults.standard.set(imageFormat, forKey: "imageFormat")
        }
    }

    @Published var playSoundOnCapture: Bool {
        didSet {
            UserDefaults.standard.set(playSoundOnCapture, forKey: "playSoundOnCapture")
        }
    }

    @Published var globalHotkeyEnabled: Bool {
        didSet {
            UserDefaults.standard.set(globalHotkeyEnabled, forKey: "globalHotkeyEnabled")
        }
    }

    @Published var showInDock: Bool {
        didSet {
            UserDefaults.standard.set(showInDock, forKey: "showInDock")
            // Post notification to update activation policy
            NotificationCenter.default.post(name: .showInDockChanged, object: nil)
        }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
            LaunchAtLoginManager.shared.setEnabled(launchAtLogin)
        }
    }

    @Published var captureHistory: [String] {
        didSet {
            UserDefaults.standard.set(captureHistory, forKey: "captureHistory")
        }
    }

    @Published var screenshotSequence: Int {
        didSet {
            UserDefaults.standard.set(screenshotSequence, forKey: "screenshotSequence")
        }
    }

    // Security Scoped Bookmark for Sandbox access
    @Published var appOverrides: [AppOverride] {
        didSet {
            if let encoded = try? JSONEncoder().encode(appOverrides) {
                UserDefaults.standard.set(encoded, forKey: "appOverrides")
            }
        }
    }

    // Security Scoped Bookmark for Sandbox access
    private var saveFolderBookmark: Data? {
        get { UserDefaults.standard.data(forKey: "saveFolderBookmark") }
        set { UserDefaults.standard.set(newValue, forKey: "saveFolderBookmark") }
    }

    var hasValidBookmark: Bool {
        return saveFolderBookmark != nil
    }

    /// Check if a valid save folder is configured (requires user selection with bookmark)
    var hasValidSaveFolder: Bool {
        // Requires user-selected folder with valid bookmark (App Store compliance)
        return !saveFolderPath.isEmpty && hasValidBookmark
    }

    private init() {
        // Load saved values or use defaults
        self.saveToFile = UserDefaults.standard.object(forKey: "saveToFile") as? Bool ?? true  // Changed default to true

        // No default path - user MUST select a folder via NSOpenPanel
        // This complies with Apple guideline 2.4.5(i) - user-accessible storage
        let defaultPath = ""  // Empty = forces folder selection
        self.saveFolderPath = UserDefaults.standard.string(forKey: "saveFolderPath") ?? defaultPath

        self.imageFormat = UserDefaults.standard.string(forKey: "imageFormat") ?? "png"
        self.playSoundOnCapture = UserDefaults.standard.object(forKey: "playSoundOnCapture") as? Bool ?? true
        self.globalHotkeyEnabled = UserDefaults.standard.object(forKey: "globalHotkeyEnabled") as? Bool ?? true
        self.showInDock = UserDefaults.standard.object(forKey: "showInDock") as? Bool ?? true
        self.launchAtLogin = UserDefaults.standard.object(forKey: "launchAtLogin") as? Bool ?? false  // Default: disabled

        self.captureHistory = UserDefaults.standard.stringArray(forKey: "captureHistory") ?? []

        let seq = UserDefaults.standard.integer(forKey: "screenshotSequence")
        self.screenshotSequence = seq > 0 ? seq : 1

        if let data = UserDefaults.standard.data(forKey: "appOverrides"),
           let decoded = try? JSONDecoder().decode([AppOverride].self, from: data) {
            self.appOverrides = decoded
        } else {
            self.appOverrides = []
        }

        restoreFolderAccess()
        ensureFolderExists()
    }

    func ensureFolderExists() {
        let fileManager = FileManager.default
        // For Sandbox, we rely on restoreFolderAccess(). Creating directory might fail if permission is lost.
        if !fileManager.fileExists(atPath: saveFolderPath) {
            // Only try to create if it's the temp directory or we have permission
            try? fileManager.createDirectory(atPath: saveFolderPath, withIntermediateDirectories: true, attributes: nil)
        }
    }

    func selectFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Please select a folder to save screenshots"

        if panel.runModal() == .OK {
            if let url = panel.url {
                // Create security scoped bookmark
                do {
                    let bookmarkData = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
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

    private func restoreFolderAccess() {
        guard let bookmarkData = saveFolderBookmark else { return }

        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)

            if isStale {
                // Bookmark is stale, may need to recreate
            }

            startAccessing(url: url)
        } catch {
            // Failed to resolve bookmark
        }
    }

    private func startAccessing(url: URL) {
        _ = url.startAccessingSecurityScopedResource()
    }

    func clearSaveFolder() {
        let fileManager = FileManager.default
        guard let items = try? fileManager.contentsOfDirectory(atPath: saveFolderPath) else { return }

        for item in items {
            // SAFETY CHECK: Only delete files created by PastScreen
            // Matches pattern: Screenshot-YYYY-MM-dd... or Screen-N...
            if (item.hasPrefix("Screenshot-") || item.hasPrefix("Screen-")) && (item.hasSuffix(".png") || item.hasSuffix(".jpg")) {
                let itemPath = saveFolderPath + item
                try? fileManager.removeItem(atPath: itemPath)
            }
        }

        // Reset sequence
        screenshotSequence = 1
    }

    func addToHistory(_ path: String) {
        var currentHistory = captureHistory

        // Remove if exists to avoid duplicates (will be re-added at top)
        currentHistory.removeAll { $0 == path }

        // Add to top
        currentHistory.insert(path, at: 0)

        // Keep only last 10 items
        if currentHistory.count > 10 {
            currentHistory = Array(currentHistory.prefix(10))
        }

        captureHistory = currentHistory
    }

    func clearHistory() {
        captureHistory.removeAll()
    }

    func addAppOverride(_ override: AppOverride) {
        if let index = appOverrides.firstIndex(where: { $0.bundleIdentifier == override.bundleIdentifier }) {
            appOverrides[index] = override
        } else {
            appOverrides.append(override)
        }
    }

    func removeAppOverride(id: String) {
        appOverrides.removeAll { $0.id == id }
    }

    func getOverride(for bundleIdentifier: String) -> ClipboardFormat? {
        return appOverrides.first(where: { $0.bundleIdentifier == bundleIdentifier })?.format
    }
}
