//
//  SettingsView.swift
//  Mio
//
//  Settings window — Apple HIG-conformant single-page Form with grouped
//  sections. Mirrors the visual language of macOS system apps (Reminders,
//  Mail, Safari) by using only system components (Form / Section / Toggle
//  / LabeledContent / Button) and system semantic colors. Light/dark mode
//  adaptation is automatic via system tint.
//
//  Two independent hotkeys (window capture / full-screen) are configured
//  here. Each hotkey row exposes a clear-shortcut button that puts the
//  hotkey into `HotKey.unset` state — replaces the legacy single-toggle
//  "enable global hotkey" approach with per-shortcut control.
//

import SwiftUI
import AppKit
import Combine

// MARK: - Settings root

struct SettingsView: View {
    @EnvironmentObject var general: GeneralSettings
    @EnvironmentObject var hotkey: HotKeySettings
    @EnvironmentObject var capture: CaptureSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            // MARK: 通用
            Section {
                LabeledContent("settings.hotkey.window_capture") {
                    HotKeyRecorderView(hotkey: $hotkey.windowCaptureHotkey)
                }
                LabeledContent("settings.hotkey.advanced_window_capture") {
                    HotKeyRecorderView(hotkey: $hotkey.advancedWindowCaptureHotkey)
                }
                LabeledContent("settings.hotkey.full_screen") {
                    HotKeyRecorderView(hotkey: $hotkey.fullScreenHotkey)
                }
                Toggle("settings.launch_at_login", isOn: $general.launchAtLogin)
                Toggle("settings.play_sound_on_capture", isOn: $capture.playSoundOnCapture)
            } header: {
                Text("settings.section.general")
            } footer: {
                Text("settings.section.general.footer")
            }

            // MARK: 画框
            Section {
                Toggle("settings.frame.enabled", isOn: $capture.captureFrameEnabled)

                LabeledContent("settings.frame.signature") {
                    TextField(
                        "",
                        text: $capture.captureFrameCustomText,
                        prompt: capture.captureFrameCustomText.isEmpty
                            ? Text("settings.frame.signature.placeholder")
                            : nil
                    )
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.tint)
                    .disabled(!capture.captureFrameEnabled)
                    .onChange(of: capture.captureFrameCustomText) { _, newValue in
                        // 40 字符上限（spec §3.5）。超出立即截断。
                        if newValue.count > 40 {
                            capture.captureFrameCustomText = String(newValue.prefix(40))
                        }
                    }
                }

                Picker(selection: $capture.captureFrameTheme) {
                    ForEach(CaptureFrameTheme.allCases) { theme in
                        Text(theme.localizedLabel).tag(theme)
                    }
                } label: {
                    Text("settings.frame.theme")
                }
                .pickerStyle(.menu)
                .disabled(!capture.captureFrameEnabled)
            } header: {
                Text("settings.section.frame")
            } footer: {
                Text("settings.section.frame.footer")
            }

            // MARK: 存储
            Section {
                Toggle("settings.save_to_file", isOn: $capture.saveToFile)

                Button {
                    selectSaveFolder()
                } label: {
                    HStack {
                        Text("settings.save_to")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(folderDisplayName)
                            .foregroundStyle(.tint)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } header: {
                Text("settings.section.storage")
            } footer: {
                Text("settings.section.storage.footer")
            }

            // MARK: 关于
            Section {
                Button {
                    showOnboarding()
                } label: {
                    HStack {
                        Text("settings.view_onboarding")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                LabeledContent("settings.version") {
                    Text(versionString)
                        .foregroundStyle(.secondary)
                }

                Button {
                    if let url = URL(string: "https://github.com/iSoldLeo/Mio") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack {
                        Text("settings.project_homepage")
                        Spacer()
                        Image(systemName: "arrow.up.forward.app")
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    if let url = URL(string: "https://github.com/iSoldLeo/Mio/blob/main/PRIVACY.md") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack {
                        Text("settings.privacy_policy")
                        Spacer()
                        Image(systemName: "arrow.up.forward.app")
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } header: {
                Text("settings.section.about")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 660)
    }

    // MARK: Actions

    private func selectSaveFolder() {
        // Bring app to front so NSOpenPanel attaches as expected.
        NSApp.activate(ignoringOtherApps: true)
        if let newPath = capture.selectFolder() {
            capture.saveFolderPath = newPath
        }
    }

    private func showOnboarding() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "onboarding")
    }

    // MARK: Derived

    private var folderDisplayName: String {
        if capture.saveFolderPath.isEmpty {
            return "选择文件夹…"
        }
        let url = URL(fileURLWithPath: capture.saveFolderPath)
        return url.lastPathComponent.isEmpty ? capture.saveFolderPath : url.lastPathComponent
    }

    private var versionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
}

// MARK: - Hotkey recorder

struct HotKeyRecorderView: View {
    @Binding var hotkey: HotKey
    @State private var isRecording = false
    @State private var localMonitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            if isRecording {
                Text("settings.hotkey.press_prompt")
                    .foregroundStyle(.secondary)
            } else if hotkey.isUnset {
                Text("settings.hotkey.unset")
                    .foregroundStyle(.secondary)
            } else {
                Text(hotkey.symbolDisplayString)
                    .font(.body.monospaced())
            }

            Button(isRecording ? LocalizedStringKey("common.cancel") : LocalizedStringKey("common.change")) {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            // Clear button — hidden (zero opacity, layout preserved) when
            // already unset or actively recording. `.opacity(0)` instead
            // of `if`-omission keeps the recorder row height stable
            // across the three states (recording / unset / set).
            Button {
                hotkey = .unset
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .opacity(hotkey.isUnset || isRecording ? 0 : 1)
            .disabled(hotkey.isUnset || isRecording)
            .help("settings.hotkey.clear")
        }
        .onDisappear {
            stopRecording()
        }
    }

    private func startRecording() {
        guard localMonitor == nil else { return }

        isRecording = true
        HotKeyManager.shared.setRecordingHotKey(true)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // SAFETY: addLocalMonitorForEvents always delivers on the main thread.
            MainActor.assumeIsolated {
                let modifiers = HotKey.normalizedModifiers(event.modifierFlags)
                let characters = event.charactersIgnoringModifiers?.lowercased()
                hotkey = HotKey(keyCode: event.keyCode, modifiers: modifiers.rawValue, characters: characters)
                stopRecording()
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        isRecording = false
        HotKeyManager.shared.setRecordingHotKey(false)
    }
}

extension HotKey {
    var symbolDisplayString: String {
        var parts: [String] = []
        if modifierFlags.contains(.control) { parts.append("⌃") }
        if modifierFlags.contains(.option) { parts.append("⌥") }
        if modifierFlags.contains(.shift) { parts.append("⇧") }
        if modifierFlags.contains(.command) { parts.append("⌘") }
        parts.append(displayKey)
        return parts.joined()
    }
}

// MARK: - Preview

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .environmentObject(AppSettings.shared.general)
            .environmentObject(AppSettings.shared.hotkey)
            .environmentObject(AppSettings.shared.capture)
    }
}
