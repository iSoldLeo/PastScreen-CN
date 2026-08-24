//
//  AppServices.swift
//  Mio
//
//  The process-lifetime composition root. During the module-by-module
//  migration it is also the explicit inventory for legacy dependencies;
//  each owning module replaces its slot in place rather than adding a second
//  container or compatibility route.
//

import Foundation
import AppKit
import OSLog

nonisolated enum AppStopReason: Sendable {
    case userQuit
    case applicationTermination
    case duplicateInstance(runningInstanceCount: Int)

    var logValue: String {
        switch self {
        case .userQuit: "user_quit"
        case .applicationTermination: "application_termination"
        case .duplicateInstance: "duplicate_instance"
        }
    }
}

@MainActor
final class AppServices {
    private enum Lifecycle {
        case constructed
        case started
        case stopped
    }

    private enum PrewarmPhase {
        case scheduled
        case started
    }

    private struct PrewarmOperation {
        let id: UUID
        let scheduledAt: ContinuousClock.Instant
        var phase: PrewarmPhase
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.iSoldLeo.Mio",
        category: "App.Lifecycle"
    )

    // Module 10 direct slots.
    let captureSettings: CaptureSettings
    let saveFolderAccess: SaveFolderAccess
    /// Module 12: SMAppService-backed Login Item controller — the single source
    /// of truth for launch-at-login (replaced the old GeneralSettings/UserDefaults Bool).
    let launchAtLoginController: LaunchAtLoginController
    let captureCommandRouter: CaptureCommandRouter
    let shortcutStore: ShortcutStore
    let globalShortcutService: GlobalShortcutService
    let shortcutFormatter: ShortcutLabelFormatter

    private let permissionManager: PermissionManager
    private let captureController: CaptureController
    private let onboardingPresenter: OnboardingPresenter
    private let editorWindows: EditorWindowRegistry
    private let imageProcessor: ImageProcessor
    private let capturePipeline: CapturePipeline
    private let outputDelivery: OutputDeliveryService
    private let feedbackPresenter: CaptureFeedbackPresenter
    private let systemLifecycleMonitor: SystemLifecycleMonitor
    private var displayChangeObserver: NSObjectProtocol?

    private let constructedAt = ContinuousClock().now
    private var startedAt: ContinuousClock.Instant?
    private var lifecycle: Lifecycle = .constructed
    private var prewarmOperation: PrewarmOperation?
    private var prewarmTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        let captureSettings = CaptureSettings(defaults: defaults)
        let saveFolderAccess = SaveFolderAccess(defaults: defaults)
        // Single System Settings opener — the only owner of every System Settings
        // navigation (Screen Recording deep-link + Login Items panel).
        let systemSettingsOpener = SystemSettingsOpener()
        let launchAtLoginController = LaunchAtLoginController(settingsOpener: systemSettingsOpener)
        let permissionManager = PermissionManager()
        let shortcutStore = ShortcutStore(defaults: .standard)
        let globalShortcutService = GlobalShortcutService(store: shortcutStore)
        let shortcutFormatter = ShortcutLabelFormatter()
        let frameResources = FrameResourceLoader.load()
        let imageProcessor = ImageProcessor(frameResources: frameResources)
        // Module 04 has one process-wide owner. It budgets prewarm and user
        // capture together instead of hiding concurrent SCK work in two actors.
        let capturePipeline = CapturePipeline()
        let fileOutput = FileOutputService(saveFolderAccess: saveFolderAccess)
        let clipboardOutput = ClipboardOutputService()
        let outputDelivery = OutputDeliveryService(
            fileOutput: fileOutput,
            clipboardOutput: clipboardOutput
        )
        let feedbackPresenter = CaptureFeedbackPresenter()
        // 01 (composition root) owns the recovery handler: unpack the pure
        // action, drive module 12's opener, and on failure feed back an
        // .actionFailed pill. 08 never touches NSWorkspace. Weak presenter
        // capture keeps the stored closure cycle-free.
        feedbackPresenter.setActionHandler { [weak feedbackPresenter] action in
            switch action {
            case .openSystemSettings(let destination):
                if case .failure = systemSettingsOpener.open(destination) {
                    feedbackPresenter?.present(
                        .actionFailed(id: CaptureFeedbackID(), action: action)
                    )
                }
            }
        }
        let editorCompositeRenderer = EditorCompositeRenderer()
        let editorWindows = EditorWindowRegistry(
            imageProcessor: imageProcessor,
            outputDelivery: outputDelivery,
            feedbackPresenter: feedbackPresenter,
            compositeRenderer: editorCompositeRenderer
        )
        let selectionPresenter = SelectionPresenter()
        let captureController = CaptureController(
            pipeline: capturePipeline,
            imageProcessor: imageProcessor,
            outputDelivery: outputDelivery,
            selectionPresenter: selectionPresenter,
            feedbackPresenter: feedbackPresenter,
            openEditor: { [editorWindows] image, displayID, preferences, capturedAt in
                try editorWindows.open(EditorInput(
                    image: image,
                    displayID: displayID,
                    framePreference: preferences.frame,
                    deliveryPolicy: DeliveryPolicy(preferences: preferences),
                    capturedAt: capturedAt
                ))
            },
            capturePreferencesSnapshot: { [captureSettings] in
                captureSettings.snapshot()
            }
        )
        let onboardingPresenter = OnboardingPresenter(
            imageProcessor: imageProcessor,
            permissionManager: permissionManager,
            openScreenRecordingSettings: { [systemSettingsOpener] in
                systemSettingsOpener.open(.screenRecording)
            }
        )
        let systemLifecycleMonitor = SystemLifecycleMonitor()

        self.captureSettings = captureSettings
        self.saveFolderAccess = saveFolderAccess
        self.launchAtLoginController = launchAtLoginController
        self.permissionManager = permissionManager
        self.shortcutStore = shortcutStore
        self.globalShortcutService = globalShortcutService
        self.shortcutFormatter = shortcutFormatter
        self.captureController = captureController
        self.onboardingPresenter = onboardingPresenter
        self.editorWindows = editorWindows
        self.imageProcessor = imageProcessor
        self.capturePipeline = capturePipeline
        self.outputDelivery = outputDelivery
        self.feedbackPresenter = feedbackPresenter
        self.systemLifecycleMonitor = systemLifecycleMonitor
        self.captureCommandRouter = CaptureCommandRouter(
            permissionManager: permissionManager,
            feedbackPresenter: feedbackPresenter,
            startCapture: { [captureController] command in
                captureController.start(command)
            }
        )

        let buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        Self.logger.info(
            "event=app.lifecycle.constructed result=constructed build_version=\(buildVersion, privacy: .public) process_id=\(ProcessInfo.processInfo.processIdentifier, privacy: .public)"
        )
    }

    func start() {
        switch lifecycle {
        case .constructed:
            lifecycle = .started
            startedAt = ContinuousClock().now
        case .started:
            Self.logger.debug("event=app.lifecycle.start_ignored reason=already_started")
            return
        case .stopped:
            Self.logger.error("event=app.lifecycle.start_rejected reason=stopped")
            return
        }

        saveFolderAccess.start()
        captureCommandRouter.start()

        let router = captureCommandRouter
        globalShortcutService.start { [weak router] action in
            let command = CaptureCommand(shortcutAction: action)
            _ = router?.submit(command, source: .globalShortcut)
        }

        startSystemLifecycleObservers()

        startPrewarm()

        if OnboardingPresenter.shouldShowOnLaunch {
            showOnboarding()
        }

        Self.logger.info(
            "event=app.lifecycle.started reason=application_launch result=started duration_ms=\(Self.durationMilliseconds(since: self.constructedAt), privacy: .public) command_pending_count=\(self.captureCommandRouter.hasPendingCommand ? 1 : 0, privacy: .public) prewarm_pending_count=\(self.prewarmOperation == nil ? 0 : 1, privacy: .public)"
        )
    }

    func didBecomeActive() {
        guard lifecycle == .started else {
            Self.logger.debug("event=app.lifecycle.active_ignored reason=not_started_or_stopped")
            return
        }

        let lifetimeStart = startedAt ?? constructedAt
        Self.logger.info(
            "event=app.lifecycle.active reason=application_did_become_active result=active duration_ms=\(Self.durationMilliseconds(since: lifetimeStart), privacy: .public) command_pending_count=\(self.captureCommandRouter.hasPendingCommand ? 1 : 0, privacy: .public) prewarm_pending_count=\(self.prewarmOperation == nil ? 0 : 1, privacy: .public)"
        )

        // M12-05: app 重新 active 时只读刷新系统真相（Login Item + Screen Recording
        // 权限），不改 desired state、不请求权限。
        launchAtLoginController.refresh()
        permissionManager.refreshScreenCaptureDecision()
    }

    // MARK: - System lifecycle (M12-03)

    private func startSystemLifecycleObservers() {
        systemLifecycleMonitor.start { [weak self] event in
            self?.handleSystemLifecycle(event)
        }
        // Display-topology change is an NSApplication input (not a workspace
        // event, §8.4): route it to the same 03 cancel entry.
        displayChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard Thread.isMainThread else { return }
            // SAFETY: posted on OperationQueue.main; runtime guard before MainActor entry.
            MainActor.assumeIsolated {
                self?.captureController.cancelActiveSession(reason: .displayEnvironmentChange)
            }
        }
    }

    private func stopSystemLifecycleObservers() {
        systemLifecycleMonitor.stop()
        if let observer = displayChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            displayChangeObserver = nil
        }
    }

    /// 01 orchestration of system lifecycle events (§8.5): wake / session-active
    /// only reconcile 02 (never replay a capture) and refresh Login Item truth;
    /// sleep / session-resign cancel the in-flight capture via 03's single input.
    private func handleSystemLifecycle(_ event: SystemLifecycleEvent) {
        switch event {
        case .willSleep:
            captureController.cancelActiveSession(reason: .systemSuspension)
        case .sessionDidResignActive:
            captureController.cancelActiveSession(reason: .userSessionResign)
        case .didWake:
            logShortcutReconcile(.systemWake, globalShortcutService.reconcile(reason: .systemWake))
            launchAtLoginController.refresh()
            permissionManager.refreshScreenCaptureDecision()
        case .sessionDidBecomeActive:
            logShortcutReconcile(
                .sessionBecameActive,
                globalShortcutService.reconcile(reason: .sessionBecameActive)
            )
            launchAtLoginController.refresh()
            permissionManager.refreshScreenCaptureDecision()
        }
    }

    private func logShortcutReconcile(
        _ reason: ShortcutReconcileReason,
        _ outcome: ShortcutReconcileOutcome
    ) {
        switch outcome {
        case .healthy:
            Self.logger.info(
                "event=app.shortcut_reconcile reason=\(reason.rawValue, privacy: .public) result=healthy"
            )
        case let .degraded(failedActions):
            Self.logger.notice(
                "event=app.shortcut_reconcile reason=\(reason.rawValue, privacy: .public) result=degraded failed_count=\(failedActions.count, privacy: .public)"
            )
        case .failed:
            Self.logger.error(
                "event=app.shortcut_reconcile reason=\(reason.rawValue, privacy: .public) result=failed"
            )
        case .serviceStopped:
            Self.logger.info(
                "event=app.shortcut_reconcile reason=\(reason.rawValue, privacy: .public) result=service_stopped"
            )
        }
    }

    func stop(reason: AppStopReason) {
        guard lifecycle != .stopped else {
            Self.logger.debug(
                "event=app.lifecycle.stop_ignored requested_reason=\(reason.logValue, privacy: .public) reason=already_stopped"
            )
            return
        }

        let commandPendingCount = captureCommandRouter.hasPendingCommand ? 1 : 0
        let prewarmPendingCount = prewarmOperation == nil ? 0 : 1

        if case let .duplicateInstance(runningInstanceCount) = reason {
            Self.logger.notice(
                "event=app.lifecycle.duplicate result=detected running_instance_count=\(runningInstanceCount, privacy: .public) decision=terminate_current_process"
            )
        }

        lifecycle = .stopped
        captureCommandRouter.stop()
        captureController.stop()
        feedbackPresenter.stop()
        editorWindows.stop(reason: reason)
        stopSystemLifecycleObservers()

        let operation = prewarmOperation
        prewarmOperation = nil
        let task = prewarmTask
        prewarmTask = nil

        if let operation {
            logPrewarmTerminal(operation, stopReason: reason)
        }
        task?.cancel()

        let shortcutStopOutcome = globalShortcutService.stop()
        logShortcutStopOutcome(shortcutStopOutcome)
        onboardingPresenter.stop()
        saveFolderAccess.stop()

        let lifetimeStart = startedAt ?? constructedAt
        Self.logger.info(
            "event=app.lifecycle.stopped reason=\(reason.logValue, privacy: .public) result=stopped duration_ms=\(Self.durationMilliseconds(since: lifetimeStart), privacy: .public) command_pending_count_before=\(commandPendingCount, privacy: .public) prewarm_pending_count_before=\(prewarmPendingCount, privacy: .public) command_pending_count_after=0 prewarm_pending_count_after=0"
        )
    }

    isolated deinit {
        prewarmTask?.cancel()
    }

    func showOnboarding() {
        onboardingPresenter.show(
            shortcutStore: shortcutStore,
            shortcutService: globalShortcutService,
            shortcutFormatter: shortcutFormatter,
            captureSettings: captureSettings,
            saveFolderAccess: saveFolderAccess
        )
    }

    private func startPrewarm() {
        let operationID = UUID()
        let operation = PrewarmOperation(
            id: operationID,
            scheduledAt: ContinuousClock().now,
            phase: .scheduled
        )
        prewarmOperation = operation

        let capturePipeline = capturePipeline
        prewarmTask = Task(
            name: "mio.prewarm.\(operationID.uuidString)",
            priority: .utility
        ) { [weak self] in
            guard !Task.isCancelled else {
                self?.recordPrewarmStaleResult(operationID: operationID, phase: "entry")
                return
            }
            guard self?.beginPrewarm(operationID: operationID) == true else { return }

            do {
                let outcome = try await capturePipeline.prewarm(correlationID: operationID)
                guard !Task.isCancelled else {
                    self?.recordPrewarmStaleResult(operationID: operationID, phase: "completion")
                    return
                }
                self?.finishPrewarm(operationID: operationID, outcome: outcome)
            } catch is CancellationError {
                self?.recordPrewarmStaleResult(operationID: operationID, phase: "cancelled")
            } catch let error as CaptureAcquisitionError {
                guard !Task.isCancelled else {
                    self?.recordPrewarmStaleResult(operationID: operationID, phase: "failed_after_cancel")
                    return
                }
                self?.failPrewarm(operationID: operationID, error: error)
            } catch {
                guard !Task.isCancelled else {
                    self?.recordPrewarmStaleResult(operationID: operationID, phase: "failed_after_cancel")
                    return
                }
                self?.failPrewarm(
                    operationID: operationID,
                    error: .platformFailure(code: (error as NSError).code)
                )
            }
        }

        Self.logger.info(
            "event=app.prewarm.scheduled correlation_id=\(operationID.uuidString, privacy: .public) operation_id=\(operationID.uuidString, privacy: .public) result=scheduled"
        )
    }

    private func beginPrewarm(operationID: UUID) -> Bool {
        guard
            !Task.isCancelled,
            lifecycle == .started,
            var operation = prewarmOperation,
            operation.id == operationID
        else {
            recordPrewarmStaleResult(operationID: operationID, phase: "entry_gate")
            return false
        }

        operation.phase = .started
        prewarmOperation = operation
        Self.logger.info(
            "event=app.prewarm.started correlation_id=\(operationID.uuidString, privacy: .public) operation_id=\(operationID.uuidString, privacy: .public) result=started"
        )
        return true
    }

    private func finishPrewarm(operationID: UUID, outcome: PrewarmOutcome) {
        guard
            !Task.isCancelled,
            lifecycle == .started,
            let operation = prewarmOperation,
            operation.id == operationID
        else {
            recordPrewarmStaleResult(operationID: operationID, phase: "completion_gate")
            return
        }

        prewarmOperation = nil
        prewarmTask = nil
        let outcomeValue = switch outcome {
        case .completed: "completed"
        case .skippedForActiveCapture: "skipped_active_capture"
        }
        Self.logger.info(
            "event=app.prewarm.completed correlation_id=\(operationID.uuidString, privacy: .public) operation_id=\(operationID.uuidString, privacy: .public) result=completed duration_ms=\(Self.durationMilliseconds(since: operation.scheduledAt), privacy: .public) outcome=\(outcomeValue, privacy: .public)"
        )
    }

    private func failPrewarm(operationID: UUID, error: CaptureAcquisitionError) {
        guard
            lifecycle == .started,
            let operation = prewarmOperation,
            operation.id == operationID
        else {
            recordPrewarmStaleResult(operationID: operationID, phase: "failure_gate")
            return
        }

        prewarmOperation = nil
        prewarmTask = nil
        Self.logger.info(
            "event=app.prewarm.failed correlation_id=\(operationID.uuidString, privacy: .public) operation_id=\(operationID.uuidString, privacy: .public) result=failed duration_ms=\(Self.durationMilliseconds(since: operation.scheduledAt), privacy: .public) error_category=\(error.stableLogCode, privacy: .public)"
        )
    }

    private func logPrewarmTerminal(_ operation: PrewarmOperation, stopReason: AppStopReason) {
        let duration = Self.durationMilliseconds(since: operation.scheduledAt)
        switch operation.phase {
        case .scheduled:
            Self.logger.info(
                "event=app.prewarm.invalidated correlation_id=\(operation.id.uuidString, privacy: .public) operation_id=\(operation.id.uuidString, privacy: .public) result=invalidated reason=\(stopReason.logValue, privacy: .public) duration_ms=\(duration, privacy: .public)"
            )
        case .started:
            Self.logger.info(
                "event=app.prewarm.cancelled correlation_id=\(operation.id.uuidString, privacy: .public) operation_id=\(operation.id.uuidString, privacy: .public) result=cancelled reason=\(stopReason.logValue, privacy: .public) duration_ms=\(duration, privacy: .public)"
            )
        }
    }

    private func recordPrewarmStaleResult(operationID: UUID, phase: StaticString) {
        Self.logger.debug(
            "event=app.prewarm.stale_result_dropped correlation_id=\(operationID.uuidString, privacy: .public) operation_id=\(operationID.uuidString, privacy: .public) phase=\(phase, privacy: .public) reason=cancelled_or_invalidated"
        )
    }

    private static func durationMilliseconds(since start: ContinuousClock.Instant) -> Int64 {
        let components = start.duration(to: ContinuousClock().now).components
        return components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
    }

    private func logShortcutStopOutcome(_ outcome: ShortcutStopOutcome) {
        switch outcome {
        case .stoppedCleanly:
            Self.logger.info("event=app.shortcut_stop result=stopped_cleanly")
        case let .cleanupFailed(residualCount, handlerRetained, failures):
            Self.logger.error(
                "event=app.shortcut_stop result=cleanup_failed residual_count=\(residualCount, privacy: .public) handler_retained=\(handlerRetained, privacy: .public) failure_count=\(failures.count, privacy: .public)"
            )
        }
    }
}

private extension CaptureCommand {
    init(shortcutAction: ShortcutAction) {
        switch shortcutAction {
        case .windowCapture:
            self = .captureArea
        case .advancedWindowCapture:
            self = .captureAdvanced
        case .fullScreenCapture:
            self = .captureFullScreen
        }
    }
}
