//
//  CaptureCommandRouter.swift
//  Mio
//
//  The single App-layer route shared by menu and global-shortcut capture
//  commands. Permission is a module-12 typed `PermissionDecision` (a denial maps
//  to an 08 feedback action); module 03 returns a typed capture admission result
//  instead of treating closure invocation as success.
//

import Foundation
import OSLog

nonisolated enum CaptureCommand: Sendable {
    case captureArea
    case captureAdvanced
    case captureFullScreen

    fileprivate var logValue: String {
        switch self {
        case .captureArea: "area"
        case .captureAdvanced: "advanced"
        case .captureFullScreen: "full_screen"
        }
    }
}

nonisolated enum CommandSource: Sendable {
    case menu
    case globalShortcut

    fileprivate var logValue: String {
        switch self {
        case .menu: "menu"
        case .globalShortcut: "global_shortcut"
        }
    }
}

nonisolated struct CaptureCommandID: Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

nonisolated enum CaptureRoutingRejection: Equatable, Sendable {
    case notStarted
    case stopped
    case routingBusy(activeCommandID: CaptureCommandID)
}

nonisolated enum CaptureRoutingDisposition: Equatable, Sendable {
    case routingStarted(commandID: CaptureCommandID)
    case rejected(commandID: CaptureCommandID, reason: CaptureRoutingRejection)
}

@MainActor
final class CaptureCommandRouter {
    private enum Lifecycle {
        case constructed
        case started
        case stopped
    }

    private struct PendingRoute {
        let commandID: CaptureCommandID
        let command: CaptureCommand
        let source: CommandSource
        let acceptedAt: ContinuousClock.Instant
        var permissionStartedAt: ContinuousClock.Instant?
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.iSoldLeo.Mio",
        category: "App.Command"
    )

    private let permissionManager: PermissionManager
    private let feedbackPresenter: CaptureFeedbackPresenting
    private let startCapture: @MainActor (CaptureCommand) -> CaptureStartDisposition

    private var lifecycle: Lifecycle = .constructed
    private var pendingRoute: PendingRoute?
    private var pendingTask: Task<Void, Never>?

    var hasPendingCommand: Bool {
        pendingRoute != nil
    }

    init(
        permissionManager: PermissionManager,
        feedbackPresenter: CaptureFeedbackPresenting,
        startCapture: @escaping @MainActor (CaptureCommand) -> CaptureStartDisposition
    ) {
        self.permissionManager = permissionManager
        self.feedbackPresenter = feedbackPresenter
        self.startCapture = startCapture
    }

    func start() {
        switch lifecycle {
        case .constructed:
            lifecycle = .started
            Self.logger.info("event=app.command.router.started result=started")
        case .started:
            Self.logger.debug("event=app.command.router.start_ignored reason=already_started")
        case .stopped:
            Self.logger.error("event=app.command.router.start_rejected reason=stopped")
        }
    }

    @discardableResult
    func submit(
        _ command: CaptureCommand,
        source: CommandSource
    ) -> CaptureRoutingDisposition {
        let commandID = CaptureCommandID()

        Self.logger.info(
            "event=app.command.received correlation_id=\(commandID.rawValue.uuidString, privacy: .public) command_id=\(commandID.rawValue.uuidString, privacy: .public) command=\(command.logValue, privacy: .public) source=\(source.logValue, privacy: .public)"
        )

        switch lifecycle {
        case .constructed:
            return reject(commandID, reason: .notStarted, command: command, source: source)
        case .stopped:
            return reject(commandID, reason: .stopped, command: command, source: source)
        case .started:
            break
        }

        if let activeCommandID = pendingRoute?.commandID {
            return reject(
                commandID,
                reason: .routingBusy(activeCommandID: activeCommandID),
                command: command,
                source: source
            )
        }

        let acceptedAt = ContinuousClock().now
        pendingRoute = PendingRoute(
            commandID: commandID,
            command: command,
            source: source,
            acceptedAt: acceptedAt,
            permissionStartedAt: nil
        )

        let permissionManager = permissionManager
        let startCapture = startCapture
        pendingTask = Task(
            name: "mio.capture-route.\(commandID.rawValue.uuidString)",
            priority: .userInitiated
        ) { @MainActor [weak self] in
            guard !Task.isCancelled else {
                self?.recordStaleResult(commandID: commandID, phase: "entry")
                return
            }
            guard self?.beginPermission(commandID: commandID) == true else { return }

            let decision = permissionManager.authorizeScreenCapture()

            guard !Task.isCancelled else {
                self?.recordStaleResult(commandID: commandID, phase: "permission_completion")
                return
            }
            self?.finishRoute(
                commandID: commandID,
                decision: decision,
                startCapture: startCapture
            )
        }

        Self.logger.info(
            "event=app.command.accepted correlation_id=\(commandID.rawValue.uuidString, privacy: .public) command_id=\(commandID.rawValue.uuidString, privacy: .public) command=\(command.logValue, privacy: .public) source=\(source.logValue, privacy: .public) result=routing_started"
        )
        return .routingStarted(commandID: commandID)
    }

    func stop() {
        guard lifecycle != .stopped else {
            Self.logger.debug("event=app.command.router.stop_ignored reason=already_stopped")
            return
        }

        lifecycle = .stopped

        let route = pendingRoute
        pendingRoute = nil
        let task = pendingTask
        pendingTask = nil

        if let route {
            logTerminal(
                event: "app.command.cancelled",
                route: route,
                result: "cancelled",
                reason: "app_services_stopped"
            )
        }

        task?.cancel()
        Self.logger.info(
            "event=app.command.router.stopped result=stopped pending_count_before=\(route == nil ? 0 : 1, privacy: .public)"
        )
    }

    isolated deinit {
        pendingTask?.cancel()
    }

    private func beginPermission(commandID: CaptureCommandID) -> Bool {
        guard
            !Task.isCancelled,
            lifecycle == .started,
            var route = pendingRoute,
            route.commandID == commandID
        else {
            recordStaleResult(commandID: commandID, phase: "entry_gate")
            return false
        }

        route.permissionStartedAt = ContinuousClock().now
        pendingRoute = route
        Self.logger.info(
            "event=app.command.permission.started correlation_id=\(commandID.rawValue.uuidString, privacy: .public) command_id=\(commandID.rawValue.uuidString, privacy: .public) command=\(route.command.logValue, privacy: .public) source=\(route.source.logValue, privacy: .public) truth=legacy"
        )
        return true
    }

    private func finishRoute(
        commandID: CaptureCommandID,
        decision: PermissionDecision,
        startCapture: @MainActor (CaptureCommand) -> CaptureStartDisposition
    ) {
        guard
            !Task.isCancelled,
            lifecycle == .started,
            let route = pendingRoute,
            route.commandID == commandID
        else {
            recordStaleResult(commandID: commandID, phase: "permission_result")
            return
        }

        pendingRoute = nil
        pendingTask = nil

        let permissionStartedAt = route.permissionStartedAt ?? route.acceptedAt
        let authorized: Bool = { if case .authorized = decision { return true }; return false }()
        Self.logger.info(
            "event=app.command.permission.completed correlation_id=\(commandID.rawValue.uuidString, privacy: .public) command_id=\(commandID.rawValue.uuidString, privacy: .public) command=\(route.command.logValue, privacy: .public) source=\(route.source.logValue, privacy: .public) result=\(authorized ? "authorized" : "denied", privacy: .public) truth=typed duration_ms=\(Self.durationMilliseconds(since: permissionStartedAt), privacy: .public)"
        )

        guard case .authorized = decision else {
            presentPermissionDenial(decision)
            logTerminal(
                event: "app.command.completed",
                route: route,
                result: "permission_denied",
                reason: "permission_denied"
            )
            return
        }

        logCaptureDisposition(route: route, disposition: startCapture(route.command))
    }

    /// 01 → 08: turn a non-authorized permission decision into an 08-owned
    /// feedback event. Recovery-bearing decisions become a clickable
    /// `.permissionDenied` pill; `.restricted(nil)`/`.failed` become a plain
    /// `.failed` pill (no fabricated action). 12 never touches the presenter.
    private func presentPermissionDenial(_ decision: PermissionDecision) {
        let event: CaptureFeedbackEvent
        switch decision {
        case let .denied(.openSystemSettings(destination)),
             let .restricted(.some(.openSystemSettings(destination))):
            event = .permissionDenied(
                id: CaptureFeedbackID(),
                action: .openSystemSettings(destination)
            )
        case .restricted(nil), .failed, .authorized:
            event = .failed(id: CaptureFeedbackID(), failure: .unknown)
        }
        feedbackPresenter.present(event)
    }

    private func reject(
        _ commandID: CaptureCommandID,
        reason: CaptureRoutingRejection,
        command: CaptureCommand,
        source: CommandSource
    ) -> CaptureRoutingDisposition {
        switch reason {
        case .notStarted:
            Self.logger.info(
                "event=app.command.rejected correlation_id=\(commandID.rawValue.uuidString, privacy: .public) command_id=\(commandID.rawValue.uuidString, privacy: .public) command=\(command.logValue, privacy: .public) source=\(source.logValue, privacy: .public) result=rejected reason=not_started"
            )
        case .stopped:
            Self.logger.info(
                "event=app.command.rejected correlation_id=\(commandID.rawValue.uuidString, privacy: .public) command_id=\(commandID.rawValue.uuidString, privacy: .public) command=\(command.logValue, privacy: .public) source=\(source.logValue, privacy: .public) result=rejected reason=stopped"
            )
        case let .routingBusy(activeCommandID):
            Self.logger.info(
                "event=app.command.rejected correlation_id=\(commandID.rawValue.uuidString, privacy: .public) command_id=\(commandID.rawValue.uuidString, privacy: .public) command=\(command.logValue, privacy: .public) source=\(source.logValue, privacy: .public) result=rejected reason=routing_busy active_command_id=\(activeCommandID.rawValue.uuidString, privacy: .public)"
            )
        }

        return .rejected(commandID: commandID, reason: reason)
    }

    private func logTerminal(
        event: StaticString,
        route: PendingRoute,
        result: StaticString,
        reason: StaticString
    ) {
        Self.logger.info(
            "event=\(event, privacy: .public) correlation_id=\(route.commandID.rawValue.uuidString, privacy: .public) command_id=\(route.commandID.rawValue.uuidString, privacy: .public) command=\(route.command.logValue, privacy: .public) source=\(route.source.logValue, privacy: .public) result=\(result, privacy: .public) reason=\(reason, privacy: .public) duration_ms=\(Self.durationMilliseconds(since: route.acceptedAt), privacy: .public) capture_truth=not_started"
        )
    }

    private func logCaptureDisposition(
        route: PendingRoute,
        disposition: CaptureStartDisposition
    ) {
        switch disposition {
        case let .accepted(sessionID):
            Self.logger.info(
                "event=app.command.completed correlation_id=\(route.commandID.rawValue.uuidString, privacy: .public) command_id=\(route.commandID.rawValue.uuidString, privacy: .public) capture_session_id=\(sessionID.rawValue.uuidString, privacy: .public) command=\(route.command.logValue, privacy: .public) source=\(route.source.logValue, privacy: .public) result=capture_accepted reason=none duration_ms=\(Self.durationMilliseconds(since: route.acceptedAt), privacy: .public) capture_truth=accepted"
            )
        case let .rejected(.busy(activeSessionID, phase)):
            Self.logger.info(
                "event=app.command.completed correlation_id=\(route.commandID.rawValue.uuidString, privacy: .public) command_id=\(route.commandID.rawValue.uuidString, privacy: .public) active_capture_session_id=\(activeSessionID.rawValue.uuidString, privacy: .public) active_phase=\(phase.rawValue, privacy: .public) command=\(route.command.logValue, privacy: .public) source=\(route.source.logValue, privacy: .public) result=capture_rejected reason=capture_busy duration_ms=\(Self.durationMilliseconds(since: route.acceptedAt), privacy: .public) capture_truth=rejected"
            )
        case .rejected(.stopped):
            Self.logger.info(
                "event=app.command.completed correlation_id=\(route.commandID.rawValue.uuidString, privacy: .public) command_id=\(route.commandID.rawValue.uuidString, privacy: .public) command=\(route.command.logValue, privacy: .public) source=\(route.source.logValue, privacy: .public) result=capture_rejected reason=capture_stopped duration_ms=\(Self.durationMilliseconds(since: route.acceptedAt), privacy: .public) capture_truth=rejected"
            )
        }
    }

    private func recordStaleResult(commandID: CaptureCommandID, phase: StaticString) {
        Self.logger.debug(
            "event=app.command.stale_result_dropped correlation_id=\(commandID.rawValue.uuidString, privacy: .public) command_id=\(commandID.rawValue.uuidString, privacy: .public) phase=\(phase, privacy: .public) reason=cancelled_or_invalidated"
        )
    }

    private static func durationMilliseconds(since start: ContinuousClock.Instant) -> Int64 {
        let components = start.duration(to: ContinuousClock().now).components
        return components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
    }
}
