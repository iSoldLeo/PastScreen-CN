import SwiftUI
import AppKit

struct MenuBarContentView: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var hotkey = AppSettings.shared.hotkey
    @ObservedObject var app: AppDelegate

    var body: some View {
        captureSection
        Divider()
        utilitySection
    }

    private var captureSection: some View {
        Group {
            Button(NSLocalizedString("menu.capture_area", comment: "")) {
                app.takeScreenshot()
            }
            .applyHotkey(keyboardShortcut(for: hotkey.windowCaptureHotkey))

            Button(NSLocalizedString("menu.capture_advanced", comment: "")) {
                app.takeAdvancedScreenshot()
            }
            .applyHotkey(keyboardShortcut(for: hotkey.advancedWindowCaptureHotkey))

            Button(NSLocalizedString("menu.capture_fullscreen", comment: "")) {
                app.captureFullScreen()
            }
            .applyHotkey(keyboardShortcut(for: hotkey.fullScreenHotkey))
        }
    }

    private var utilitySection: some View {
        Group {
            Button(NSLocalizedString("menu.preferences", comment: "")) {
                // Use SwiftUI's settings action to ensure the Settings scene opens reliably (macOS 14+)
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            // 临时入口：onboarding 还在开发，正式版前从设置→项目指引进入。
            // 现在直接挂菜单栏方便迭代时调试。落地完成后删掉这一项。
            Button("项目指引（开发预览）") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "onboarding")
            }
            Button(NSLocalizedString("menu.quit", comment: "")) {
                app.quit()
            }
        }
    }

    private func keyboardShortcut(for hotkey: HotKey) -> KeyboardShortcut? {
        guard
            !hotkey.isUnset,
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
