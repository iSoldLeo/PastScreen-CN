//
//  AppSettings.swift
//  PastScreen
//
//  Settings management with UserDefaults persistence
//

import Foundation
import SwiftUI
import Combine
import AppKit

struct HotKey: Codable, Equatable, Sendable {
    var keyCode: UInt16
    var modifiers: UInt
    var characters: String?

    static let supportedModifierMask: NSEvent.ModifierFlags = [.command, .option, .shift, .control]
    static let defaultCapture = HotKey(
        keyCode: 1,
        modifiers: NSEvent.ModifierFlags([.option, .command]).rawValue,
        characters: "s"
    )

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers).intersection(Self.supportedModifierMask)
    }

    var displayKey: String {
        Self.displayKey(for: keyCode, characters: characters)
    }

    var displayParts: [String] {
        var parts: [String] = []
        if modifierFlags.contains(.control) { parts.append("Ctrl") }
        if modifierFlags.contains(.option) { parts.append("Opt") }
        if modifierFlags.contains(.shift) { parts.append("Shift") }
        if modifierFlags.contains(.command) { parts.append("Cmd") }
        parts.append(displayKey)
        return parts
    }

    var displayString: String {
        displayParts.joined(separator: "+")
    }

    var keyEquivalent: String {
        guard let chars = characters, !chars.isEmpty else {
            return ""
        }
        return chars.lowercased()
    }

    static func normalizedModifiers(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection(Self.supportedModifierMask)
    }

    private static func displayKey(for keyCode: UInt16, characters: String?) -> String {
        if let special = specialKeyDisplay[keyCode] {
            return special
        }

        guard let chars = characters, !chars.isEmpty else {
            return String(format: NSLocalizedString("hotkey.key.code", comment: ""), keyCode)
        }

        if chars == " " {
            return NSLocalizedString("hotkey.key.space", comment: "")
        }

        return chars.uppercased()
    }

    private static let specialKeyDisplay: [UInt16: String] = [
        36: NSLocalizedString("hotkey.key.return", comment: ""),
        48: NSLocalizedString("hotkey.key.tab", comment: ""),
        49: NSLocalizedString("hotkey.key.space", comment: ""),
        51: NSLocalizedString("hotkey.key.delete", comment: ""),
        53: NSLocalizedString("hotkey.key.escape", comment: ""),
        117: NSLocalizedString("hotkey.key.forward_delete", comment: ""),
        115: NSLocalizedString("hotkey.key.home", comment: ""),
        119: NSLocalizedString("hotkey.key.end", comment: ""),
        116: NSLocalizedString("hotkey.key.page_up", comment: ""),
        121: NSLocalizedString("hotkey.key.page_down", comment: ""),
        123: NSLocalizedString("hotkey.key.left", comment: ""),
        124: NSLocalizedString("hotkey.key.right", comment: ""),
        125: NSLocalizedString("hotkey.key.down", comment: ""),
        126: NSLocalizedString("hotkey.key.up", comment: ""),
        122: "F1",
        120: "F2",
        99: "F3",
        118: "F4",
        96: "F5",
        97: "F6",
        98: "F7",
        100: "F8",
        101: "F9",
        109: "F10",
        103: "F11",
        111: "F12",
        105: "F13",
        107: "F14",
        113: "F15",
        106: "F16",
        64: "F17",
        79: "F18",
        80: "F19",
        90: "F20"
    ]
}

enum CaptureClipboardFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case image = "image"
    case path = "path"
    case markdownImage = "markdownImage"

    var id: String { rawValue }
}

public struct RGBAColor: Codable, Equatable, Sendable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    init(r: Double, g: Double, b: Double, a: Double) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(nsColor: NSColor) {
        let color = nsColor.usingColorSpace(.sRGB) ?? nsColor
        self.r = Double(color.redComponent)
        self.g = Double(color.greenComponent)
        self.b = Double(color.blueComponent)
        self.a = Double(color.alphaComponent)
    }

    init?(cgColor: CGColor) {
        guard let nsColor = NSColor(cgColor: cgColor)?.usingColorSpace(.sRGB) else { return nil }
        self.init(nsColor: nsColor)
    }

    var cgColor: CGColor? {
        NSColor(
            calibratedRed: CGFloat(r),
            green: CGFloat(g),
            blue: CGFloat(b),
            alpha: CGFloat(a)
        ).cgColor
    }

    var swiftUIColor: Color {
        Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

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
}

@MainActor
class AppSettings: ObservableObject {
    static let shared = AppSettings()
    // Defaults for window border (off-white with a hint of gray)
    private let defaultBorderColor = RGBAColor(r: 0.97, g: 0.97, b: 0.97, a: 1.0)
    private let defaultBorderWidth: Double = 10
    private let defaultBorderCornerRadius: Double = 22
    private var isInitialized = false

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

    @Published var windowBorderEnabled: Bool {
        didSet {
            UserDefaults.standard.set(windowBorderEnabled, forKey: "windowBorderEnabled")
        }
    }

    @Published var windowBorderWidth: Double {
        didSet {
            UserDefaults.standard.set(windowBorderWidth, forKey: "windowBorderWidth")
        }
    }

    @Published var windowBorderCornerRadius: Double {
        didSet {
            UserDefaults.standard.set(windowBorderCornerRadius, forKey: "windowBorderCornerRadius")
        }
    }

    @Published var windowBorderColor: RGBAColor {
        didSet {
            if let encoded = try? JSONEncoder().encode(windowBorderColor) {
                UserDefaults.standard.set(encoded, forKey: "windowBorderColor")
            }
        }
    }

    @Published var frozenWindowLimitPerDisplay: Int {
        didSet {
            let clamped = max(5, frozenWindowLimitPerDisplay)
            if clamped != frozenWindowLimitPerDisplay {
                frozenWindowLimitPerDisplay = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: "frozenWindowLimitPerDisplay")
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

    @Published var globalHotkeyEnabled: Bool {
        didSet {
            UserDefaults.standard.set(globalHotkeyEnabled, forKey: "globalHotkeyEnabled")
        }
    }

    @Published var globalHotkey: HotKey {
        didSet {
            if let encoded = try? JSONEncoder().encode(globalHotkey) {
                UserDefaults.standard.set(encoded, forKey: "globalHotkey")
            }
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

    @Published var appLanguage: AppLanguage {
        didSet {
            let previous = oldValue
            UserDefaults.standard.set(appLanguage.rawValue, forKey: "appLanguage")
            applyAppLanguage()
            if isInitialized,
               appLanguage == .antarctic,
               previous != .antarctic {
                playAntarcticChirp()
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
        self.windowBorderEnabled = UserDefaults.standard.object(forKey: "windowBorderEnabled") as? Bool ?? true
        self.windowBorderWidth = UserDefaults.standard.object(forKey: "windowBorderWidth") as? Double ?? defaultBorderWidth
        self.windowBorderCornerRadius = UserDefaults.standard.object(forKey: "windowBorderCornerRadius") as? Double ?? defaultBorderCornerRadius
        if let data = UserDefaults.standard.data(forKey: "windowBorderColor"),
           let decoded = try? JSONDecoder().decode(RGBAColor.self, from: data) {
            self.windowBorderColor = decoded
        } else {
            self.windowBorderColor = defaultBorderColor
        }
        let storedWindowLimit = UserDefaults.standard.integer(forKey: "frozenWindowLimitPerDisplay")
        if storedWindowLimit > 0 {
            self.frozenWindowLimitPerDisplay = max(5, storedWindowLimit)
        } else {
            self.frozenWindowLimitPerDisplay = 10
        }
        self.playSoundOnCapture = UserDefaults.standard.object(forKey: "playSoundOnCapture") as? Bool ?? true

        if let raw = UserDefaults.standard.string(forKey: "captureClipboardFormat"),
           let format = CaptureClipboardFormat(rawValue: raw) {
            self.captureClipboardFormat = format
        } else {
            self.captureClipboardFormat = .image
        }

        self.globalHotkeyEnabled = UserDefaults.standard.object(forKey: "globalHotkeyEnabled") as? Bool ?? true

        if let data = UserDefaults.standard.data(forKey: "globalHotkey"),
           let decoded = try? JSONDecoder().decode(HotKey.self, from: data) {
            self.globalHotkey = decoded
        } else {
            self.globalHotkey = .defaultCapture
        }

        self.showInDock = UserDefaults.standard.object(forKey: "showInDock") as? Bool ?? false
        self.launchAtLogin = UserDefaults.standard.object(forKey: "launchAtLogin") as? Bool ?? false  // Default: disabled

        self.captureHistory = UserDefaults.standard.stringArray(forKey: "captureHistory") ?? []

        let seq = UserDefaults.standard.integer(forKey: "screenshotSequence")
        self.screenshotSequence = seq > 0 ? seq : 1

        if let savedLanguage = UserDefaults.standard.string(forKey: "appLanguage"),
           let language = AppLanguage(rawValue: savedLanguage) {
            self.appLanguage = language
        } else {
            self.appLanguage = .system
        }

        self.isInitialized = true
        applyAppLanguage()
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
        panel.prompt = NSLocalizedString("settings.select_folder.prompt", comment: "")
        panel.message = NSLocalizedString("settings.select_folder.message", comment: "")

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

    private func applyAppLanguage() {
        switch appLanguage {
        case .system:
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            Bundle.setAppLanguage(nil)
        default:
            UserDefaults.standard.set([appLanguage.rawValue], forKey: "AppleLanguages")
            Bundle.setAppLanguage(appLanguage.rawValue)
        }
        UserDefaults.standard.synchronize()
    }

    private func playAntarcticChirp() {
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
