import SwiftUI
import AppKit

struct MenuBarContentView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject var app: AppDelegate

    private var history: [String] { settings.captureHistory }
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
            Button(NSLocalizedString("menu.show_last", comment: "")) {
                app.revealLastScreenshot()
            }
            .disabled(!canRevealLast)

            if history.isEmpty {
                Button(NSLocalizedString("menu.history.empty", comment: "")) {}
                    .disabled(true)
            } else {
                Menu(NSLocalizedString("menu.history", comment: "")) {
                    ForEach(history, id: \.self) { path in
                        Button((path as NSString).lastPathComponent) {
                            app.copyFromHistory(path: path)
                        }
                    }
                    Divider()
                    Button(NSLocalizedString("menu.history.clear", comment: "")) {
                        app.clearHistory()
                    }
                }
            }
        }
    }

    private var utilitySection: some View {
        Group {
            Button(NSLocalizedString("menu.destination", comment: "")) {
                app.changeDestinationFolder()
            }
            Button(NSLocalizedString("menu.preferences", comment: "")) {
                app.openPreferences()
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
