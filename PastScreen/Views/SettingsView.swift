//
//  SettingsView.swift
//  PastScreen
//
//  Settings window with system-styled SwiftUI tabs and forms
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
#if canImport(TipKit)
import TipKit
#endif

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

            EditorSettingsView()
                .tabItem { Label(NSLocalizedString("settings.tab.editor", value: "编辑", comment: ""), systemImage: "paintbrush.pointed") }

            StorageSettingsView()
                .tabItem { Label(NSLocalizedString("settings.tab.storage", value: "存储", comment: ""), systemImage: "folder.fill") }

            AppsSettingsView()
                .tabItem { Label(NSLocalizedString("settings.tab.apps", value: "应用", comment: ""), systemImage: "macwindow") }
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
        // Off-screen预渲染编辑页的径向预览，打开设置时就触发GPU管线，减少切换时卡顿
        .overlay(alignment: .topLeading) {
            radialPrewarmView
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
                NSLocalizedString("settings.general.help_section", value: "帮助", comment: ""),
                systemImage: "questionmark.circle"
            ) {
                Button {
                    OnboardingManager.shared.show()
                } label: {
                    Label(NSLocalizedString("settings.general.help.view_tutorial", value: "查看教程", comment: ""), systemImage: "play.circle")
                }
                .buttonStyle(.bordered)
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

                    Toggle(NSLocalizedString("settings.capture.advanced_screenshot", value: "高级截图", comment: ""), isOn: $settings.advancedHotkeyEnabled)

                    LabeledContent(NSLocalizedString("settings.capture.advanced_screenshot", value: "高级截图", comment: "")) {
                        HotKeyRecorderView(hotkey: $settings.advancedHotkey)
                            .disabled(!settings.advancedHotkeyEnabled)
                    }

                    Toggle(NSLocalizedString("settings.capture.ocr_capture", value: "OCR", comment: ""), isOn: $settings.ocrHotkeyEnabled)

                    LabeledContent(NSLocalizedString("settings.capture.ocr_capture", value: "OCR", comment: "")) {
                        HotKeyRecorderView(hotkey: $settings.ocrHotkey)
                            .disabled(!settings.ocrHotkeyEnabled)
                    }
                }
            }
        }
    }
}

// MARK: - Editor Settings

struct EditorSettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var radialTools: [DrawingTool] = DrawingTool.defaultRadialTools

    private var availableRadialTools: [DrawingTool] { settings.radialAvailableTools }
    private var maxRadialCount: Int { min(4, availableRadialTools.count) }

    var body: some View {
        SettingsPage {
            SettingsGlassSection(
                NSLocalizedString("settings.editor.toolbar.title", comment: ""),
                systemImage: "paintbrush.pointed",
                footer: NSLocalizedString("settings.editor.toolbar.reorder_hint", comment: "")
            ) {
                Text(NSLocalizedString("settings.editor.toolbar.description", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                List($settings.editingToolOrder, id: \.self, editActions: .move) { $tool in
                    Toggle(isOn: binding(for: tool)) {
                        Label(tool.localizedName, systemImage: tool.systemImage)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .frame(maxHeight: CGFloat(max(settings.editingToolOrder.count, 1)) * 34 + 12)
                .toggleStyle(TrailingSwitchToggleStyle())
                .glassContainer(material: .thinMaterial, cornerRadius: 10, borderOpacity: 0.12, shadowOpacity: 0.0)
            }

            SettingsGlassSection(
                NSLocalizedString("settings.editor.radial.title", comment: ""),
                systemImage: "circle.grid.3x3.fill"
            ) {
                Toggle(NSLocalizedString("settings.editor.radial.enabled", comment: ""), isOn: $settings.radialWheelEnabled)

                Text(NSLocalizedString("settings.editor.radial.description", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Group {
                    ForEach(Array(radialTools.enumerated()), id: \.element) { index, tool in
                        LabeledContent {
                            ControlGroup {
                                Button {
                                    moveRadialTool(at: index, offset: -1)
                                } label: {
                                    Image(systemName: "chevron.up")
                                }
                                .disabled(index == 0)

                                Button {
                                    moveRadialTool(at: index, offset: 1)
                                } label: {
                                    Image(systemName: "chevron.down")
                                }
                                .disabled(index == radialTools.count - 1)

                                Button {
                                    removeRadialTool(at: index)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .disabled(radialTools.count <= 1)
                            }
                            .controlSize(.small)
                        } label: {
                            Picker("", selection: Binding(
                                get: { radialTools[index] },
                                set: { newValue in updateRadialTool(at: index, with: newValue) }
                            )) {
                                ForEach(availableRadialTools, id: \.self) { option in
                                    Label(option.localizedName, systemImage: option.systemImage)
                                        .tag(option)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                    }

                    if radialTools.count < maxRadialCount {
                        Button {
                            addRadialTool()
                        } label: {
                            Label(NSLocalizedString("settings.editor.radial.add", comment: ""), systemImage: "plus.circle")
                        }
                        .buttonStyle(.borderless)
                    }

                    RadialWheelPreview(tools: radialTools)
                        .frame(maxWidth: .infinity)

                    Text(NSLocalizedString("settings.editor.radial.note", comment: ""))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                        .disabled(!settings.radialWheelEnabled)
                        .opacity(settings.radialWheelEnabled ? 1 : 0.6)
            }

            SettingsGlassSection(
                NSLocalizedString("settings.editor.ocr.title", value: "OCR", comment: ""),
                systemImage: "text.viewfinder",
                footer: NSLocalizedString("settings.editor.ocr.note", value: "不勾选任何语言时，将使用系统默认/自动检测。", comment: "")
            ) {
                Text(NSLocalizedString("settings.editor.ocr.description", value: "选择启用的识别语言，使用时会在已启用语言中自动识别。", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(NSLocalizedString("settings.editor.ocr.reset", value: "恢复默认", comment: "")) {
                    settings.resetOCRLanguagesToDefault()
                }
                .controlSize(.small)

                ForEach(OCRLanguageOption.recommended) { option in
                    Toggle(option.displayName, isOn: Binding(
                        get: { settings.ocrRecognitionLanguages.contains(option.code) },
                        set: { settings.setOCRLanguageEnabled(option.code, enabled: $0) }
                    ))
                }
            }
        }
        .onAppear {
            radialTools = settings.radialDrawingTools
        }
        .onChange(of: settings.radialToolIdentifiers) { _, _ in radialTools = settings.radialDrawingTools }
    }

    private func binding(for tool: DrawingTool) -> Binding<Bool> {
        Binding(
            get: { settings.enabledEditingTools.contains(tool) },
            set: { newValue in
                settings.updateEditingTool(tool, enabled: newValue)
            }
        )
    }

    private func addRadialTool() {
        guard !availableRadialTools.isEmpty else { return }
        var updated = radialTools
        let unusedTools = availableRadialTools.filter { !updated.contains($0) }
        if let next = unusedTools.first {
            updated.append(next)
        } else if let fallback = availableRadialTools.first {
            updated.append(fallback)
        }
        applyRadialTools(updated)
    }

    private func removeRadialTool(at index: Int) {
        guard radialTools.count > 1, radialTools.indices.contains(index) else { return }
        var updated = radialTools
        updated.remove(at: index)
        applyRadialTools(updated)
    }

    private func moveRadialTool(at index: Int, offset: Int) {
        var updated = radialTools
        let destination = index + offset

        guard updated.indices.contains(index), updated.indices.contains(destination) else { return }

        updated.swapAt(index, destination)
        applyRadialTools(updated)
    }

    private func updateRadialTool(at index: Int, with newTool: DrawingTool) {
        guard radialTools.indices.contains(index) else { return }
        var updated = radialTools
        updated[index] = newTool
        applyRadialTools(updated)
    }

    private func applyRadialTools(_ tools: [DrawingTool]) {
        let cleaned = deduplicatedRadialTools(tools)
        let normalized = settings.updateRadialTools(cleaned)
        radialTools = normalized
    }

    private func deduplicatedRadialTools(_ tools: [DrawingTool]) -> [DrawingTool] {
        var seen = Set<DrawingTool>()
        var ordered: [DrawingTool] = []

        for tool in tools.reversed() {
            if seen.insert(tool).inserted {
                ordered.append(tool)
            }
        }

        return ordered.reversed()
    }
}

private struct RadialWheelPreview: View {
    let tools: [DrawingTool]

    var body: some View {
        GeometryReader { geometry in
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let highlight = CGPoint(x: center.x, y: center.y - 40)
            RadialToolPalette(
                center: center,
                current: tools.isEmpty ? center : highlight,
                tools: tools.isEmpty ? DrawingTool.defaultRadialTools : tools,
                deadZoneRadius: 30,
                toolNameProvider: { $0.localizedName },
                selectedIndex: tools.isEmpty ? nil : 0
            )
        }
        .frame(width: 220, height: 200)
        // Offload complex radial rendering to GPU to avoid主线程卡顿
        .drawingGroup()
    }
}

private struct TrailingSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
                .onTapGesture { configuration.isOn.toggle() }
            Spacer()
            Toggle("", isOn: configuration.$isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .scaleEffect(0.82)
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
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    if let newPath = settings.selectFolder() {
                                        settings.saveFolderPath = newPath
                                    }
                                }
                            }
                        }
                    }

                if settings.saveToFile {
                    LabeledContent(NSLocalizedString("settings.storage.save_folder.label", value: "保存位置", comment: "")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(settings.saveFolderPath.replacingOccurrences(of: "/Users/\(NSUserName())", with: "~"))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            HStack {
                                Button(NSLocalizedString("settings.storage.change_button", comment: "")) {
                                    if let newPath = settings.selectFolder() {
                                        settings.saveFolderPath = newPath
                                    }
                                }

                                Button(NSLocalizedString("settings.storage.open_folder", comment: "")) {
                                    NSWorkspace.shared.open(URL(fileURLWithPath: settings.saveFolderPath))
                                }

                                Spacer()

                                Button(NSLocalizedString("settings.storage.clear_folder", comment: "")) {
                                    settings.clearSaveFolder()
                                }
                                .foregroundColor(.red)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Apps Settings

struct AppsSettingsView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        SettingsPage {
            SettingsGlassSection(
                NSLocalizedString("settings.apps.rules", value: "规则", comment: ""),
                systemImage: "macwindow"
            ) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(NSLocalizedString("settings.apps.default_behavior", value: "默认：复制图片到剪贴板", comment: ""), systemImage: "info.circle.fill")
                        .font(.subheadline)
                    Text(NSLocalizedString("settings.apps.instructions", value: "在下面添加应用，如果需要复制文件路径，请将其设置为“路径”（适用于终端）。", comment: ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()
                    .padding(.vertical, 4)

                if settings.appOverrides.isEmpty {
                    ContentUnavailableView {
                        Label(NSLocalizedString("settings.apps.empty_title", value: "暂无应用规则", comment: ""), systemImage: "macwindow.badge.plus")
                    } description: {
                        Text(NSLocalizedString("settings.apps.empty_description", value: "添加应用以改变剪贴板行为。\n终端需要文件路径时使用“路径”。", comment: ""))
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    ForEach($settings.appOverrides) { $override in
                        LabeledContent {
                            HStack(spacing: 8) {
                                Picker("", selection: $override.format) {
                                    Text(NSLocalizedString("settings.apps.clipboard.image", value: "图片", comment: "")).tag(ClipboardFormat.image)
                                    Text(NSLocalizedString("settings.apps.clipboard.path", value: "路径", comment: "")).tag(ClipboardFormat.path)
                                }
                                .labelsHidden()
                                .frame(width: 120)

                                Button {
                                    settings.removeAppOverride(id: override.bundleIdentifier)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(override.appName)
                                    .fontWeight(.medium)
                                Text(override.bundleIdentifier)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
            }

            SettingsGlassSection(
                NSLocalizedString("settings.apps.add_rule", value: "添加应用规则", comment: ""),
                systemImage: "plus"
            ) {
                Button(action: addApp) {
                    Label(NSLocalizedString("settings.apps.add_rule", value: "添加应用规则", comment: ""), systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = NSLocalizedString("settings.select_folder.prompt", comment: "")
        panel.message = NSLocalizedString("settings.apps.select_app_message", value: "选择一个应用", comment: "")

        if panel.runModal() == .OK, let url = panel.url {
            if let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier {
                let name = FileManager.default.displayName(atPath: url.path)
                let override = AppOverride(bundleIdentifier: bundleID, appName: name, format: .path)
                settings.addAppOverride(override)
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

private extension SettingsView {
    var radialPrewarmView: some View {
        RadialWheelPreview(tools: settings.radialDrawingTools)
            .frame(width: 220, height: 200)
            .opacity(0.001)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .environmentObject(AppSettings.shared)
    }
}
