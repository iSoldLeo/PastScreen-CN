//
//  CaptureFeedback.swift
//  Mio
//
//  Module-08 capture completion feedback: the single injected presenter that
//  turns a settled capture/delivery terminal into a transient, non-blocking
//  menu-bar pill and an optional screenshot sound.
//
//  08 owns the presentation-safe value boundary (`CaptureFeedbackEvent`,
//  `DeliveryOutcomeSummary` and its projection), one pure policy, and one
//  `@MainActor` presenter that owns the status item, the sound and the dismiss
//  task. It never inspects file paths, raw errors or images, and never mutates
//  the module-03 session terminal or the module-07 delivery outcome.
//
//  Permission-recovery action (`M08-04`) is implemented in module 12: the
//  `.permissionDenied` pill is clickable and carries a pure `CaptureFeedbackAction`
//  value. 08 still owns no `NSWorkspace`/URL/opener — on click it calls the
//  01-injected `actionHandler`, which drives module 12's `SystemSettingsOpener`.
//

import AppKit
import OSLog

// MARK: - Presentation identity and source

nonisolated struct CaptureFeedbackID: Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

nonisolated enum DeliveryFeedbackSource: Sendable, Equatable {
    case directCapture
    case editorFinish
}

// MARK: - Presentation-safe delivery summary

/// Stable, path-free failure category. The concrete I/O detail stays in 07's
/// logs under 90's privacy rules; the 08 UI never sees the underlying failure.
nonisolated enum DeliveryFailureCategory: Sendable, Equatable {
    case folderAuthorization
    case fileEncoding
    case fileWrite
    case clipboardWrite
    case unavailable
    case unknown

    init(_ failure: FileDeliveryFailure) {
        switch failure {
        case .pngEncodingFailed:
            self = .fileEncoding
        case .authorization, .authorizationUnavailable, .permissionDenied:
            self = .folderAuthorization
        case .invalidCaptureTimestamp, .directoryCreationFailed, .diskFull,
             .nameAllocationFailed, .temporaryWriteFailed,
             .atomicPublishUnsupported, .atomicPublishFailed:
            self = .fileWrite
        }
    }

    init(_ failure: ClipboardDeliveryFailure) {
        self = .clipboardWrite
    }
}

nonisolated enum FileDeliveryFeedbackState: Sendable, Equatable {
    case notRequested
    case saved
    case failed(DeliveryFailureCategory)
    case cancelledBeforeAttempt
    case cancelledDuringAttempt

    init(_ outcome: FileDeliveryOutcome) {
        switch outcome {
        case .notRequested: self = .notRequested
        case .saved: self = .saved
        case let .failed(failure): self = .failed(DeliveryFailureCategory(failure))
        case .cancelledBeforeAttempt: self = .cancelledBeforeAttempt
        case .cancelledDuringAttempt: self = .cancelledDuringAttempt
        }
    }

    var isSuccessful: Bool {
        if case .saved = self { return true }
        return false
    }
}

nonisolated enum ClipboardDeliveryFeedbackState: Sendable, Equatable {
    case copied
    case failed(DeliveryFailureCategory)
    case cancelledBeforeAttempt

    init(_ outcome: ClipboardDeliveryOutcome) {
        switch outcome {
        case .copied: self = .copied
        case let .failed(failure): self = .failed(DeliveryFailureCategory(failure))
        case .cancelledBeforeAttempt: self = .cancelledBeforeAttempt
        }
    }

    var isSuccessful: Bool {
        if case .copied = self { return true }
        return false
    }
}

/// 08-owned presentation DTO. The initializer is private so a summary can only
/// be built by `project(from:)` from a settled 07 `DeliveryOutcome`; an illegal
/// completion/sink combination is unrepresentable (Review1 F04).
nonisolated struct DeliveryOutcomeSummary: Sendable, Equatable {
    let file: FileDeliveryFeedbackState
    let clipboard: ClipboardDeliveryFeedbackState
    let completion: DeliveryCompletion

    private init(
        file: FileDeliveryFeedbackState,
        clipboard: ClipboardDeliveryFeedbackState,
        completion: DeliveryCompletion
    ) {
        self.file = file
        self.clipboard = clipboard
        self.completion = completion
    }

    static func project(from outcome: DeliveryOutcome) -> DeliveryOutcomeSummary {
        DeliveryOutcomeSummary(
            file: FileDeliveryFeedbackState(outcome.file),
            clipboard: ClipboardDeliveryFeedbackState(outcome.clipboard),
            completion: outcome.completion
        )
    }

    var hasSuccessfulSink: Bool {
        file.isSuccessful || clipboard.isSuccessful
    }
}

// MARK: - Failure and feedback event

nonisolated enum CaptureFailurePresentation: Sendable, Equatable {
    case acquisitionUnavailable
    case selectionUnavailable
    case imagePreparationFailed
    case delivery(DeliveryOutcomeSummary)
    case unknown
}

/// A pure, presentation-independent recovery action carried by a feedback event.
/// 08 never executes it: on click the presenter calls the 01-injected handler,
/// which unpacks the destination and drives module 12's opener (§8.5).
nonisolated enum CaptureFeedbackAction: Sendable, Equatable {
    case openSystemSettings(SystemSettingsDestination)
}

/// Presentation input for module 08. A pure `Sendable` value: no closure, URL,
/// image, path or raw `Error`. `M08-04` permission-recovery cases carry a pure
/// `CaptureFeedbackAction` value (still no closure/URL) that 01 injects a handler
/// for; 08 only presents and calls back on click.
nonisolated enum CaptureFeedbackEvent: Sendable, Equatable {
    case delivered(
        id: CaptureFeedbackID,
        source: DeliveryFeedbackSource,
        summary: DeliveryOutcomeSummary,
        soundEnabled: Bool
    )
    case editorOpened(id: CaptureFeedbackID, soundEnabled: Bool)
    case failed(id: CaptureFeedbackID, failure: CaptureFailurePresentation)
    case timedOut(id: CaptureFeedbackID, phase: CapturePhase)
    case cancelled(id: CaptureFeedbackID, reason: CaptureCancellationReason)
    /// Screen Recording denied: the pill is clickable and fires `action` once.
    case permissionDenied(id: CaptureFeedbackID, action: CaptureFeedbackAction)
    /// A previously offered recovery action failed to run (e.g. opener rejected).
    case actionFailed(id: CaptureFeedbackID, action: CaptureFeedbackAction)

    var id: CaptureFeedbackID {
        switch self {
        case let .delivered(id, _, _, _),
             let .editorOpened(id, _),
             let .failed(id, _),
             let .timedOut(id, _),
             let .cancelled(id, _),
             let .permissionDenied(id, _),
             let .actionFailed(id, _):
            id
        }
    }

    var logCode: String {
        switch self {
        case .delivered: "delivered"
        case .editorOpened: "editor_opened"
        case .failed: "failed"
        case .timedOut: "timed_out"
        case .cancelled: "cancelled"
        case .permissionDenied: "permission_denied"
        case .actionFailed: "action_failed"
        }
    }

    /// The clickable recovery action this event offers, if any. `.actionFailed`
    /// is itself terminal and offers none.
    var recoveryAction: CaptureFeedbackAction? {
        switch self {
        case let .permissionDenied(_, action): action
        case .delivered, .editorOpened, .failed, .timedOut, .cancelled, .actionFailed: nil
        }
    }
}

// MARK: - Pure policy

nonisolated enum CaptureFeedbackStyle: Sendable, Equatable {
    case success
    case warning
    case failure

    var logCode: String {
        switch self {
        case .success: "success"
        case .warning: "warning"
        case .failure: "failure"
        }
    }
}

/// Pure visual descriptor. `messageKey` is a stable string-catalog key
/// (`.public`-safe); the presenter resolves the localized string on MainActor.
nonisolated struct CaptureFeedbackVisual: Sendable, Equatable {
    let messageKey: String
    let style: CaptureFeedbackStyle
    let duration: TimeInterval
}

nonisolated struct CaptureFeedbackDecision: Sendable, Equatable {
    /// A `nil` visual means silent: dismiss any prior pill, show nothing new.
    let visual: CaptureFeedbackVisual?
    let shouldPlaySound: Bool

    static let silent = CaptureFeedbackDecision(visual: nil, shouldPlaySound: false)
}

/// Pure, table-testable mapping from a feedback event to a visual + sound
/// decision. It never touches AppKit, `NSApp`, `UserDefaults` or locale.
nonisolated enum CaptureFeedbackPolicy {
    static let successDuration: TimeInterval = 1.5
    static let noticeDuration: TimeInterval = 3.0

    static func decide(for event: CaptureFeedbackEvent) -> CaptureFeedbackDecision {
        switch event {
        case let .delivered(_, source, summary, soundEnabled):
            decideDelivered(source: source, summary: summary, soundEnabled: soundEnabled)
        case let .editorOpened(_, soundEnabled):
            CaptureFeedbackDecision(visual: nil, shouldPlaySound: soundEnabled)
        case .failed:
            CaptureFeedbackDecision(
                visual: CaptureFeedbackVisual(
                    messageKey: "error.capture_error",
                    style: .failure,
                    duration: noticeDuration
                ),
                shouldPlaySound: false
            )
        case .timedOut:
            CaptureFeedbackDecision(
                visual: CaptureFeedbackVisual(
                    messageKey: "capture.timeout",
                    style: .failure,
                    duration: noticeDuration
                ),
                shouldPlaySound: false
            )
        case let .cancelled(_, reason):
            decideCancelled(reason)
        case .permissionDenied:
            CaptureFeedbackDecision(
                visual: CaptureFeedbackVisual(
                    messageKey: "capture.feedback.permission_denied",
                    style: .failure,
                    duration: noticeDuration
                ),
                shouldPlaySound: false
            )
        case .actionFailed:
            CaptureFeedbackDecision(
                visual: CaptureFeedbackVisual(
                    messageKey: "capture.feedback.open_settings_failed",
                    style: .failure,
                    duration: noticeDuration
                ),
                shouldPlaySound: false
            )
        }
    }

    private static func decideDelivered(
        source: DeliveryFeedbackSource,
        summary: DeliveryOutcomeSummary,
        soundEnabled: Bool
    ) -> CaptureFeedbackDecision {
        // 08 owns the rule that only a direct capture plays the screenshot
        // sound; Editor Finish never re-plays it (Review1 F03 / §14).
        let playSound = source == .directCapture && soundEnabled && summary.hasSuccessfulSink
        switch summary.completion {
        case .cancelled:
            return CaptureFeedbackDecision(visual: nil, shouldPlaySound: playSound)
        case .failed:
            return CaptureFeedbackDecision(
                visual: CaptureFeedbackVisual(
                    messageKey: "error.capture_error",
                    style: .failure,
                    duration: noticeDuration
                ),
                shouldPlaySound: playSound
            )
        case .complete:
            return CaptureFeedbackDecision(
                visual: CaptureFeedbackVisual(
                    messageKey: summary.file.isSuccessful
                        ? "capture.saved_and_copied"
                        : "capture.copied",
                    style: .success,
                    duration: successDuration
                ),
                shouldPlaySound: playSound
            )
        case .partial:
            return CaptureFeedbackDecision(
                visual: CaptureFeedbackVisual(
                    messageKey: summary.file.isSuccessful
                        ? "capture.partial.saved_copy_incomplete"
                        : "capture.partial.copied_save_incomplete",
                    style: .warning,
                    duration: noticeDuration
                ),
                shouldPlaySound: playSound
            )
        }
    }

    private static func decideCancelled(_ reason: CaptureCancellationReason) -> CaptureFeedbackDecision {
        // Exhaustive over the live reasons so a future module-12 reason forces a
        // compile error here instead of silently falling through (Review1 F03).
        switch reason {
        case .userInteraction, .taskCancellation, .applicationStopping, .selectionPresentationLost,
             .systemSuspension, .userSessionResign, .displayEnvironmentChange:
            .silent
        }
    }
}

// MARK: - Presenter

@MainActor
protocol CaptureFeedbackPresenting: AnyObject {
    func present(_ event: CaptureFeedbackEvent)
    func stop()
}

/// The single process-wide feedback presenter. Constructed and owned by
/// `AppServices`; injected into `CaptureController` and the editor windows.
/// Not a `.shared` singleton. Latest-wins visual + sound, no queue.
@MainActor
final class CaptureFeedbackPresenter: CaptureFeedbackPresenting {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.iSoldLeo.Mio",
        category: "capture.feedback"
    )

    private let sound = FeedbackSoundPlayer()
    private var currentPresentationID: CaptureFeedbackID?
    private var pillStatusItem: NSStatusItem?
    private var dismissTask: Task<Void, Never>?
    private var isStopped = false
    /// 01-injected handler, run once when the user clicks a recovery pill.
    private var actionHandler: (@MainActor (CaptureFeedbackAction) -> Void)?
    /// The pending clickable action for the on-screen pill (take-once, ID-gated).
    private var pendingAction: (id: CaptureFeedbackID, action: CaptureFeedbackAction)?
    /// AppKit target for the clickable pill; holds only a MainActor closure that
    /// weakly captures this presenter (no feature back-reference, cycle-free).
    private lazy var actionRelay = FeedbackActionRelay { [weak self] in
        self?.fireActionIfCurrent()
    }

    /// Inject the 01-owned recovery handler (composition root). Cleared on stop.
    func setActionHandler(_ handler: @escaping @MainActor (CaptureFeedbackAction) -> Void) {
        actionHandler = handler
    }

    func present(_ event: CaptureFeedbackEvent) {
        guard !isStopped else { return }

        let id = event.id
        // Duplicate current-ID events are idempotent: never replay sound or
        // rebuild the item for an identity already on screen (Review1 F02).
        if currentPresentationID == id {
            Self.logger.info(
                "event=capture.feedback.present feedback_id=\(id.rawValue.uuidString, privacy: .public) kind=\(event.logCode, privacy: .public) result=duplicate_ignored"
            )
            return
        }
        currentPresentationID = id
        let decision = CaptureFeedbackPolicy.decide(for: event)

        // Every valid event advances the presentation generation: dismiss the
        // previous pill first so a prior "copied" cannot linger into the new
        // terminal, even when the new decision is silent.
        dismissVisual()

        if decision.shouldPlaySound {
            sound.play()
        }
        if let visual = decision.visual {
            show(visual, id: id, action: event.recoveryAction)
        }

        Self.logger.info(
            "event=capture.feedback.present feedback_id=\(id.rawValue.uuidString, privacy: .public) kind=\(event.logCode, privacy: .public) style=\(decision.visual?.style.logCode ?? "silent", privacy: .public) message_key=\(decision.visual?.messageKey ?? "none", privacy: .public) duration_ms=\(Int((decision.visual?.duration ?? 0) * 1000), privacy: .public) sound=\(decision.shouldPlaySound, privacy: .public)"
        )
    }

    func stop() {
        isStopped = true
        currentPresentationID = nil
        actionHandler = nil
        dismissVisual()
        sound.stop()
    }

    private func show(_ visual: CaptureFeedbackVisual, id: CaptureFeedbackID, action: CaptureFeedbackAction?) {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else {
            NSStatusBar.system.removeStatusItem(statusItem)
            Self.logger.notice(
                "event=capture.feedback.present feedback_id=\(id.rawValue.uuidString, privacy: .public) result=status_button_unavailable"
            )
            return
        }

        pillStatusItem = statusItem
        let message = NSLocalizedString(visual.messageKey, comment: "Capture completion feedback")
        switch visual.style {
        case .success:
            button.title = "✓ \(message)"
            button.contentTintColor = .systemGreen
        case .warning:
            button.title = "! \(message)"
            button.contentTintColor = .systemOrange
        case .failure:
            button.title = "✕ \(message)"
            button.contentTintColor = .systemRed
        }
        button.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        button.isBordered = true
        button.bezelStyle = .rounded
        button.focusRingType = .none

        // Recovery pill (M08-04): make the pill clickable and arm a take-once,
        // ID-gated action. The relay holds only a MainActor closure.
        if let action {
            pendingAction = (id: id, action: action)
            button.target = actionRelay
            button.action = #selector(FeedbackActionRelay.fire)
        }

        let duration = visual.duration
        dismissTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(duration))
            } catch {
                return  // cancelled by a replacement or stop()
            }
            self?.dismissIfCurrent(id)
        }
    }

    /// Fired by the pill button: run the pending action at most once, and only
    /// while its pill is still current. Clears the action first (so a double
    /// click cannot run it twice) and detaches the button target/action.
    private func fireActionIfCurrent() {
        guard let pending = pendingAction, pending.id == currentPresentationID else { return }
        pendingAction = nil
        if let button = pillStatusItem?.button {
            button.target = nil
            button.action = nil
        }
        Self.logger.info(
            "event=capture.feedback.action feedback_id=\(pending.id.rawValue.uuidString, privacy: .public) result=fired"
        )
        actionHandler?(pending.action)
    }

    private func dismissIfCurrent(_ id: CaptureFeedbackID) {
        guard currentPresentationID == id else { return }
        currentPresentationID = nil
        dismissVisual()
    }

    private func dismissVisual() {
        pendingAction = nil
        dismissTask?.cancel()
        dismissTask = nil

        guard let item = pillStatusItem else { return }
        // Clear the reference before removing so a re-entrant path never
        // double-removes the same status item.
        pillStatusItem = nil
        NSStatusBar.system.removeStatusItem(item)
    }
}

// MARK: - Recovery action relay

/// Bridges the status-item button's target/action to the presenter's take-once
/// handling. Holds only a `@MainActor` closure (which weakly captures the
/// presenter); it has no back-reference to any feature owner.
@MainActor
private final class FeedbackActionRelay: NSObject {
    private let onFire: @MainActor () -> Void

    init(onFire: @escaping @MainActor () -> Void) {
        self.onFire = onFire
        super.init()
    }

    @objc func fire() {
        onFire()
    }
}

// MARK: - Sound

/// Private composition child of `CaptureFeedbackPresenter`. Single resource,
/// latest-wins/restart, checks `play()` and clears the reference only when the
/// finished sound is still current (Review1 F06/F08). No `Glass` second path.
@MainActor
final class FeedbackSoundPlayer: NSObject, NSSoundDelegate {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.iSoldLeo.Mio",
        category: "capture.feedback"
    )

    private static let systemSoundPath =
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"

    private var current: NSSound?

    func play() {
        // Latest-wins: stop the in-flight sound first. If the platform refuses
        // to stop it, keep the old instance (its completion clears the owner)
        // and suppress this replacement so at most one sound ever plays.
        guard stopCurrent() else {
            Self.logger.notice("event=capture.feedback.sound result=replacement_suppressed_stop_rejected")
            return
        }
        guard let sound = NSSound(contentsOfFile: Self.systemSoundPath, byReference: true) else {
            Self.logger.notice("event=capture.feedback.sound result=load_failed")
            return
        }
        sound.delegate = self
        current = sound
        if !sound.play() {
            sound.delegate = nil
            current = nil
            Self.logger.notice("event=capture.feedback.sound result=play_rejected")
        }
    }

    func stop() {
        _ = stopCurrent()
    }

    /// Stops and releases the current sound. Returns `true` when no in-flight
    /// sound remains (safe to start a new one). A refused stop keeps the owner
    /// reference and delegate so the identity-matched completion can clear it,
    /// and is reported for observability rather than silently ignored.
    @discardableResult
    private func stopCurrent() -> Bool {
        guard let sound = current else { return true }
        guard sound.stop() else {
            Self.logger.notice("event=capture.feedback.sound result=stop_rejected")
            return false
        }
        sound.delegate = nil
        current = nil
        return true
    }

    func sound(_ sound: NSSound, didFinishPlaying finished: Bool) {
        // A stale completion for an already-replaced instance must not drop the
        // newer reference.
        guard current === sound else { return }
        current = nil
        sound.delegate = nil
    }
}
