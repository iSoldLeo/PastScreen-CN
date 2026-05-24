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

    var body: some View {
        Form {
            // MARK: 通用
            Section {
                LabeledContent("窗口截图") {
                    HotKeyRecorderView(hotkey: $hotkey.windowCaptureHotkey)
                }
                LabeledContent("全屏截图") {
                    HotKeyRecorderView(hotkey: $hotkey.fullScreenHotkey)
                }
                Toggle("开机启动", isOn: $general.launchAtLogin)
                Toggle("截图音效", isOn: $capture.playSoundOnCapture)
            } header: {
                Text("通用")
            } footer: {
                Text("按下快捷键即可在任意应用中触发对应的截图模式。")
            }

            // MARK: 存储
            Section {
                Toggle("保存截图到文件", isOn: $capture.saveToFile)

                Button {
                    selectSaveFolder()
                } label: {
                    HStack {
                        Text("保存到")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(folderDisplayName)
                            .foregroundStyle(.tint)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } header: {
                Text("存储")
            } footer: {
                Text("关闭「保存截图到文件」后，截图仅复制到剪切板，不写入磁盘。")
            }

            // MARK: 关于
            Section {
                Button {
                    showOnboarding()
                } label: {
                    HStack {
                        Text("查看入门指引")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                LabeledContent("版本") {
                    Text(versionString)
                        .foregroundStyle(.secondary)
                }

                Button {
                    if let url = URL(string: "https://github.com/iSoldLeo/Mio") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack {
                        Text("项目主页")
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
                        Text("隐私政策")
                        Spacer()
                        Image(systemName: "arrow.up.forward.app")
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } header: {
                Text("关于")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 540)
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
        // Placeholder until the onboarding subsystem lands in a later
        // batch. Logging here keeps the row visibly clickable.
        NSLog("[Mio] onboarding subsystem not implemented yet — placeholder")
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
                Text("请按下快捷键…")
                    .foregroundStyle(.secondary)
            } else if hotkey.isUnset {
                Text("未设置")
                    .foregroundStyle(.secondary)
            } else {
                Text(hotkey.symbolDisplayString)
                    .font(.body.monospaced())
            }

            Button(isRecording ? "取消" : "更改") {
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
            .help("清除快捷键")
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
