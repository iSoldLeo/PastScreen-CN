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

    enum SettingsTab: String, CaseIterable {
        case general = "General"
        case capture = "Capture"
        case storage = "Storage"
        case apps = "Apps"

        var icon: String {
            switch self {
            case .general: return "gear"
            case .capture: return "camera.fill"
            case .storage: return "folder.fill"
            case .apps: return "macwindow"
            }
        }

        var color: Color {
            switch self {
            case .general: return .gray
            case .capture: return .red
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
                    Text(selectedTab.rawValue)
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

                Text(tab.rawValue)
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
                Label("Options", systemImage: "gearshape")
                    .font(.headline)
                    .padding(.leading, 2)

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Launch at Login", isOn: $settings.launchAtLogin)
                        Divider()
                        Toggle("Show in Dock", isOn: $settings.showInDock)
                        Divider()
                        Toggle("Play capture sound", isOn: $settings.playSoundOnCapture)
                    }
                    .padding(12)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Help", systemImage: "questionmark.circle")
                    .font(.headline)
                    .padding(.leading, 2)

                GroupBox {
                    HStack {
                        Text("Need help getting started?")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Show Tutorial") {
                            OnboardingManager.shared.show()
                        }
                    }
                    .padding(12)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Privacy", systemImage: "hand.raised.fill")
                    .font(.headline)
                    .padding(.leading, 2)

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Your Privacy Matters")
                                    .font(.subheadline)
                                    .fontWeight(.medium)

                                Text("PastScreen collects zero data. Everything stays on your Mac.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }

                        Divider()

                        HStack {
                            Text("• No analytics or tracking\n• No cloud uploads\n• No third-party services\n• Local-only operation")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Spacer()

                            Button("View Full Policy") {
                                if let url = URL(string: "https://github.com/augiefra/PastScreen/blob/main/PRIVACY.md") {
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
                Label("Format", systemImage: "photo")
                    .font(.headline)
                    .padding(.leading, 2)

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Image Format", selection: $settings.imageFormat) {
                            Text("PNG (Lossless)").tag("png")
                            Text("JPEG (Compressed)").tag("jpeg")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        HStack {
                            Text("Format:")
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
                Label("Shortcuts", systemImage: "keyboard")
                    .font(.headline)
                    .padding(.leading, 2)

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Enable global hotkey", isOn: $settings.globalHotkeyEnabled)

                        if settings.globalHotkeyEnabled {
                            Divider()
                            HStack {
                                Text("Capture Area")
                                Spacer()
                                HotKeyRecorderView(hotkey: $settings.globalHotkey)
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
    }
}

// MARK: - Storage Settings

struct StorageSettingsView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 32) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Destination", systemImage: "externaldrive")
                    .font(.headline)
                    .padding(.leading, 2)

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Save to Disk", isOn: $settings.saveToFile)
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

                                Button("Change...") {
                                    if let newPath = settings.selectFolder() {
                                        settings.saveFolderPath = newPath
                                    }
                                }
                            }
                            .padding(8)
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(6)

                            HStack {
                                Button("Open Folder") {
                                    NSWorkspace.shared.open(URL(fileURLWithPath: settings.saveFolderPath))
                                }

                                Spacer()

                                Button("Clear Folder") {
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
                        Text("Default: Image is copied to clipboard")
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }

                    Text("Add an app below and set it to **Path** if you want the file path copied instead (useful for terminals).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(12)
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Overrides", systemImage: "list.bullet")
                    .font(.headline)
                    .padding(.leading, 2)

                GroupBox {
                    if settings.appOverrides.isEmpty {
                        VStack(spacing: 16) {
                            Image(systemName: "macwindow.badge.plus")
                                .font(.system(size: 48))
                                .foregroundStyle(.secondary.opacity(0.3))

                            Text("No application rules")
                                .font(.headline)

                            Text("Add apps to change clipboard behavior.\nUse 'Path' for terminals that need the file path.")
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
                                        Text("Image").tag(ClipboardFormat.image)
                                        Text("Path").tag(ClipboardFormat.path)
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
                Label("Add Application Rule", systemImage: "plus")
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
        panel.prompt = "Select"
        panel.message = "Select an application"

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
                Text("Press keys...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                KeyboardShortcutView(keys: hotkey.symbolDisplayParts)
            }

            Button(isRecording ? "Cancel" : "Change") {
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
