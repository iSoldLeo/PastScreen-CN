//
//  SettingsView.swift
//  PastScreen
//
//  Settings window with modern Sidebar UI and Glass design
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
#if canImport(TipKit)
import TipKit
#endif

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var selectedTab: SettingsTab = .general

    enum SettingsTab: CaseIterable {
        case general
        case capture
        case editor
        case storage
        case apps

        var title: String {
            switch self {
            case .general:
                return NSLocalizedString("settings.tab.general", value: "通用", comment: "")
            case .capture:
                return NSLocalizedString("settings.tab.capture", value: "截图", comment: "")
            case .editor:
                return NSLocalizedString("settings.tab.editor", value: "编辑", comment: "")
            case .storage:
                return NSLocalizedString("settings.tab.storage", value: "存储", comment: "")
            case .apps:
                return NSLocalizedString("settings.tab.apps", value: "应用", comment: "")
            }
        }

        var icon: String {
            switch self {
            case .general: return "gear"
            case .capture: return "camera.fill"
            case .editor: return "paintbrush.pointed"
            case .storage: return "folder.fill"
            case .apps: return "macwindow"
            }
        }

        var color: Color {
            switch self {
            case .general: return .gray
            case .capture: return .red
            case .editor: return .orange
            case .storage: return .blue
            case .apps: return .green
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            VStack(spacing: 4) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    SidebarButton(tab: tab, isSelected: selectedTab == tab) {
                        selectedTab = tab
                    }
                }
                Spacer()

                // Footer - Read version dynamically from Bundle
                Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            }
            .padding(.vertical)
            .padding(.horizontal, 10)
            .frame(width: 180)
            .background(.ultraThinMaterial)

            Divider()

            // Content
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text(selectedTab.title)
                        .font(.title)
                        .fontWeight(.bold)
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 24)

                ScrollView {
                    VStack(spacing: 32) {
                        switch selectedTab {
                        case .general: GeneralSettingsView()
                        case .capture: CaptureSettingsView()
                        case .editor: EditorSettingsView()
                        case .storage: StorageSettingsView()
                        case .apps: AppsSettingsView()
                        }
                    }
                    .padding(24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 750, height: 580)
    }
}

struct SidebarButton: View {
    let tab: SettingsView.SettingsTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(tab.color)
                        .frame(width: 22, height: 22)

                    Image(systemName: tab.icon)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                }

                Text(tab.title)
                    .font(.system(size: 13))
                    .fontWeight(isSelected ? .medium : .regular)
                    .foregroundColor(isSelected ? .white : .primary)

                Spacer()
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(isSelected ? Color.accentColor : Color.clear)
            .cornerRadius(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 32) {
            VStack(alignment: .leading, spacing: 8) {
                Label(NSLocalizedString("settings.general.options", value: "选项", comment: ""), systemImage: "gearshape")
                    .font(.headline)
                    .padding(.leading, 2)

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(NSLocalizedString("settings.general.launch_at_login", value: "开机启动", comment: ""), isOn: $settings.launchAtLogin)
                        Divider()
                        Toggle(NSLocalizedString("settings.general.show_in_dock", value: "在 Dock 栏里显示", comment: ""), isOn: $settings.showInDock)
                        Divider()
                        Toggle(NSLocalizedString("settings.general.play_sound", comment: ""), isOn: $settings.playSoundOnCapture)
                        Divider()
                        HStack {
                            Text(NSLocalizedString("settings.general.language", value: "语言", comment: ""))
                            Spacer()
                            Picker("", selection: $settings.appLanguage) {
                                ForEach(AppLanguage.allCases) { lang in
                                    Text(lang.displayName).tag(lang)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 140)
                        }
                        Text(NSLocalizedString("settings.general.language.note", value: "更改后重启应用生效", comment: ""))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Label(NSLocalizedString("settings.general.help_section", value: "帮助", comment: ""), systemImage: "questionmark.circle")
                    .font(.headline)
                    .padding(.leading, 2)

                GroupBox {
                    HStack {
                        Text(NSLocalizedString("settings.general.help.prompt", value: "需要入门帮助？", comment: ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(NSLocalizedString("settings.general.help.view_tutorial", value: "查看教程", comment: "")) {
                            OnboardingManager.shared.show()
                        }
                    }
                    .padding(12)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Label(NSLocalizedString("settings.general.privacy_section", value: "隐私", comment: ""), systemImage: "hand.raised.fill")
                    .font(.headline)
                    .padding(.leading, 2)

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(NSLocalizedString("settings.general.privacy.title", value: "你的隐私很重要", comment: ""))
                                    .font(.subheadline)
                                    .fontWeight(.medium)

                                Text(NSLocalizedString("settings.general.privacy.description", value: "PastScreen-CN 不收集任何数据，所有内容仅保存在你的 Mac 上。", comment: ""))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }

                        Divider()

                        HStack {
                            Text(NSLocalizedString("settings.general.privacy.bullets", value: "• 无分析或追踪\n• 无云端上传\n• 无第三方服务\n• 仅本地运行", comment: ""))
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Spacer()

                            Button(NSLocalizedString("settings.general.privacy.view_policy", value: "查看完整隐私政策", comment: "")) {
                                if let url = URL(string: "https://github.com/iSoldLeo/PastScreen-CN/blob/main/PRIVACY.md") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
    }
}

// MARK: - Capture Settings

struct CaptureSettingsView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 32) {
            VStack(alignment: .leading, spacing: 8) {
                Label(NSLocalizedString("settings.capture.format_section", comment: ""), systemImage: "photo")
                    .font(.headline)
                    .padding(.leading, 2)

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker(NSLocalizedString("settings.capture.image_format", comment: ""), selection: $settings.imageFormat) {
                            Text(NSLocalizedString("settings.capture.format_png", comment: "")).tag("png")
                            Text(NSLocalizedString("settings.capture.format_jpeg", comment: "")).tag("jpeg")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        HStack {
                            Text(NSLocalizedString("settings.capture.image_format", comment: ""))
                                .foregroundStyle(.secondary)
                            Text(settings.imageFormat.uppercased())
                                .fontWeight(.medium)
                            Spacer()
                        }
                        .font(.caption)
                    }
                    .padding(12)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Label(NSLocalizedString("settings.capture.shortcuts_section", comment: ""), systemImage: "keyboard")
                    .font(.headline)
                    .padding(.leading, 2)

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(NSLocalizedString("settings.capture.enable_hotkey", comment: ""), isOn: $settings.globalHotkeyEnabled)

                        if settings.globalHotkeyEnabled {
                            Divider()
                            HStack {
                                Text(NSLocalizedString("settings.capture.quick_screenshot", value: "快速截图", comment: ""))
                                Spacer()
                                HotKeyRecorderView(hotkey: $settings.globalHotkey)
                            }
                            Divider()
                            HStack {
                                Text(NSLocalizedString("settings.capture.advanced_screenshot", value: "高级截图", comment: ""))
                                Spacer()
                                Toggle("", isOn: $settings.advancedHotkeyEnabled)
                                    .labelsHidden()
                                HotKeyRecorderView(hotkey: $settings.advancedHotkey)
                                    .disabled(!settings.advancedHotkeyEnabled)
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
    }
}

// MARK: - Editor Settings

struct EditorSettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var radialTools: [DrawingTool] = DrawingTool.defaultRadialTools
    private var orderedTools: [DrawingTool] {
        settings.orderedEditingTools
    }
    private var availableRadialTools: [DrawingTool] {
        settings.radialAvailableTools
    }
    private var maxRadialCount: Int {
        min(4, availableRadialTools.count)
    }

    var body: some View {
        VStack(spacing: 32) {
            VStack(alignment: .leading, spacing: 8) {
                Label(NSLocalizedString("settings.editor.toolbar.title", comment: ""), systemImage: "paintbrush.pointed")
                    .font(.headline)
                    .padding(.leading, 2)

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(NSLocalizedString("settings.editor.toolbar.description", comment: ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        
                        Text(NSLocalizedString("settings.editor.toolbar.reorder_hint", comment: ""))
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Divider()

                        ForEach(Array(orderedTools.enumerated()), id: \.element) { index, tool in
                            HStack(spacing: 8) {
                                Toggle(isOn: binding(for: tool)) {
                                    HStack(spacing: 8) {
                                        Image(systemName: tool.systemImage)
                                            .frame(width: 18)
                                        Text(tool.localizedName)
                                    }
                                }

                                Spacer()

                                HStack(spacing: 4) {
                                    Button {
                                        moveTool(at: index, offset: -1)
                                    } label: {
                                        Image(systemName: "chevron.up")
                                            .frame(width: 18, height: 18)
                                    }
                                    .buttonStyle(.borderless)
                                    .controlSize(.small)
                                    .disabled(index == 0)

                                    Button {
                                        moveTool(at: index, offset: 1)
                                    } label: {
                                        Image(systemName: "chevron.down")
                                            .frame(width: 18, height: 18)
                                    }
                                    .buttonStyle(.borderless)
                                    .controlSize(.small)
                                    .disabled(index == orderedTools.count - 1)
                                }
                            }
                        }

                        Text(NSLocalizedString("settings.editor.toolbar.note", comment: ""))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                }
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Label(NSLocalizedString("settings.editor.radial.title", comment: ""), systemImage: "circle.grid.3x3.fill")
                    .font(.headline)
                    .padding(.leading, 2)

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(NSLocalizedString("settings.editor.radial.enabled", comment: ""), isOn: $settings.radialWheelEnabled)

                        Text(NSLocalizedString("settings.editor.radial.description", comment: ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Divider()

                        Group {
                            ForEach(Array(radialTools.enumerated()), id: \.element) { index, tool in
                                HStack(spacing: 8) {
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
                                    .frame(maxWidth: 200, alignment: .leading)

                                    Spacer()

                                    HStack(spacing: 4) {
                                        Button {
                                            moveRadialTool(at: index, offset: -1)
                                        } label: {
                                            Image(systemName: "chevron.up")
                                                .frame(width: 18, height: 18)
                                        }
                                        .buttonStyle(.borderless)
                                        .controlSize(.small)
                                        .disabled(index == 0)

                                        Button {
                                            moveRadialTool(at: index, offset: 1)
                                        } label: {
                                            Image(systemName: "chevron.down")
                                                .frame(width: 18, height: 18)
                                        }
                                        .buttonStyle(.borderless)
                                        .controlSize(.small)
                                        .disabled(index == radialTools.count - 1)

                                        Button {
                                            removeRadialTool(at: index)
                                        } label: {
                                            Image(systemName: "trash")
                                                .frame(width: 18, height: 18)
                                        }
                                        .buttonStyle(.borderless)
                                        .controlSize(.small)
                                        .disabled(radialTools.count <= 1)
                                    }
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
                    .padding(12)
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
    
    private func moveTool(at index: Int, offset: Int) {
        var updated = orderedTools
        let destination = index + offset
        
        guard updated.indices.contains(index), updated.indices.contains(destination) else { return }
        
        updated.swapAt(index, destination)
        settings.updateEditingToolOrder(updated)
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
    }
}

// MARK: - Storage Settings

struct StorageSettingsView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 32) {
            VStack(alignment: .leading, spacing: 8) {
                Label(NSLocalizedString("settings.storage.section_title", comment: ""), systemImage: "externaldrive")
                    .font(.headline)
                    .padding(.leading, 2)

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(NSLocalizedString("settings.storage.save_to_disk", comment: ""), isOn: $settings.saveToFile)
                            .onChange(of: settings.saveToFile) { _, newValue in
                                if newValue {
                                    // ALWAYS require valid bookmark (user-selected folder)
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
                            Divider()
                            HStack {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(.blue)

                                Text(settings.saveFolderPath.replacingOccurrences(of: "/Users/\(NSUserName())", with: "~"))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                Spacer()

                                Button(NSLocalizedString("settings.storage.change_button", comment: "")) {
                                    if let newPath = settings.selectFolder() {
                                        settings.saveFolderPath = newPath
                                    }
                                }
                            }
                            .padding(8)
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(6)

                            HStack {
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
                    .padding(12)
                }
            }
        }
    }
}

// MARK: - Apps Settings

struct AppsSettingsView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 16) {
            GroupBox {
                VStack(spacing: 12) {
                    HStack {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.blue)
                        Text(NSLocalizedString("settings.apps.default_behavior", value: "默认：复制图片到剪贴板", comment: ""))
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }

                    Text(NSLocalizedString("settings.apps.instructions", value: "在下面添加应用，如果需要复制文件路径，请将其设置为“路径”（适用于终端）。", comment: ""))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(12)
            }

            VStack(alignment: .leading, spacing: 8) {
                Label(NSLocalizedString("settings.apps.rules", value: "规则", comment: ""), systemImage: "list.bullet")
                    .font(.headline)
                    .padding(.leading, 2)

                GroupBox {
                    if settings.appOverrides.isEmpty {
                        VStack(spacing: 16) {
                            Image(systemName: "macwindow.badge.plus")
                                .font(.system(size: 48))
                                .foregroundStyle(.secondary.opacity(0.3))

                            Text(NSLocalizedString("settings.apps.empty_title", value: "暂无应用规则", comment: ""))
                                .font(.headline)

                            Text(NSLocalizedString("settings.apps.empty_description", value: "添加应用以改变剪贴板行为。\n终端需要文件路径时使用“路径”。", comment: ""))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, minHeight: 150)
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [5]))
                                .foregroundStyle(.secondary.opacity(0.2))
                        )
                    } else {
                        ForEach($settings.appOverrides) { $override in
                            GroupBox {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(override.appName)
                                            .fontWeight(.medium)
                                        Text(override.bundleIdentifier)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    Picker("", selection: $override.format) {
                                        Text(NSLocalizedString("settings.apps.clipboard.image", value: "图片", comment: "")).tag(ClipboardFormat.image)
                                        Text(NSLocalizedString("settings.apps.clipboard.path", value: "路径", comment: "")).tag(ClipboardFormat.path)
                                    }
                                    .frame(width: 90)
                                    .labelsHidden()

                                    Button(action: {
                                        settings.removeAppOverride(id: override.bundleIdentifier)
                                    }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.gray.opacity(0.5))
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(4)
                            }
                        }
                    }
                }
            }

            Button(action: addApp) {
                Label(NSLocalizedString("settings.apps.add_rule", value: "添加应用规则", comment: ""), systemImage: "plus")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
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
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.gray.opacity(0.15))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                            )
                    )
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

#Preview {
    SettingsView()
        .environmentObject(AppSettings.shared)
}
