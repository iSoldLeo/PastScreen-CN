//
//  SettingsView.swift
//  PastScreen
//
//  Settings window with system-styled SwiftUI tabs and forms
//

import SwiftUI
@preconcurrency import AppKit  // NSEvent 未标记 Sendable
import Combine

private struct SettingsPage<Content: View>: View {
    private let content: Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .background {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                Rectangle().fill(.ultraThinMaterial)
            }
        }
    }
}

private struct SettingsGlassSection<Content: View>: View {
    private let title: String
    private let systemImage: String
    private let footer: String?
    private let content: Content

    init(_ title: String, systemImage: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(title, systemImage: systemImage)
                    .font(.headline)

                Divider()

                content

                if let footer {
                    Text(footer)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label(NSLocalizedString("settings.tab.general", value: "通用", comment: ""), systemImage: "gear") }

            CaptureSettingsView()
                .tabItem { Label(NSLocalizedString("settings.tab.capture", value: "截图", comment: ""), systemImage: "camera.fill") }

            StorageSettingsView()
                .tabItem { Label(NSLocalizedString("settings.tab.storage", value: "存储", comment: ""), systemImage: "folder.fill") }
        }
        .frame(minWidth: 720, idealWidth: 780, minHeight: 560)
        .background {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                Rectangle().fill(.ultraThinMaterial)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding([.trailing, .bottom], 8)
        }
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        SettingsPage {
            SettingsGlassSection(
                NSLocalizedString("settings.general.options", value: "常规", comment: ""),
                systemImage: "slider.horizontal.3",
                footer: NSLocalizedString("settings.general.language.note", value: "更改后重启应用生效", comment: "")
            ) {
                Toggle(NSLocalizedString("settings.general.launch_at_login", value: "开机启动", comment: ""), isOn: $settings.launchAtLogin)
                Toggle(NSLocalizedString("settings.general.show_in_dock", value: "在 Dock 栏里显示", comment: ""), isOn: $settings.showInDock)
                Toggle(NSLocalizedString("settings.general.play_sound", comment: ""), isOn: $settings.playSoundOnCapture)
                Picker(NSLocalizedString("settings.general.language", value: "语言", comment: ""), selection: $settings.appLanguage) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.menu)
            }

            SettingsGlassSection(
                NSLocalizedString("settings.general.privacy_section", value: "隐私", comment: ""),
                systemImage: "hand.raised.fill"
            ) {
                Text(NSLocalizedString("settings.general.privacy.description", value: "PastScreen-CN 不收集任何数据，所有内容仅保存在你的 Mac 上。", comment: ""))
                    .foregroundStyle(.secondary)

                Text(NSLocalizedString("settings.general.privacy.bullets", value: "• 无分析或追踪\n• 无云端上传\n• 无第三方服务\n• 仅本地运行", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let url = URL(string: "https://github.com/iSoldLeo/PastScreen-CN/blob/main/PRIVACY.md") {
                    Link(NSLocalizedString("settings.general.privacy.view_policy", value: "查看完整隐私政策", comment: ""), destination: url)
                }
            }
        }
    }
}

// MARK: - Capture Settings

struct CaptureSettingsView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        SettingsPage {
            SettingsGlassSection(
                NSLocalizedString("settings.capture.clipboard_section", value: "复制", comment: ""),
                systemImage: "doc.on.clipboard"
            ) {
                Picker(NSLocalizedString("settings.capture.clipboard.default", value: "截图后复制", comment: ""), selection: $settings.captureClipboardFormat) {
                    Text(NSLocalizedString("settings.capture.clipboard.image", value: "图片", comment: "")).tag(CaptureClipboardFormat.image)
                    Text(NSLocalizedString("settings.capture.clipboard.path", value: "路径（文本）", comment: "")).tag(CaptureClipboardFormat.path)
                    Text(NSLocalizedString("settings.capture.clipboard.markdown_image", value: "Markdown 图片引用", comment: "")).tag(CaptureClipboardFormat.markdownImage)
                }
                .pickerStyle(.menu)

                if settings.captureClipboardFormat != .image {
                    Text(NSLocalizedString("settings.capture.clipboard.requires_saving", value: "复制路径/Markdown 需要启用并设置“保存到磁盘”。", comment: ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            SettingsGlassSection(
                NSLocalizedString("settings.capture.format_section", comment: ""),
                systemImage: "photo"
            ) {
                Picker(NSLocalizedString("settings.capture.image_format", comment: ""), selection: $settings.imageFormat) {
                    Text(NSLocalizedString("settings.capture.format_png", comment: "")).tag("png")
                    Text(NSLocalizedString("settings.capture.format_jpeg", comment: "")).tag("jpeg")
                }
                .pickerStyle(.segmented)
            }

            SettingsGlassSection(
                NSLocalizedString("settings.capture.window_border", value: "窗口边框", comment: ""),
                systemImage: "square.on.square.dashed"
            ) {
                Toggle(NSLocalizedString("settings.capture.window_border.enable", value: "启用窗口边框", comment: ""), isOn: $settings.windowBorderEnabled)

                if settings.windowBorderEnabled {
                    LabeledContent(NSLocalizedString("settings.capture.window_border.width", value: "边框宽度", comment: "")) {
                        HStack(spacing: 8) {
                            Slider(value: $settings.windowBorderWidth, in: 8...32, step: 1)
                            Text("\(Int(settings.windowBorderWidth)) pt")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }

                    LabeledContent(NSLocalizedString("settings.capture.window_border.corner", value: "圆角半径", comment: "")) {
                        HStack(spacing: 8) {
                            Slider(value: $settings.windowBorderCornerRadius, in: 8...32, step: 1)
                            Text("\(Int(settings.windowBorderCornerRadius)) pt")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }

                    ColorPicker(
                        NSLocalizedString("settings.capture.window_border.color", value: "边框颜色", comment: ""),
                        selection: Binding<Color>(
                            get: { settings.windowBorderColor.swiftUIColor },
                            set: { newColor in
                                if let cg = newColor.cgColor, let rgba = RGBAColor(cgColor: cg) {
                                    settings.windowBorderColor = rgba
                                }
                            }
                        ),
                        supportsOpacity: true
                    )
                }
            }

            SettingsGlassSection(
                NSLocalizedString("settings.capture.shortcuts_section", comment: ""),
                systemImage: "keyboard"
            ) {
                Toggle(NSLocalizedString("settings.capture.enable_hotkey", comment: ""), isOn: $settings.globalHotkeyEnabled)

                if settings.globalHotkeyEnabled {
                    LabeledContent(NSLocalizedString("settings.capture.quick_screenshot", value: "快速截图", comment: "")) {
                        HotKeyRecorderView(hotkey: $settings.globalHotkey)
                    }
                }
            }
        }
    }
}

// MARK: - Storage Settings

struct StorageSettingsView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        SettingsPage {
            SettingsGlassSection(
                NSLocalizedString("settings.storage.section_title", comment: ""),
                systemImage: "externaldrive"
            ) {
                Toggle(NSLocalizedString("settings.storage.save_to_disk", comment: ""), isOn: $settings.saveToFile)
                    .onChange(of: settings.saveToFile) { _, newValue in
                        if newValue {
                            if !settings.hasValidBookmark {
                                Task { @MainActor in
                                    try? await Task.sleep(nanoseconds: 100_000_000)
                                    if let newPath = settings.selectFolder() {
                                        settings.saveFolderPath = newPath
                                    }
                                }
                            }
                        }
                    }

                if settings.saveToFile {
                    LabeledContent(NSLocalizedString("settings.storage.save_folder.label", value: "保存位置", comment: "")) {
                        HStack(spacing: 10) {
                            Text(settings.saveFolderPath.replacingOccurrences(of: "/Users/\(NSUserName())", with: "~"))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Button(NSLocalizedString("settings.storage.change_button", comment: "")) {
                                if let newPath = settings.selectFolder() {
                                    settings.saveFolderPath = newPath
                                }
                            }
                            .controlSize(.small)

                            Button(NSLocalizedString("settings.storage.open_folder", comment: "")) {
                                NSWorkspace.shared.open(URL(fileURLWithPath: settings.saveFolderPath))
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Hotkey helpers

struct KeyboardShortcutView: View {
    let keys: [String]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(.subheadline, design: .monospaced))
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 24, minHeight: 24)
                    .padding(.horizontal, 4)
                    .glassContainer(material: .ultraThinMaterial, cornerRadius: 4, borderOpacity: 0.18, shadowOpacity: 0.0)
            }
        }
    }
}

struct HotKeyRecorderView: View {
    @Binding var hotkey: HotKey
    @State private var isRecording = false
    @State private var localMonitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            if isRecording {
                Text(NSLocalizedString("hotkey.prompt.press", value: "请按下快捷键...", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                KeyboardShortcutView(keys: hotkey.symbolDisplayParts)
            }

            Button(isRecording ? NSLocalizedString("common.cancel", comment: "") : NSLocalizedString("common.change", value: "更改", comment: "")) {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
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
            let modifiers = HotKey.normalizedModifiers(event.modifierFlags)
            let characters = event.charactersIgnoringModifiers?.lowercased()
            hotkey = HotKey(keyCode: event.keyCode, modifiers: modifiers.rawValue, characters: characters)
            stopRecording()
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
    var symbolDisplayParts: [String] {
        var parts: [String] = []
        if modifierFlags.contains(.control) { parts.append("⌃") }
        if modifierFlags.contains(.option) { parts.append("⌥") }
        if modifierFlags.contains(.shift) { parts.append("⇧") }
        if modifierFlags.contains(.command) { parts.append("⌘") }
        parts.append(displayKey)
        return parts
    }

    var symbolDisplayString: String {
        symbolDisplayParts.joined()
    }
}


struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .environmentObject(AppSettings.shared)
    }
}
