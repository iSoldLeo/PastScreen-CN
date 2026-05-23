//
//  SettingsView.swift
//  Mio
//
//  Settings window with system-styled SwiftUI tabs and forms
//

import SwiftUI
import AppKit

// MARK: - Glass Helpers (inlined from LiquidGlassComponents — sole consumer is SettingsView)

private struct GlassContainerStyle: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var material: Material
    var cornerRadius: CGFloat
    var showBorder: Bool
    var borderOpacity: Double
    var shadowOpacity: Double

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(fillStyle, in: shape)
            .clipShape(shape)
            .overlay {
                if showBorder {
                    shape
                        .strokeBorder(borderStyle, lineWidth: 1)
                }
            }
            .shadow(color: .black.opacity(shadowOpacity), radius: 14, x: 0, y: 8)
    }

    private var fillStyle: AnyShapeStyle {
        if reduceTransparency {
            return AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
        }
        return AnyShapeStyle(material)
    }

    private var borderStyle: AnyShapeStyle {
        if reduceTransparency {
            return AnyShapeStyle(Color(nsColor: .separatorColor).opacity(0.7))
        }
        return AnyShapeStyle(Color.white.opacity(borderOpacity))
    }
}

extension View {
    fileprivate func glassContainer(
        material: Material = .regularMaterial,
        cornerRadius: CGFloat = 12,
        showBorder: Bool = true,
        borderOpacity: Double = 0.14,
        shadowOpacity: Double = 0.10
    ) -> some View {
        modifier(
            GlassContainerStyle(
                material: material,
                cornerRadius: cornerRadius,
                showBorder: showBorder,
                borderOpacity: borderOpacity,
                shadowOpacity: shadowOpacity
            )
        )
    }
}

private struct GlassCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .glassContainer(material: .regularMaterial, cornerRadius: 12)
    }
}

// MARK: - Settings page chrome

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
    @EnvironmentObject var general: GeneralSettings
    @EnvironmentObject var capture: CaptureSettings

    var body: some View {
        SettingsPage {
            SettingsGlassSection(
                NSLocalizedString("settings.general.options", value: "常规", comment: ""),
                systemImage: "slider.horizontal.3"
            ) {
                Toggle(NSLocalizedString("settings.general.launch_at_login", value: "开机启动", comment: ""), isOn: $general.launchAtLogin)
                Toggle(NSLocalizedString("settings.general.play_sound", comment: ""), isOn: $capture.playSoundOnCapture)
            }

            SettingsGlassSection(
                NSLocalizedString("settings.general.privacy_section", value: "隐私", comment: ""),
                systemImage: "hand.raised.fill"
            ) {
                Text(NSLocalizedString("settings.general.privacy.description", value: "Mio 不收集任何数据，所有内容仅保存在你的 Mac 上。", comment: ""))
                    .foregroundStyle(.secondary)

                Text(NSLocalizedString("settings.general.privacy.bullets", value: "• 无分析或追踪\n• 无云端上传\n• 无第三方服务\n• 仅本地运行", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let url = URL(string: "https://github.com/iSoldLeo/Mio/blob/main/PRIVACY.md") {
                    Link(NSLocalizedString("settings.general.privacy.view_policy", value: "查看完整隐私政策", comment: ""), destination: url)
                }
            }
        }
    }
}

// MARK: - Capture Settings

struct CaptureSettingsView: View {
    @EnvironmentObject var hotkey: HotKeySettings

    var body: some View {
        SettingsPage {
            SettingsGlassSection(
                NSLocalizedString("settings.capture.shortcuts_section", comment: ""),
                systemImage: "keyboard"
            ) {
                Toggle(NSLocalizedString("settings.capture.enable_hotkey", comment: ""), isOn: $hotkey.globalHotkeyEnabled)

                if hotkey.globalHotkeyEnabled {
                    LabeledContent(NSLocalizedString("settings.capture.quick_screenshot", value: "快速截图", comment: "")) {
                        HotKeyRecorderView(hotkey: $hotkey.globalHotkey)
                    }
                }
            }
        }
    }
}

// MARK: - Storage Settings

struct StorageSettingsView: View {
    @EnvironmentObject var capture: CaptureSettings

    var body: some View {
        SettingsPage {
            SettingsGlassSection(
                NSLocalizedString("settings.storage.section_title", comment: ""),
                systemImage: "externaldrive"
            ) {
                Toggle(
                    NSLocalizedString("settings.storage.save_to_file", value: "保存截图到文件", comment: ""),
                    isOn: $capture.saveToFile
                )

                Text(NSLocalizedString("settings.storage.save_to_file.help", value: "关闭后，截图仅复制到剪切板，不写入磁盘。", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            .environmentObject(AppSettings.shared.general)
            .environmentObject(AppSettings.shared.hotkey)
            .environmentObject(AppSettings.shared.capture)
    }
}
