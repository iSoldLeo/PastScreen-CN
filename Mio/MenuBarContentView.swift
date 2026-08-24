import AppKit
import SwiftUI

@MainActor
struct MenuBarContentView: View {
    private enum ShortcutProjection {
        case label(ShortcutPresentation)
        case unavailable
        case none
    }

    @Environment(\.openSettings) private var openSettings
    @ObservedObject private var shortcutService: GlobalShortcutService

    private let shortcutFormatter: ShortcutLabelFormatter
    private let submitCapture: @MainActor (CaptureCommand, CommandSource) -> CaptureRoutingDisposition
    private let quit: @MainActor () -> Void

    init(
        shortcutService: GlobalShortcutService,
        shortcutFormatter: ShortcutLabelFormatter,
        submitCapture: @escaping @MainActor (CaptureCommand, CommandSource) -> CaptureRoutingDisposition,
        quit: @escaping @MainActor () -> Void
    ) {
        _shortcutService = ObservedObject(wrappedValue: shortcutService)
        self.shortcutFormatter = shortcutFormatter
        self.submitCapture = submitCapture
        self.quit = quit
    }

    var body: some View {
        captureSection
        Divider()
        utilitySection
    }

    private var captureSection: some View {
        Group {
            captureButton(
                titleKey: "menu.capture_area",
                command: .captureArea,
                action: .windowCapture
            )
            captureButton(
                titleKey: "menu.capture_advanced",
                command: .captureAdvanced,
                action: .advancedWindowCapture
            )
            captureButton(
                titleKey: "menu.capture_fullscreen",
                command: .captureFullScreen,
                action: .fullScreenCapture
            )
        }
    }

    private var utilitySection: some View {
        Group {
            Button(NSLocalizedString("menu.preferences", comment: "")) {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            Button(NSLocalizedString("menu.quit", comment: "")) {
                quit()
            }
        }
    }

    private func captureButton(
        titleKey: String,
        command: CaptureCommand,
        action: ShortcutAction
    ) -> some View {
        Button {
            _ = submitCapture(command, .menu)
        } label: {
            HStack {
                Text(LocalizedStringKey(titleKey))
                Spacer()
                actualShortcutLabel(for: action)
            }
        }
    }

    @ViewBuilder
    private func actualShortcutLabel(for action: ShortcutAction) -> some View {
        switch shortcutProjection(for: action) {
        case let .label(presentation):
            Text(presentation.compactLabel)
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text(presentation.accessibilityLabel))
                .help(presentation.accessibilityLabel)
        case .unavailable:
            Text("hotkey.status.unavailable")
                .foregroundStyle(.secondary)
        case .none:
            EmptyView()
        }
    }

    private func shortcutProjection(for action: ShortcutAction) -> ShortcutProjection {
        _ = shortcutService.presentationRevision
        switch shortcutService.registrationStates[action] ?? .notStarted {
        case let .registered(shortcut):
            return .label(shortcutFormatter.presentation(for: shortcut))
        case .failed:
            return .unavailable
        case .notStarted, .disabled:
            return .none
        }
    }
}
