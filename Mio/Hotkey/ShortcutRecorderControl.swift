//
//  ShortcutRecorderControl.swift
//  Mio
//
//  The only owner of shortcut-recording NSEvent monitors and window cleanup.
//

import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

nonisolated enum ShortcutRecorderStyle: Sendable {
    case settings
    case onboarding
}

private nonisolated enum ShortcutRecorderNotice: Equatable, Sendable {
    case primaryModifierRequired
    case unsupportedModifierBits
    case duplicate(ShortcutAction)
    case saveFailed
    case monitorInstallationFailed
    case recordingBusy
    case serviceUnavailable
}

@MainActor
private final class ShortcutRecorderController: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var notice: ShortcutRecorderNotice?

    private let action: ShortcutAction
    private let host: ShortcutRecordingHost
    private let ownerID = RecorderOwnerID()
    private let service: GlobalShortcutService

    private weak var attachedWindow: NSWindow?
    private var sessionID: RecordingSessionID?
    private var localMonitor: Any?
    private var windowObservers: [NSObjectProtocol] = []

    init(
        action: ShortcutAction,
        host: ShortcutRecordingHost,
        service: GlobalShortcutService
    ) {
        self.action = action
        self.host = host
        self.service = service
    }

    func windowDidChange(_ newWindow: NSWindow?) {
        let previousWindow = attachedWindow
        attachedWindow = newWindow
        if previousWindow != nil, newWindow == nil, sessionID != nil {
            finish(.viewDetached)
        }
    }

    func toggleRecording() {
        if isRecording {
            finish(.cancelled)
        } else {
            startRecording()
        }
    }

    func disable() {
        notice = nil
        project(service.disable(action: action))
    }

    func retry() {
        notice = nil
        project(service.retryRegistration(action: action))
    }

    isolated deinit {
        removeOwnedUIResources()
        if let sessionID {
            service.endRecording(id: sessionID, reason: .deinitialized)
        }
    }

    private func startRecording() {
        guard localMonitor == nil, sessionID == nil else { return }
        guard let attachedWindow else {
            notice = .serviceUnavailable
            return
        }

        notice = nil
        let outcome = service.beginRecording(
            owner: ownerID,
            host: host,
            onInvalidated: { [weak self] reason in
                self?.invalidateFromService(reason: reason)
            }
        )

        switch outcome {
        case let .started(id):
            sessionID = id
        case .rejected(.recordingBusy):
            notice = .recordingBusy
            return
        case .rejected(.serviceNotStarted):
            notice = .serviceUnavailable
            return
        }

        installWindowObservers(for: attachedWindow)
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard Thread.isMainThread else { return event }
            let keyCode = event.keyCode
            let modifierRawValue = event.modifierFlags.rawValue

            // SAFETY: the runtime guard above proves this synchronous AppKit
            // monitor callback is on the main thread before touching MainActor
            // state or deciding whether the event is consumed.
            let consumed = MainActor.assumeIsolated {
                guard let self, self.sessionID != nil else { return false }
                self.handleKeyDown(
                    keyCode: keyCode,
                    modifierFlags: NSEvent.ModifierFlags(rawValue: modifierRawValue)
                )
                return true
            }
            return consumed ? nil : event
        }

        guard let monitor else {
            finish(.monitorInstallationFailed)
            notice = .monitorInstallationFailed
            return
        }

        localMonitor = monitor
        isRecording = true
    }

    private func handleKeyDown(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) {
        let modifiers = Self.shortcutModifiers(from: modifierFlags)
        if keyCode == UInt16(kVK_Escape), modifiers.isEmpty {
            finish(.cancelled)
            return
        }

        guard let sessionID else { return }
        let candidate = Shortcut(keyCode: keyCode, modifiers: modifiers)
        switch service.update(action: action, candidate: candidate, sessionID: sessionID) {
        case .applied:
            finish(.saved)
        case let .rejectedValidation(failure):
            notice = Self.notice(for: failure)
        case .rejectedStore:
            finish(.saveFailed)
            notice = .saveFailed
        case .rejectedStaleSession, .rejectedServiceNotStarted:
            invalidateFromService(reason: .serviceStopped)
        case .rejectedRecordingActive:
            assertionFailure("The matching recorder session must be allowed to update its action.")
        }
    }

    private func project(_ outcome: ShortcutMutationOutcome) {
        switch outcome {
        case .applied:
            break
        case let .rejectedValidation(failure):
            notice = Self.notice(for: failure)
        case .rejectedStore:
            notice = .saveFailed
        case .rejectedRecordingActive:
            notice = .recordingBusy
        case .rejectedStaleSession, .rejectedServiceNotStarted:
            notice = .serviceUnavailable
        }
    }

    private func finish(_ reason: RecordingEndReason) {
        notice = nil
        guard let sessionID else {
            removeOwnedUIResources()
            isRecording = false
            return
        }

        removeOwnedUIResources()
        service.endRecording(id: sessionID, reason: reason)
        self.sessionID = nil
        isRecording = false
    }

    private func invalidateFromService(reason: RecordingEndReason) {
        guard sessionID != nil else { return }
        removeOwnedUIResources()
        sessionID = nil
        isRecording = false
        notice = nil
        if reason == .serviceStopped {
            notice = .serviceUnavailable
        }
    }

    private func installWindowObservers(for window: NSWindow) {
        removeWindowObservers()
        let center = NotificationCenter.default
        windowObservers.append(center.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard Thread.isMainThread else { return }
            // SAFETY: the observer is explicitly delivered on OperationQueue.main
            // and the runtime guard verifies that contract before MainActor entry.
            MainActor.assumeIsolated {
                self?.finish(.windowResigned)
            }
        })
        windowObservers.append(center.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard Thread.isMainThread else { return }
            // SAFETY: same explicit main-queue contract and runtime proof as above.
            MainActor.assumeIsolated {
                self?.finish(.windowClosed)
            }
        })
    }

    private func removeOwnedUIResources() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        removeWindowObservers()
    }

    private func removeWindowObservers() {
        let center = NotificationCenter.default
        for observer in windowObservers {
            center.removeObserver(observer)
        }
        windowObservers.removeAll()
    }

    private static func shortcutModifiers(
        from flags: NSEvent.ModifierFlags
    ) -> ShortcutModifiers {
        let normalized = flags.intersection(.deviceIndependentFlagsMask)
        var result: ShortcutModifiers = []
        if normalized.contains(.command) { result.insert(.command) }
        if normalized.contains(.option) { result.insert(.option) }
        if normalized.contains(.shift) { result.insert(.shift) }
        if normalized.contains(.control) { result.insert(.control) }
        return result
    }

    private static func notice(
        for failure: ShortcutValidationFailure
    ) -> ShortcutRecorderNotice {
        switch failure {
        case .unsupportedModifierBits: .unsupportedModifierBits
        case .primaryModifierRequired: .primaryModifierRequired
        case let .duplicate(action): .duplicate(action)
        }
    }
}

@MainActor
struct ShortcutRecorderView: View {
    @ObservedObject private var store: ShortcutStore
    @ObservedObject private var service: GlobalShortcutService
    @StateObject private var controller: ShortcutRecorderController

    private let action: ShortcutAction
    private let formatter: ShortcutLabelFormatter
    private let style: ShortcutRecorderStyle

    init(
        action: ShortcutAction,
        host: ShortcutRecordingHost,
        style: ShortcutRecorderStyle,
        store: ShortcutStore,
        service: GlobalShortcutService,
        formatter: ShortcutLabelFormatter
    ) {
        self.action = action
        self.style = style
        self.formatter = formatter
        _store = ObservedObject(wrappedValue: store)
        _service = ObservedObject(wrappedValue: service)
        _controller = StateObject(wrappedValue: ShortcutRecorderController(
            action: action,
            host: host,
            service: service
        ))
    }

    var body: some View {
        VStack(alignment: style == .settings ? .trailing : .center, spacing: 5) {
            HStack(spacing: 8) {
                shortcutLabel
                Button(
                    controller.isRecording
                        ? LocalizedStringKey("common.cancel")
                        : LocalizedStringKey("common.change")
                ) {
                    controller.toggleRecording()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if shouldShowRetry {
                    Button("hotkey.action.retry") {
                        controller.retry()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Button {
                    controller.disable()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .opacity(shouldShowClear ? 1 : 0)
                .disabled(!shouldShowClear)
                .help("settings.hotkey.clear")
            }

            if let statusText {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let noticeText {
                Text(noticeText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .background(ShortcutRecorderWindowProbe { window in
            controller.windowDidChange(window)
        })
    }

    @ViewBuilder
    private var shortcutLabel: some View {
        if controller.isRecording {
            Text("settings.hotkey.press_prompt")
                .foregroundStyle(.secondary)
        } else if let presentation = desiredPresentation {
            Text(presentation.compactLabel)
                .font(.body.monospaced())
                .accessibilityLabel(Text(presentation.accessibilityLabel))
                .help(presentation.accessibilityLabel)
        } else {
            Text("settings.hotkey.unset")
                .foregroundStyle(.secondary)
        }
    }

    private var desiredPresentation: ShortcutPresentation? {
        _ = service.presentationRevision
        guard let shortcut = store.assignments[action].shortcut else { return nil }
        return formatter.presentation(for: shortcut)
    }

    private var actualState: ShortcutRegistrationState {
        service.registrationStates[action] ?? .notStarted
    }

    private var shouldShowRetry: Bool {
        guard !controller.isRecording else { return false }
        if case .failed = actualState { return true }
        return false
    }

    private var shouldShowClear: Bool {
        !controller.isRecording && store.assignments[action].shortcut != nil
    }

    private var statusText: LocalizedStringKey? {
        guard !controller.isRecording else { return nil }
        switch actualState {
        case .notStarted:
            return store.assignments[action].shortcut == nil
                ? nil
                : LocalizedStringKey("hotkey.status.unregistered")
        case .disabled, .registered:
            return nil
        case let .failed(_, failure):
            return failureStatusText(for: failure)
        }
    }

    private var noticeText: LocalizedStringKey? {
        guard let notice = controller.notice else { return nil }
        switch notice {
        case .primaryModifierRequired:
            return "hotkey.error.primary_modifier_required"
        case .unsupportedModifierBits:
            return "hotkey.error.unsupported_modifiers"
        case let .duplicate(action):
            return duplicateMessage(for: action)
        case .saveFailed:
            return "hotkey.error.save_failed"
        case .monitorInstallationFailed:
            return "hotkey.error.monitor_failed"
        case .recordingBusy:
            return "hotkey.error.recording_busy"
        case .serviceUnavailable:
            return "hotkey.error.service_unavailable"
        }
    }

    private func duplicateMessage(for action: ShortcutAction) -> LocalizedStringKey {
        switch action {
        case .windowCapture: "hotkey.error.duplicate.window_capture"
        case .advancedWindowCapture: "hotkey.error.duplicate.advanced_window_capture"
        case .fullScreenCapture: "hotkey.error.duplicate.full_screen_capture"
        }
    }

    private func failureStatusText(
        for failure: ShortcutRegistrationFailure
    ) -> LocalizedStringKey {
        switch failure {
        case let .platform(operation, _):
            switch operation {
            case .installHandler, .removeHandler:
                "hotkey.status.install_handler_failed"
            case .register:
                "hotkey.status.registration_failed"
            case .unregister:
                "hotkey.status.unregistration_failed"
            }
        case .registrationIdentifierExhausted:
            "hotkey.status.internal_resource_failed"
        }
    }
}

@MainActor
private struct ShortcutRecorderWindowProbe: NSViewRepresentable {
    let onWindowChange: @MainActor (NSWindow?) -> Void

    func makeNSView(context: Context) -> ProbeView {
        ProbeView(onWindowChange: onWindowChange)
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.onWindowChange = onWindowChange
    }

    static func dismantleNSView(_ nsView: ProbeView, coordinator: ()) {
        nsView.notifyDetachment()
    }

    @MainActor
    final class ProbeView: NSView {
        var onWindowChange: @MainActor (NSWindow?) -> Void

        init(onWindowChange: @escaping @MainActor (NSWindow?) -> Void) {
            self.onWindowChange = onWindowChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange(window)
        }

        func notifyDetachment() {
            onWindowChange(nil)
        }
    }
}
