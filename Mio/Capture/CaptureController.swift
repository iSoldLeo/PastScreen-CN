//
//  CaptureController.swift
//  Mio
//
//  Module 03's only capture-session owner. It serializes admission, owns the
//  decisive operation/watchdog handles, validates AppKit callback identity and
//  routes every terminal path through one synchronous cleanup.
//

import AppKit
import Foundation
import OSLog

nonisolated private enum FinalizationSource: Sendable {
    case image(CaptureImage)
    case window(descriptor: CaptureWindowDescriptor, cached: CaptureImage?)
}

nonisolated private enum PreparationResult: Sendable {
    case area(FrozenScreens)
    case screens(FrozenScreens)
}

@MainActor
final class CaptureController {
    private enum State {
        case idle
        case active(ActiveSession)
        case stopped
    }

    private struct TimeoutObservation {
        let elapsedMilliseconds: Int64
        let overshootMilliseconds: Int64
    }

    private enum TerminalCause {
        case delivered(DeliveryOutcome)
        case deliveryFailed(DeliveryOutcome)
        case editorOpened
        case cancelled(CaptureCancellationReason)
        case failed
        case timedOut(TimeoutObservation)

        var logCode: String {
            switch self {
            case .delivered: "delivered"
            case .deliveryFailed: "delivery_failed"
            case .editorOpened: "editor_opened"
            case let .cancelled(reason): "cancelled_\(reason.rawValue)"
            case .failed: "failed"
            case .timedOut: "timed_out"
            }
        }
    }

    private struct OperationInvalidation {
        let terminalCode: String
        let timeout: TimeoutObservation?
    }

    private final class OperationToken {
        let sessionID: CaptureSessionID
        let phase: CapturePhase
        var invalidation: OperationInvalidation?

        init(sessionID: CaptureSessionID, phase: CapturePhase) {
            self.sessionID = sessionID
            self.phase = phase
        }
    }

    private final class ActiveSession {
        let id: CaptureSessionID
        let command: CaptureCommand
        let startedAt: ContinuousClock.Instant
        let capturedAt: CaptureTimestamp
        let preferences: CapturePreferencesSnapshot
        let deliveryPolicy: DeliveryPolicy

        var phase: CapturePhase = .preparing
        var phaseStartedAt: ContinuousClock.Instant
        var operationToken: OperationToken?
        var operationTask: Task<Void, Never>?
        var watchdogTask: Task<Void, Never>?
        var frozenScreens: FrozenScreens?

        var areaFrame: FrameApplication {
            command == .captureAdvanced ? .none : resolvedFrameApplication(from: preferences.frame)
        }

        init(
            id: CaptureSessionID,
            command: CaptureCommand,
            startedAt: ContinuousClock.Instant,
            capturedAt: CaptureTimestamp,
            preferences: CapturePreferencesSnapshot
        ) {
            self.id = id
            self.command = command
            self.startedAt = startedAt
            self.capturedAt = capturedAt
            self.preferences = preferences
            self.deliveryPolicy = DeliveryPolicy(preferences: preferences)
            self.phaseStartedAt = startedAt
        }
    }

    private enum TimeoutPolicy {
        static let preparingSeconds: Int64 = 8
        static let finalizingSeconds: Int64 = 20
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.iSoldLeo.Mio",
        category: "capture.session"
    )

    private let pipeline: CapturePipeline
    private let outputDelivery: OutputDeliveryService
    private let imageProcessor: ImageProcessor
    private let selectionPresenter: SelectionPresenter
    private let feedbackPresenter: CaptureFeedbackPresenting
    private let openEditor: @MainActor (
        _ image: CaptureImage,
        _ displayID: CGDirectDisplayID,
        _ preferences: CapturePreferencesSnapshot,
        _ capturedAt: CaptureTimestamp
    ) throws -> Void
    private let capturePreferencesSnapshot: @MainActor () -> CapturePreferencesSnapshot
    private var state: State = .idle

    init(
        pipeline: CapturePipeline,
        imageProcessor: ImageProcessor,
        outputDelivery: OutputDeliveryService,
        selectionPresenter: SelectionPresenter,
        feedbackPresenter: CaptureFeedbackPresenting,
        openEditor: @escaping @MainActor (
            _ image: CaptureImage,
            _ displayID: CGDirectDisplayID,
            _ preferences: CapturePreferencesSnapshot,
            _ capturedAt: CaptureTimestamp
        ) throws -> Void,
        capturePreferencesSnapshot: @escaping @MainActor () -> CapturePreferencesSnapshot
    ) {
        self.pipeline = pipeline
        self.outputDelivery = outputDelivery
        self.imageProcessor = imageProcessor
        self.selectionPresenter = selectionPresenter
        self.feedbackPresenter = feedbackPresenter
        self.openEditor = openEditor
        self.capturePreferencesSnapshot = capturePreferencesSnapshot
    }

    @discardableResult
    func start(_ command: CaptureCommand) -> CaptureStartDisposition {
        switch state {
        case .stopped:
            Self.logger.info("event=session.start.disposition command=\(Self.logCode(command), privacy: .public) result=rejected reason=stopped")
            return .rejected(.stopped)
        case let .active(session):
            Self.logger.info(
                "event=session.start.disposition command=\(Self.logCode(command), privacy: .public) result=rejected reason=busy active_session_id=\(session.id.rawValue.uuidString, privacy: .public) active_phase=\(session.phase.rawValue, privacy: .public)"
            )
            return .rejected(.busy(activeSessionID: session.id, phase: session.phase))
        case .idle:
            break
        }

        let sessionID = CaptureSessionID()
        let session = ActiveSession(
            id: sessionID,
            command: command,
            startedAt: ContinuousClock().now,
            capturedAt: CaptureTimestamp(
                instant: Date(),
                timeZoneIdentifier: TimeZone.current.identifier
            ),
            preferences: capturePreferencesSnapshot()
        )
        state = .active(session)

        Self.logger.info(
            "event=session.start.disposition session_id=\(sessionID.rawValue.uuidString, privacy: .public) command=\(Self.logCode(command), privacy: .public) result=accepted phase=preparing"
        )
        logPhaseBegin(session)
        beginPreparation(session)
        return .accepted(sessionID)
    }

    func stop() {
        switch state {
        case .stopped:
            Self.logger.debug("event=session.stop.ignored reason=already_stopped")
        case .idle:
            state = .stopped
            Self.logger.info("event=session.stopped result=stopped active_session_count_before=0")
        case let .active(session):
            terminate(
                session,
                cause: .cancelled(.applicationStopping),
                transitionToStopped: true
            )
        }
    }

    /// 01-driven cancellation of the in-flight capture from a system lifecycle
    /// source (sleep / user-session resign / display-topology change). Unlike
    /// `stop()` the controller stays usable for the next capture: the active
    /// session terminates to idle, not to `.stopped`. No-op when idle/stopped.
    func cancelActiveSession(reason: CaptureCancellationReason) {
        guard case let .active(session) = state else { return }
        terminate(session, cause: .cancelled(reason))
    }

    isolated deinit {
        guard case let .active(session) = state else { return }
        session.operationToken?.invalidation = OperationInvalidation(
            terminalCode: "deinit_safety",
            timeout: nil
        )
        session.operationTask?.cancel()
        session.watchdogTask?.cancel()
    }

    // MARK: - Preparation

    private func beginPreparation(_ session: ActiveSession) {
        armWatchdog(session, seconds: TimeoutPolicy.preparingSeconds)
        let token = installOperationToken(for: session)
        let pipeline = pipeline
        let command = session.command
        session.operationTask = Task(
            name: "mio.capture-session.operation.\(session.id.rawValue.uuidString).preparing",
            priority: .userInitiated
        ) { @MainActor [weak self] in
            do {
                try Task.checkCancellation()
                let result: PreparationResult = switch command {
                case .captureArea, .captureAdvanced:
                    .area(try await pipeline.captureFrozenScreens(correlationID: token.sessionID.rawValue))
                case .captureFullScreen:
                    .screens(try await pipeline.captureFrozenScreens(correlationID: token.sessionID.rawValue))
                }
                try Task.checkCancellation()
                self?.completePreparation(token: token, result: result)
            } catch {
                self?.completeOperationFailure(token: token, error: error)
            }
        }
    }

    private func completePreparation(token: OperationToken, result: PreparationResult) {
        guard let session = takeCurrentOperation(token) else {
            logIgnored(token: token, kind: "preparation")
            return
        }
        cancelWatchdog(session)

        switch result {
        case let .area(screens):
            presentAreaSelection(session, screens: screens)
        case let .screens(screens):
            presentScreenSelection(session, screens: screens)
        }
    }

    private func presentAreaSelection(_ session: ActiveSession, screens: FrozenScreens) {
        session.frozenScreens = screens
        transition(session, to: .selectingArea, trigger: "area_assets_ready")
        // No watchdog: selection/chooser phases have no deadline (C05-D1 removed).
        let input = AreaSelectionInput(screens: screens)
        let token = installOperationToken(for: session)
        let presenter = selectionPresenter
        let sessionID = session.id
        session.operationTask = Task(
            name: "mio.capture-session.operation.\(session.id.rawValue.uuidString).selecting_area",
            priority: .userInitiated
        ) { @MainActor [weak self] in
            do {
                let decision = try await presenter.selectArea(input: input, sessionID: sessionID)
                self?.completeAreaSelection(token: token, decision: decision)
            } catch {
                self?.completeOperationFailure(token: token, error: error)
            }
        }
    }

    private func presentScreenSelection(
        _ session: ActiveSession,
        screens: FrozenScreens
    ) {
        guard !screens.ordered.isEmpty else {
            terminate(session, cause: .failed)
            return
        }

        if screens.ordered.count == 1, let screen = screens.ordered.first {
            transition(session, to: .finalizing, trigger: "single_screen_ready")
            beginFinalization(
                session,
                source: .image(screen.image),
                displayID: screen.displayID,
                crop: nil,
                frame: .none
            )
            return
        }

        session.frozenScreens = screens
        transition(session, to: .choosingScreen, trigger: "multiple_screens_ready")
        let input = ScreenChoiceInput(screens: screens)
        let token = installOperationToken(for: session)
        let presenter = selectionPresenter
        let sessionID = session.id
        session.operationTask = Task(
            name: "mio.capture-session.operation.\(session.id.rawValue.uuidString).choosing_screen",
            priority: .userInitiated
        ) { @MainActor [weak self] in
            do {
                let decision = try await presenter.chooseScreen(input: input, sessionID: sessionID)
                self?.completeScreenChoice(token: token, decision: decision)
            } catch {
                self?.completeOperationFailure(token: token, error: error)
            }
        }
    }

    // MARK: - Selection decisions (from SelectionPresenter)

    private func completeAreaSelection(token: OperationToken, decision: AreaSelectionDecision) {
        guard let session = takeCurrentOperation(token) else {
            logIgnored(token: token, kind: "area_selection")
            return
        }
        switch decision {
        case let .rectangle(request):
            guard let match = session.frozenScreens?.ordered.first(where: {
                $0.displayID == request.displayID
            }) else {
                terminate(session, cause: .failed)
                return
            }
            transition(session, to: .finalizing, trigger: "rectangle_selected")
            beginFinalization(
                session,
                source: .image(match.image),
                displayID: match.displayID,
                crop: CropInstruction(rectInSourcePoints: request.rectInDisplayPoints),
                frame: session.areaFrame
            )
        case let .window(selection):
            transition(session, to: .finalizing, trigger: "window_selected")
            beginFinalization(
                session,
                source: .window(descriptor: selection.descriptor, cached: nil),
                displayID: selection.descriptor.primaryDisplayID,
                crop: nil,
                frame: session.areaFrame
            )
        case let .cancelled(trigger):
            terminate(session, cause: .cancelled(Self.cancellationReason(for: trigger)))
        }
    }

    private func completeScreenChoice(token: OperationToken, decision: ScreenChoiceDecision) {
        guard let session = takeCurrentOperation(token) else {
            logIgnored(token: token, kind: "screen_choice")
            return
        }
        switch decision {
        case let .selected(displayID):
            guard let image = session.frozenScreens?.ordered.first(where: {
                $0.displayID == displayID
            })?.image else {
                terminate(session, cause: .failed)
                return
            }
            transition(session, to: .finalizing, trigger: "screen_selected")
            beginFinalization(
                session,
                source: .image(image),
                displayID: displayID,
                crop: nil,
                frame: .none
            )
        case let .cancelled(trigger):
            terminate(session, cause: .cancelled(Self.cancellationReason(for: trigger)))
        }
    }

    private static func cancellationReason(for trigger: SelectionCancelTrigger) -> CaptureCancellationReason {
        switch trigger {
        case .user: .userInteraction
        case .focusLost, .presentationInvisible, .unexpectedClose: .selectionPresentationLost
        }
    }

    // MARK: - Finalization

    private func beginFinalization(
        _ session: ActiveSession,
        source: FinalizationSource,
        displayID: CGDirectDisplayID,
        crop: CropInstruction?,
        frame: FrameApplication
    ) {
        releaseFrozenAssets(session)
        armWatchdog(session, seconds: TimeoutPolicy.finalizingSeconds)
        let token = installOperationToken(for: session)
        let command = session.command
        let sessionID = session.id
        let capturedAt = session.capturedAt
        let deliveryPolicy = session.deliveryPolicy
        let pipeline = pipeline
        let imageProcessor = imageProcessor
        let outputDelivery = outputDelivery

        session.operationTask = Task(
            name: "mio.capture-session.operation.\(session.id.rawValue.uuidString).finalizing",
            priority: .userInitiated
        ) { @MainActor [weak self] in
            do {
                try Task.checkCancellation()
                let sourceImage: CaptureImage
                switch source {
                case let .image(image):
                    sourceImage = image
                case let .window(descriptor, cached):
                    sourceImage = if let cached {
                        cached
                    } else {
                        try await pipeline.captureWindowOnDemand(
                            expected: descriptor,
                            correlationID: sessionID.rawValue
                        )
                    }
                }

                try Task.checkCancellation()
                let prepared = try await imageProcessor.prepareImage(
                    ImagePreparationRequest(
                        correlationID: sessionID.rawValue,
                        source: sourceImage,
                        crop: crop,
                        frame: frame
                    )
                )
                try Task.checkCancellation()

                if case .captureAdvanced = command {
                    self?.completeEditorHandoff(
                        token: token,
                        image: prepared,
                        displayID: displayID
                    )
                    return
                }

                let outcome = await outputDelivery.deliver(
                    DeliveryRequest(
                        correlationID: sessionID.rawValue,
                        image: prepared,
                        capturedAt: capturedAt,
                        policy: deliveryPolicy
                    )
                )
                self?.completeDelivery(token: token, outcome: outcome)
            } catch {
                self?.completeOperationFailure(token: token, error: error)
            }
        }
    }

    private func completeEditorHandoff(
        token: OperationToken,
        image: CaptureImage,
        displayID: CGDirectDisplayID
    ) {
        guard let session = takeCurrentOperation(token) else {
            logIgnored(token: token, kind: "editor_handoff")
            return
        }
        cancelWatchdog(session)
        do {
            try openEditor(image, displayID, session.preferences, session.capturedAt)
            terminate(session, cause: .editorOpened)
        } catch {
            // registry stopped（app 正在终止）等 typed open 失败：不谎报 .editorOpened，
            // 按取消终态收敛（app stop 路径，静默）。
            terminate(session, cause: .cancelled(.applicationStopping))
        }
    }

    private func completeDelivery(token: OperationToken, outcome: DeliveryOutcome) {
        guard let session = takeCurrentOperation(token) else {
            logLateDeliveryIfNeeded(token: token, outcome: outcome)
            return
        }
        cancelWatchdog(session)
        switch outcome.completion {
        case .complete, .partial:
            terminate(session, cause: .delivered(outcome))
        case .failed:
            terminate(session, cause: .deliveryFailed(outcome))
        case .cancelled:
            terminate(session, cause: .cancelled(.taskCancellation))
        }
    }

    private func completeOperationFailure(token: OperationToken, error: any Error) {
        guard let session = takeCurrentOperation(token) else {
            logIgnored(token: token, kind: "operation_failure")
            return
        }
        cancelWatchdog(session)
        if error is CancellationError {
            terminate(session, cause: .cancelled(.taskCancellation))
        } else {
            terminate(session, cause: .failed)
        }
    }

    // MARK: - Owned handles and terminal cleanup

    private func installOperationToken(for session: ActiveSession) -> OperationToken {
        precondition(session.operationTask == nil && session.operationToken == nil)
        let token = OperationToken(sessionID: session.id, phase: session.phase)
        session.operationToken = token
        return token
    }

    private func takeCurrentOperation(_ token: OperationToken) -> ActiveSession? {
        guard
            let session = currentSession(phase: token.phase),
            session.id == token.sessionID,
            session.operationToken === token
        else { return nil }
        session.operationToken = nil
        session.operationTask = nil
        return session
    }

    private func armWatchdog(_ session: ActiveSession, seconds: Int64) {
        cancelWatchdog(session)
        let startedAt = ContinuousClock().now
        let sessionID = session.id
        let phase = session.phase
        session.watchdogTask = Task(
            name: "mio.capture-session.watchdog.\(sessionID.rawValue.uuidString).\(phase.rawValue)",
            priority: .utility
        ) { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(seconds))
            } catch {
                return
            }
            self?.watchdogDidFire(
                sessionID: sessionID,
                phase: phase,
                startedAt: startedAt,
                seconds: seconds
            )
        }
    }

    private func watchdogDidFire(
        sessionID: CaptureSessionID,
        phase: CapturePhase,
        startedAt: ContinuousClock.Instant,
        seconds: Int64
    ) {
        guard
            let session = currentSession(phase: phase),
            session.id == sessionID
        else { return }
        session.watchdogTask = nil
        let elapsed = Self.durationMilliseconds(since: startedAt)
        let deadline = seconds * 1_000
        terminate(
            session,
            cause: .timedOut(TimeoutObservation(
                elapsedMilliseconds: elapsed,
                overshootMilliseconds: max(0, elapsed - deadline)
            ))
        )
    }

    private func cancelWatchdog(_ session: ActiveSession) {
        let task = session.watchdogTask
        session.watchdogTask = nil
        task?.cancel()
    }

    private func terminate(
        _ session: ActiveSession,
        cause: TerminalCause,
        transitionToStopped: Bool = false
    ) {
        guard case let .active(current) = state, current === session else {
            Self.logger.debug("event=session.callback.ignored callback=terminal reason=session_mismatch")
            return
        }

        let terminalPhase = session.phase
        let timeoutObservation: TimeoutObservation? = if case let .timedOut(observation) = cause {
            observation
        } else {
            nil
        }
        let cancellationReason: String = if case let .cancelled(reason) = cause {
            reason.rawValue
        } else {
            "none"
        }
        session.operationToken?.invalidation = OperationInvalidation(
            terminalCode: cause.logCode,
            timeout: timeoutObservation
        )

        let operationTask = session.operationTask
        let watchdogTask = session.watchdogTask
        session.operationToken = nil
        session.operationTask = nil
        session.watchdogTask = nil
        releaseFrozenAssets(session)

        operationTask?.cancel()
        watchdogTask?.cancel()
        // Synchronously dismiss the matching presentation (if any) before we
        // open .idle/.stopped; the async cancellation hop is only a fallback.
        selectionPresenter.cancel(sessionID: session.id)

        Self.logger.info(
            "event=session.phase.end session_id=\(session.id.rawValue.uuidString, privacy: .public) phase=\(terminalPhase.rawValue, privacy: .public) result=\(cause.logCode, privacy: .public) duration_ms=\(Self.durationMilliseconds(since: session.phaseStartedAt), privacy: .public) deadline_seconds=\(Self.deadlineSeconds(for: terminalPhase), privacy: .public)"
        )
        Self.logger.info(
            "event=session.terminal session_id=\(session.id.rawValue.uuidString, privacy: .public) command=\(Self.logCode(session.command), privacy: .public) phase=\(terminalPhase.rawValue, privacy: .public) result=\(cause.logCode, privacy: .public) cancellation_reason=\(cancellationReason, privacy: .public) duration_ms=\(Self.durationMilliseconds(since: session.startedAt), privacy: .public) deadline_elapsed_ms=\(timeoutObservation?.elapsedMilliseconds ?? -1, privacy: .public) deadline_overshoot_ms=\(timeoutObservation?.overshootMilliseconds ?? -1, privacy: .public) active_task_count=0 watchdog_count=0 presentation_count=0"
        )
        feedbackPresenter.present(
            feedbackEvent(
                for: cause,
                id: CaptureFeedbackID(rawValue: session.id.rawValue),
                phase: terminalPhase,
                preferences: session.preferences
            )
        )
        state = transitionToStopped ? .stopped : .idle
    }

    // MARK: - Presentation and logging

    private func feedbackEvent(
        for cause: TerminalCause,
        id: CaptureFeedbackID,
        phase: CapturePhase,
        preferences: CapturePreferencesSnapshot
    ) -> CaptureFeedbackEvent {
        switch cause {
        case let .delivered(outcome):
            .delivered(
                id: id,
                source: .directCapture,
                summary: .project(from: outcome),
                soundEnabled: preferences.playSoundOnCapture
            )
        case let .deliveryFailed(outcome):
            .failed(id: id, failure: .delivery(.project(from: outcome)))
        case .editorOpened:
            .editorOpened(id: id, soundEnabled: preferences.playSoundOnCapture)
        case let .cancelled(reason):
            .cancelled(id: id, reason: reason)
        case .failed:
            .failed(id: id, failure: .unknown)
        case .timedOut:
            .timedOut(id: id, phase: phase)
        }
    }

    private func logLateDeliveryIfNeeded(token: OperationToken, outcome: DeliveryOutcome) {
        guard let invalidation = token.invalidation else {
            logIgnored(token: token, kind: "delivery")
            return
        }
        Self.logger.info(
            "event=session.delivery_late session_id=\(token.sessionID.rawValue.uuidString, privacy: .public) correlation_id=\(token.sessionID.rawValue.uuidString, privacy: .public) original_terminal=\(invalidation.terminalCode, privacy: .public) terminal_phase=\(token.phase.rawValue, privacy: .public) file=\(outcome.file.logCode, privacy: .public) clipboard=\(outcome.clipboard.logCode, privacy: .public) completion=\(outcome.completion.rawValue, privacy: .public) deadline_elapsed_ms=\(invalidation.timeout?.elapsedMilliseconds ?? -1, privacy: .public) deadline_overshoot_ms=\(invalidation.timeout?.overshootMilliseconds ?? -1, privacy: .public) state_mutation=false feedback_mutation=false"
        )
    }

    private func logIgnored(token: OperationToken, kind: StaticString) {
        Self.logger.debug(
            "event=session.callback.ignored session_id=\(token.sessionID.rawValue.uuidString, privacy: .public) callback=\(kind, privacy: .public) expected_phase=\(token.phase.rawValue, privacy: .public) reason=stale_or_cancelled"
        )
    }

    private func transition(_ session: ActiveSession, to phase: CapturePhase, trigger: StaticString) {
        let previous = session.phase
        Self.logger.info(
            "event=session.phase.end session_id=\(session.id.rawValue.uuidString, privacy: .public) phase=\(previous.rawValue, privacy: .public) result=transitioned duration_ms=\(Self.durationMilliseconds(since: session.phaseStartedAt), privacy: .public) deadline_seconds=\(Self.deadlineSeconds(for: previous), privacy: .public)"
        )
        session.phase = phase
        session.phaseStartedAt = ContinuousClock().now
        Self.logger.info(
            "event=session.transition session_id=\(session.id.rawValue.uuidString, privacy: .public) from=\(previous.rawValue, privacy: .public) to=\(phase.rawValue, privacy: .public) trigger=\(trigger, privacy: .public) elapsed_ms=\(Self.durationMilliseconds(since: session.startedAt), privacy: .public)"
        )
        logPhaseBegin(session)
    }

    private func logPhaseBegin(_ session: ActiveSession) {
        Self.logger.info(
            "event=session.phase.begin session_id=\(session.id.rawValue.uuidString, privacy: .public) phase=\(session.phase.rawValue, privacy: .public) deadline_seconds=\(Self.deadlineSeconds(for: session.phase), privacy: .public)"
        )
    }

    private func currentSession(phase: CapturePhase) -> ActiveSession? {
        guard case let .active(session) = state, session.phase == phase else { return nil }
        return session
    }

    private func releaseFrozenAssets(_ session: ActiveSession) {
        session.frozenScreens = nil
    }

    private static func logCode(_ command: CaptureCommand) -> String {
        switch command {
        case .captureArea: "area"
        case .captureAdvanced: "advanced"
        case .captureFullScreen: "full_screen"
        }
    }

    private static func deadlineSeconds(for phase: CapturePhase) -> Int64 {
        switch phase {
        case .preparing: TimeoutPolicy.preparingSeconds
        case .finalizing: TimeoutPolicy.finalizingSeconds
        case .selectingArea, .choosingScreen: 0
        }
    }

    private static func durationMilliseconds(since start: ContinuousClock.Instant) -> Int64 {
        let components = start.duration(to: ContinuousClock().now).components
        return components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
    }
}
