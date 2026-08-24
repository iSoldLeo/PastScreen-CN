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
//  Shortcut rows consume module 02's shared recorder and never own event
//  monitors, persistence, or Carbon registrations themselves.
//

import SwiftUI
import AppKit

// MARK: - Settings root

struct SettingsView: View {
    @EnvironmentObject var launchAtLogin: LaunchAtLoginController
    @EnvironmentObject var capture: CaptureSettings
    @EnvironmentObject var saveFolderAccess: SaveFolderAccess

    @ObservedObject private var shortcutStore: ShortcutStore
    @ObservedObject private var shortcutService: GlobalShortcutService
    private let shortcutFormatter: ShortcutLabelFormatter
    private let presentOnboarding: @MainActor () -> Void
    @State private var folderSelectionID: SaveFolderSelectionID?

    init(
        shortcutStore: ShortcutStore,
        shortcutService: GlobalShortcutService,
        shortcutFormatter: ShortcutLabelFormatter,
        presentOnboarding: @escaping @MainActor () -> Void
    ) {
        _shortcutStore = ObservedObject(wrappedValue: shortcutStore)
        _shortcutService = ObservedObject(wrappedValue: shortcutService)
        self.shortcutFormatter = shortcutFormatter
        self.presentOnboarding = presentOnboarding
    }

    /// Login Item toggle binding: reads the controller's derived on-state,
    /// writes go through the single-flight async `setEnabled`.
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin.isOn },
            set: { newValue in Task { await launchAtLogin.setEnabled(newValue) } }
        )
    }

    var body: some View {
        Form {
            // MARK: 通用
            Section {
                LabeledContent("settings.hotkey.window_capture") {
                    recorder(for: .windowCapture)
                }
                LabeledContent("settings.hotkey.advanced_window_capture") {
                    recorder(for: .advancedWindowCapture)
                }
                LabeledContent("settings.hotkey.full_screen") {
                    recorder(for: .fullScreenCapture)
                }
                Toggle("settings.launch_at_login", isOn: launchAtLoginBinding)
                    .disabled(launchAtLogin.isChanging)
                if launchAtLogin.showsApprovalAction {
                    Button("settings.launch_at_login.open_settings") {
                        _ = launchAtLogin.openSystemSettings()
                    }
                    .buttonStyle(.link)
                }
                if launchAtLogin.isFailed {
                    Text("settings.launch_at_login.change_failed")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
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
                        text: captureFrameSignatureBinding,
                        prompt: capture.captureFrameCustomText.isEmpty
                            ? Text("settings.frame.signature.placeholder")
                            : nil
                    )
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.tint)
                    .disabled(!capture.captureFrameEnabled)
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
                .disabled(folderSelectionDisabled)

                if let notice = folderSelectionNotice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // 只在真的会写盘时才有意义——saveToFile 关掉时截图只进剪贴板，
                // 归档开关无处施力，disable 掉比留着可点更诚实。
                Toggle("settings.storage.organize_by_month", isOn: $capture.organizeByMonth)
                    .disabled(!capture.saveToFile)
                    .help("settings.storage.organize_by_month.help")
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
        if let operationID = saveFolderAccess.chooseFolder(source: .settings) {
            folderSelectionID = operationID
        }
    }

    private func showOnboarding() {
        NSApp.activate(ignoringOtherApps: true)
        presentOnboarding()
    }

    private func recorder(for action: ShortcutAction) -> some View {
        ShortcutRecorderView(
            action: action,
            host: .settings,
            style: .settings,
            store: shortcutStore,
            service: shortcutService,
            formatter: shortcutFormatter
        )
    }

    // MARK: Derived

    private var folderDisplayName: String {
        switch saveFolderAccess.state {
        case let .ready(displayName):
            displayName
        case .restoring:
            NSLocalizedString("settings.storage.folder_restoring", comment: "Restoring save folder access")
        case .selecting:
            NSLocalizedString("settings.storage.folder_selecting", comment: "Selecting a save folder")
        case .needsSelection:
            NSLocalizedString("settings.storage.folder_reselect", comment: "Save folder must be selected again")
        case .notSelected:
            NSLocalizedString("settings.storage.folder_placeholder", comment: "Storage row label when no folder is chosen yet")
        case .stopped:
            NSLocalizedString("settings.storage.folder_unavailable", comment: "Save folder service is unavailable")
        }
    }

    private var folderSelectionDisabled: Bool {
        switch saveFolderAccess.state {
        case .selecting, .stopped:
            true
        case .notSelected, .restoring, .ready, .needsSelection:
            false
        }
    }

    private var folderSelectionNotice: LocalizedStringKey? {
        guard
            let completion = saveFolderAccess.selectionCompletion,
            completion.id == folderSelectionID,
            completion.source == .settings,
            case let .failed(_, retainedPrevious) = completion.result
        else {
            return nil
        }
        return retainedPrevious
            ? "settings.storage.selection_failed_retained"
            : "settings.storage.selection_failed"
    }

    private var captureFrameSignatureBinding: Binding<String> {
        Binding(
            get: { capture.captureFrameCustomText },
            set: { capture.setCaptureFrameCustomText($0) }
        )
    }

    private var versionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
}
