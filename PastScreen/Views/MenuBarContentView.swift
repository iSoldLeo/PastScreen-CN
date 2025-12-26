import SwiftUI
import AppKit
import Combine

struct MenuBarContentView: View {
    @Environment(\.openSettings) private var openSettings
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject var app: AppDelegate
    @StateObject private var libraryMenuModel = CaptureLibraryMenuModel()

    private var canRevealLast: Bool { app.lastScreenshotPath != nil }

    var body: some View {
        captureSection
        Divider()
        historySection
        Divider()
        utilitySection
    }

    private var captureSection: some View {
        Group {
            Button(NSLocalizedString("menu.capture_area", comment: "")) {
                app.takeScreenshot()
            }
            .applyHotkey(keyboardShortcut(for: settings.globalHotkeyEnabled ? settings.globalHotkey : nil))

            Button(NSLocalizedString("menu.capture_advanced", comment: "")) {
                app.captureAdvanced()
            }
            .applyHotkey(keyboardShortcut(for: settings.advancedHotkeyEnabled ? settings.advancedHotkey : nil))

            Button(NSLocalizedString("menu.capture_fullscreen", comment: "")) {
                app.captureFullScreen()
            }
        }
    }

    private var historySection: some View {
        Group {
            Button(NSLocalizedString("menu.library.open", value: "打开素材库…", comment: "")) {
                CaptureLibraryManager.shared.show()
            }

            Button(NSLocalizedString("menu.show_last", comment: "")) {
                app.revealLastScreenshot()
            }
            .disabled(!canRevealLast)

            Menu(NSLocalizedString("menu.library.recent", value: "最近 10 条", comment: "")) {
                if libraryMenuModel.items.isEmpty {
                    Text(NSLocalizedString("menu.library.recent.empty", value: "暂无", comment: ""))
                } else {
                    ForEach(libraryMenuModel.items) { item in
                        Button(libraryMenuModel.title(for: item)) {
                            CaptureLibrary.shared.copyImageToClipboard(item: item)
                        }
                    }
                }
            }
        }
        .onAppear {
            libraryMenuModel.refresh()
        }
    }

    private var utilitySection: some View {
        Group {
            Button(NSLocalizedString("menu.destination", comment: "")) {
                app.changeDestinationFolder()
            }
            Button(NSLocalizedString("menu.preferences", comment: "")) {
                // Use SwiftUI's settings action to ensure the Settings scene opens reliably (macOS 14+)
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            Button(NSLocalizedString("menu.quit", comment: "")) {
                app.quit()
            }
        }
    }

    private func keyboardShortcut(for hotkey: HotKey?) -> KeyboardShortcut? {
        guard
            let hotkey,
            let chars = hotkey.characters,
            let first = chars.first
        else { return nil }

        let modifiers = eventModifiers(from: hotkey.modifierFlags)
        return KeyboardShortcut(KeyEquivalent(first), modifiers: modifiers)
    }

    private func eventModifiers(from flags: NSEvent.ModifierFlags) -> EventModifiers {
        var modifiers: EventModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        return modifiers
    }
}

private extension View {
    func applyHotkey(_ shortcut: KeyboardShortcut?) -> some View {
        guard let shortcut else { return AnyView(self) }
        return AnyView(self.keyboardShortcut(shortcut))
    }
}

@MainActor
private final class CaptureLibraryMenuModel: ObservableObject {
    @Published var items: [CaptureItem] = []

    private var observer: Any?
    private let rootURL: URL? = try? CaptureLibraryFileStore.defaultRootURL()

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .captureLibraryChanged,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    func refresh() {
        Task {
            let fetched = await CaptureLibrary.shared.fetchItems(query: .all, limit: 30, offset: 0)
            let copyable = fetched.filter { isCopyable($0) }
            items = Array(copyable.prefix(10))
        }
    }

    func title(for item: CaptureItem) -> String {
        if let appName = item.appName, !appName.isEmpty {
            return appName
        }
        return item.createdAt.formatted(date: .omitted, time: .shortened)
    }

    private func isCopyable(_ item: CaptureItem) -> Bool {
        if let path = item.internalOriginalPath, existsInternal(relativePath: path) { return true }
        if let path = item.internalPreviewPath, existsInternal(relativePath: path) { return true }
        if existsInternal(relativePath: item.internalThumbPath) { return true }
        if let url = item.externalFileURL, FileManager.default.fileExists(atPath: url.path) { return true }
        return false
    }

    private func existsInternal(relativePath: String) -> Bool {
        guard let rootURL else { return false }
        let url = rootURL.appendingPathComponent(relativePath, isDirectory: false)
        return FileManager.default.fileExists(atPath: url.path)
    }
}
