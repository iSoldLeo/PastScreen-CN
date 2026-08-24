//
//  GlobalShortcutService.swift
//  Mio
//
//  The single owner of Carbon's global-hotkey handler and registrations.
//

import Carbon.HIToolbox
import Combine
import Foundation
import OSLog

private nonisolated enum CarbonShortcutConstants {
    static let signature: OSType = {
        let bytes: [UInt8] = [0x4D, 0x69, 0x6F, 0x31] // "Mio1"
        return UInt32(bytes[0]) << 24
            | UInt32(bytes[1]) << 16
            | UInt32(bytes[2]) << 8
            | UInt32(bytes[3])
    }()
}

private nonisolated func mioGlobalShortcutEventHandler(
    _: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }
    guard hotKeyID.signature == CarbonShortcutConstants.signature else {
        return OSStatus(eventNotHandledErr)
    }
    guard Thread.isMainThread else { return OSStatus(eventNotHandledErr) }

    let service = Unmanaged<GlobalShortcutService>
        .fromOpaque(userData)
        .takeUnretainedValue()

    // SAFETY: Carbon application-event callbacks are expected on the main
    // thread, and the runtime guard above proves that fact before entering
    // this target's MainActor-isolated service synchronously.
    return MainActor.assumeIsolated {
        service.handleCarbonEvent(registrationID: hotKeyID.id)
    }
}

@MainActor
final class GlobalShortcutService: ObservableObject {
    private enum Lifecycle: Equatable {
        case constructed
        case started
        case stopped
    }

    private enum HandlerState {
        case notInstalled
        case installed(EventHandlerRef)
        case failed(ShortcutRegistrationFailure)
        case cleanupFailed(EventHandlerRef, ShortcutRegistrationFailure)
    }

    private struct RegistrationEntry {
        let action: ShortcutAction
        let shortcut: Shortcut
        let id: UInt32
        let ref: EventHotKeyRef
    }

    private struct RecordingSession {
        let id: RecordingSessionID
        let owner: RecorderOwnerID
        let host: ShortcutRecordingHost
        let startedAt: ContinuousClock.Instant
        let onInvalidated: @MainActor (RecordingEndReason) -> Void
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.iSoldLeo.Mio",
        category: "Hotkeys"
    )

    @Published private(set) var registrationStates: [ShortcutAction: ShortcutRegistrationState]
    @Published private(set) var presentationRevision: UInt64 = 0

    private let store: ShortcutStore
    private var lifecycle: Lifecycle = .constructed
    private var handlerState: HandlerState = .notInstalled
    private var activeByID: [UInt32: RegistrationEntry] = [:]
    private var activeIDByAction: [ShortcutAction: UInt32] = [:]
    private var residualByID: [UInt32: RegistrationEntry] = [:]
    private var nextRegistrationID: UInt32 = 1
    private var lifecycleEpoch: UInt64 = 0
    private var activeRecording: RecordingSession?
    private var onAction: (@MainActor (ShortcutAction) -> Void)?
    private var inputSourceObserver: NSObjectProtocol?

    init(store: ShortcutStore) {
        self.store = store
        self.registrationStates = Dictionary(
            uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, .notStarted) }
        )
    }

    func start(onAction: @escaping @MainActor (ShortcutAction) -> Void) {
        switch lifecycle {
        case .constructed:
            lifecycle = .started
        case .started:
            Self.logger.debug("event=shortcut.service.start result=ignored reason=already_started")
            return
        case .stopped:
            Self.logger.error("event=shortcut.service.start result=rejected reason=stopped")
            return
        }

        lifecycleEpoch &+= 1
        self.onAction = onAction
        installInputSourceObserver(epoch: lifecycleEpoch)

        guard installHandlerIfNeeded() == nil else {
            projectHandlerFailureToAssignedActions()
            Self.logger.error("event=shortcut.service.start result=handler_failed")
            return
        }

        for action in ShortcutAction.allCases {
            _ = reconcileAction(action, reason: "start")
        }
        Self.logger.info(
            "event=shortcut.service.start result=started desired_count=\(self.assignedActionCount, privacy: .public)"
        )
    }

    func stop() -> ShortcutStopOutcome {
        if lifecycle != .stopped {
            lifecycle = .stopped
            lifecycleEpoch &+= 1
            onAction = nil

            if let session = takeActiveRecording() {
                logRecordingEnded(session, reason: .serviceStopped)
                session.onInvalidated(.serviceStopped)
            }

            removeInputSourceObserver()
            terminalizeAllActiveRegistrations()
        }

        var failures: [ShortcutRegistrationFailure] = []
        failures.append(contentsOf: releaseResidualRegistrations())
        if let failure = removeHandlerIfPresent() {
            failures.append(failure)
        }

        let handlerRetained: Bool
        switch handlerState {
        case .installed, .cleanupFailed: handlerRetained = true
        case .notInstalled, .failed: handlerRetained = false
        }

        if failures.isEmpty, residualByID.isEmpty, !handlerRetained {
            Self.logger.info("event=shortcut.service.stop result=stopped_cleanly residual_count=0 handler_retained=false")
            return .stoppedCleanly
        }

        Self.logger.error(
            "event=shortcut.service.stop result=cleanup_failed residual_count=\(self.residualByID.count, privacy: .public) handler_retained=\(handlerRetained, privacy: .public) failure_count=\(failures.count, privacy: .public)"
        )
        return .cleanupFailed(
            residualRegistrationCount: residualByID.count,
            handlerRetained: handlerRetained,
            failures: failures
        )
    }

    func beginRecording(
        owner: RecorderOwnerID,
        host: ShortcutRecordingHost,
        onInvalidated: @escaping @MainActor (RecordingEndReason) -> Void
    ) -> BeginRecordingOutcome {
        guard lifecycle == .started else {
            Self.logger.notice(
                "event=shortcut.recording.rejected owner_id=\(owner.rawValue.uuidString, privacy: .public) host=\(host.rawValue, privacy: .public) reason=service_not_started"
            )
            return .rejected(.serviceNotStarted)
        }
        guard activeRecording == nil else {
            Self.logger.notice(
                "event=shortcut.recording.rejected owner_id=\(owner.rawValue.uuidString, privacy: .public) host=\(host.rawValue, privacy: .public) reason=recording_busy"
            )
            return .rejected(.recordingBusy)
        }

        let session = RecordingSession(
            id: RecordingSessionID(),
            owner: owner,
            host: host,
            startedAt: ContinuousClock().now,
            onInvalidated: onInvalidated
        )
        activeRecording = session
        Self.logger.info(
            "event=shortcut.recording.started session_id=\(session.id.rawValue.uuidString, privacy: .public) owner_id=\(owner.rawValue.uuidString, privacy: .public) host=\(host.rawValue, privacy: .public)"
        )
        return .started(session.id)
    }

    func endRecording(id: RecordingSessionID, reason: RecordingEndReason) {
        guard activeRecording?.id == id, let session = takeActiveRecording() else {
            Self.logger.debug(
                "event=shortcut.recording.end result=ignored reason=stale_session requested_session_id=\(id.rawValue.uuidString, privacy: .public)"
            )
            return
        }
        logRecordingEnded(session, reason: reason)
    }

    func endRecording(forHost host: ShortcutRecordingHost, reason: RecordingEndReason) {
        guard activeRecording?.host == host, let session = takeActiveRecording() else {
            Self.logger.debug(
                "event=shortcut.recording.host_end result=ignored requested_host=\(host.rawValue, privacy: .public) requested_reason=\(reason.rawValue, privacy: .public) reason=no_matching_session"
            )
            return
        }
        logRecordingEnded(session, reason: reason)
        session.onInvalidated(reason)
    }

    func update(
        action: ShortcutAction,
        candidate: Shortcut,
        sessionID: RecordingSessionID
    ) -> ShortcutMutationOutcome {
        guard lifecycle == .started else { return .rejectedServiceNotStarted }
        guard activeRecording?.id == sessionID else { return .rejectedStaleSession }

        if let failure = ShortcutValidator.validate(
            action: action,
            candidate: candidate,
            in: store.assignments
        ) {
            logValidationFailure(action: action, failure: failure)
            return .rejectedValidation(failure)
        }

        if store.assignments[action].shortcut == candidate,
           case .registered(candidate)? = registrationStates[action] {
            return .applied(.registered(candidate))
        }

        var candidateAssignments = store.assignments
        candidateAssignments[action] = .assigned(candidate)
        switch store.commit(candidateAssignments) {
        case .success:
            return .applied(reconcileAction(action, reason: "assignment_changed"))
        case let .failure(failure):
            return .rejectedStore(failure)
        }
    }

    func disable(action: ShortcutAction) -> ShortcutMutationOutcome {
        guard lifecycle == .started else { return .rejectedServiceNotStarted }
        guard activeRecording == nil else { return .rejectedRecordingActive }

        var candidateAssignments = store.assignments
        candidateAssignments[action] = .disabled
        switch store.commit(candidateAssignments) {
        case .success:
            return .applied(reconcileAction(action, reason: "disabled"))
        case let .failure(failure):
            return .rejectedStore(failure)
        }
    }

    func retryRegistration(action: ShortcutAction) -> ShortcutMutationOutcome {
        guard lifecycle == .started else { return .rejectedServiceNotStarted }
        guard activeRecording == nil else { return .rejectedRecordingActive }
        return .applied(reconcileAction(action, reason: "explicit_retry"))
    }

    func reconcile(reason: ShortcutReconcileReason) -> ShortcutReconcileOutcome {
        guard lifecycle == .started else { return .serviceStopped }
        let startedAt = ContinuousClock().now

        if let failure = installHandlerIfNeeded() {
            projectHandlerFailureToAssignedActions()
            logReconcile(reason: reason, outcome: "failed", startedAt: startedAt)
            return .failed(failure)
        }

        var failedActions: [ShortcutAction] = []
        for action in ShortcutAction.allCases {
            if case .failed = reconcileAction(action, reason: reason.rawValue) {
                failedActions.append(action)
            }
        }

        if failedActions.isEmpty {
            logReconcile(reason: reason, outcome: "healthy", startedAt: startedAt)
            return .healthy
        }

        logReconcile(reason: reason, outcome: "degraded", startedAt: startedAt)
        return .degraded(failedActions: failedActions)
    }

    fileprivate func handleCarbonEvent(registrationID: UInt32) -> OSStatus {
        guard lifecycle == .started else {
            logDroppedEvent(registrationID: registrationID, action: nil, reason: "service_stopped")
            return noErr
        }
        guard let entry = activeByID[registrationID] else {
            let reason = residualByID[registrationID] == nil ? "unknown_id" : "residual_id"
            logDroppedEvent(registrationID: registrationID, action: nil, reason: reason)
            return noErr
        }
        guard activeRecording == nil else {
            logDroppedEvent(
                registrationID: registrationID,
                action: entry.action,
                reason: "recording_paused"
            )
            return noErr
        }

        Self.logger.info(
            "event=shortcut.dispatched action=\(entry.action.rawValue, privacy: .public) registration_id=\(entry.id, privacy: .public)"
        )
        onAction?(entry.action)
        return noErr
    }

    isolated deinit {
        assert(lifecycle != .started, "GlobalShortcutService deinitialized before stop().")
        assert(activeByID.isEmpty, "GlobalShortcutService deinitialized with active registrations.")
        assert(activeIDByAction.isEmpty, "GlobalShortcutService deinitialized with active reverse registrations.")
        assert(residualByID.isEmpty, "GlobalShortcutService deinitialized with residual registrations.")
        assert(activeRecording == nil, "GlobalShortcutService deinitialized with an active recording session.")
        assert(inputSourceObserver == nil, "GlobalShortcutService deinitialized with an input-source observer.")
        assert(onAction == nil, "GlobalShortcutService deinitialized with a business callback.")
        switch handlerState {
        case .notInstalled, .failed:
            break
        case .installed, .cleanupFailed:
            assertionFailure("GlobalShortcutService deinitialized with a retained Carbon handler.")
        }
    }

    private var assignedActionCount: Int {
        ShortcutAction.allCases.reduce(into: 0) { count, action in
            if case .assigned = store.assignments[action] { count += 1 }
        }
    }

    private func installHandlerIfNeeded() -> ShortcutRegistrationFailure? {
        switch handlerState {
        case .installed:
            return nil
        case let .cleanupFailed(_, failure):
            return failure
        case .notInstalled, .failed:
            break
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var handler: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            mioGlobalShortcutEventHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )

        guard status == noErr, let handler else {
            let effectiveStatus = status == noErr ? OSStatus(eventInternalErr) : status
            let failure = ShortcutRegistrationFailure.platform(
                operation: .installHandler,
                osStatus: effectiveStatus
            )
            handlerState = .failed(failure)
            logPlatformResult(operation: .installHandler, status: effectiveStatus, result: "failed")
            return failure
        }

        handlerState = .installed(handler)
        logPlatformResult(operation: .installHandler, status: noErr, result: "installed")
        return nil
    }

    private func removeHandlerIfPresent() -> ShortcutRegistrationFailure? {
        let handler: EventHandlerRef
        switch handlerState {
        case let .installed(value), let .cleanupFailed(value, _):
            handler = value
        case .notInstalled, .failed:
            handlerState = .notInstalled
            return nil
        }

        let status = RemoveEventHandler(handler)
        guard status == noErr else {
            let failure = ShortcutRegistrationFailure.platform(
                operation: .removeHandler,
                osStatus: status
            )
            handlerState = .cleanupFailed(handler, failure)
            logPlatformResult(operation: .removeHandler, status: status, result: "cleanup_failed")
            return failure
        }

        handlerState = .notInstalled
        logPlatformResult(operation: .removeHandler, status: noErr, result: "removed")
        return nil
    }

    private func reconcileAction(
        _ action: ShortcutAction,
        reason: String
    ) -> ShortcutRegistrationState {
        if !cleanupResidualRegistrations(for: action) {
            return registrationStates[action] ?? .notStarted
        }

        let desired = store.assignments[action]
        if let activeID = activeIDByAction[action], let entry = activeByID[activeID] {
            if desired.shortcut == entry.shortcut {
                let state = ShortcutRegistrationState.registered(entry.shortcut)
                registrationStates[action] = state
                return state
            }

            guard unregisterActive(entry, desiredAfterFailure: desired) else {
                return registrationStates[action] ?? .notStarted
            }
        }

        guard case let .assigned(shortcut) = desired else {
            let state = ShortcutRegistrationState.disabled
            registrationStates[action] = state
            return state
        }

        if let handlerFailure = installHandlerIfNeeded() {
            let state = ShortcutRegistrationState.failed(
                desired: desired,
                failure: handlerFailure
            )
            registrationStates[action] = state
            return state
        }

        let state = register(shortcut: shortcut, action: action, reason: reason)
        registrationStates[action] = state
        return state
    }

    private func register(
        shortcut: Shortcut,
        action: ShortcutAction,
        reason: String
    ) -> ShortcutRegistrationState {
        guard let registrationID = allocateRegistrationID() else {
            let failure = ShortcutRegistrationFailure.registrationIdentifierExhausted
            Self.logger.error(
                "event=shortcut.registration result=failed action=\(action.rawValue, privacy: .public) reason=identifier_exhausted"
            )
            return .failed(desired: .assigned(shortcut), failure: failure)
        }

        let hotKeyID = EventHotKeyID(
            signature: CarbonShortcutConstants.signature,
            id: registrationID
        )
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            Self.carbonModifiers(from: shortcut.modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        guard status == noErr, let ref else {
            let effectiveStatus = status == noErr ? OSStatus(eventInternalErr) : status
            let failure = ShortcutRegistrationFailure.platform(
                operation: .register,
                osStatus: effectiveStatus
            )
            Self.logger.error(
                "event=shortcut.registration result=failed action=\(action.rawValue, privacy: .public) registration_id=\(registrationID, privacy: .public) reason=\(reason, privacy: .public) key_code=\(shortcut.keyCode, privacy: .public) modifiers=\(shortcut.modifiers.rawValue, privacy: .public) os_status=\(effectiveStatus, privacy: .public)"
            )
            return .failed(desired: .assigned(shortcut), failure: failure)
        }

        let entry = RegistrationEntry(
            action: action,
            shortcut: shortcut,
            id: registrationID,
            ref: ref
        )
        activeByID[registrationID] = entry
        activeIDByAction[action] = registrationID
        Self.logger.info(
            "event=shortcut.registration result=registered action=\(action.rawValue, privacy: .public) registration_id=\(registrationID, privacy: .public) reason=\(reason, privacy: .public) key_code=\(shortcut.keyCode, privacy: .public) modifiers=\(shortcut.modifiers.rawValue, privacy: .public) os_status=0"
        )
        return .registered(shortcut)
    }

    private func unregisterActive(
        _ entry: RegistrationEntry,
        desiredAfterFailure: ShortcutAssignment
    ) -> Bool {
        activeByID.removeValue(forKey: entry.id)
        activeIDByAction.removeValue(forKey: entry.action)

        let status = UnregisterEventHotKey(entry.ref)
        guard status == noErr else {
            let failure = ShortcutRegistrationFailure.platform(
                operation: .unregister,
                osStatus: status
            )
            residualByID[entry.id] = entry
            registrationStates[entry.action] = .failed(
                desired: desiredAfterFailure,
                failure: failure
            )
            logUnregistration(entry: entry, status: status, ownershipAfter: "residual")
            return false
        }

        logUnregistration(entry: entry, status: noErr, ownershipAfter: "released")
        return true
    }

    private func cleanupResidualRegistrations(for action: ShortcutAction) -> Bool {
        let entries = residualByID.values
            .filter { $0.action == action }
            .sorted { $0.id < $1.id }
        var allReleased = true

        for entry in entries {
            let status = UnregisterEventHotKey(entry.ref)
            if status == noErr {
                residualByID.removeValue(forKey: entry.id)
                logUnregistration(entry: entry, status: noErr, ownershipAfter: "released")
            } else {
                let failure = ShortcutRegistrationFailure.platform(
                    operation: .unregister,
                    osStatus: status
                )
                residualByID[entry.id] = entry
                registrationStates[action] = .failed(
                    desired: store.assignments[action],
                    failure: failure
                )
                logUnregistration(entry: entry, status: status, ownershipAfter: "residual")
                allReleased = false
            }
        }
        return allReleased
    }

    private func terminalizeAllActiveRegistrations() {
        let entries = activeByID.values.sorted { $0.id < $1.id }
        activeByID.removeAll()
        activeIDByAction.removeAll()
        for entry in entries {
            residualByID[entry.id] = entry
        }
    }

    private func releaseResidualRegistrations() -> [ShortcutRegistrationFailure] {
        var failures: [ShortcutRegistrationFailure] = []
        for entry in residualByID.values.sorted(by: { $0.id < $1.id }) {
            let status = UnregisterEventHotKey(entry.ref)
            if status == noErr {
                residualByID.removeValue(forKey: entry.id)
                logUnregistration(entry: entry, status: noErr, ownershipAfter: "released")
            } else {
                let failure = ShortcutRegistrationFailure.platform(
                    operation: .unregister,
                    osStatus: status
                )
                residualByID[entry.id] = entry
                failures.append(failure)
                logUnregistration(entry: entry, status: status, ownershipAfter: "residual")
            }
        }
        return failures
    }

    private func projectHandlerFailureToAssignedActions() {
        let failure: ShortcutRegistrationFailure
        switch handlerState {
        case let .failed(value), let .cleanupFailed(_, value):
            failure = value
        case .notInstalled, .installed:
            return
        }

        for action in ShortcutAction.allCases {
            let desired = store.assignments[action]
            switch desired {
            case .disabled:
                registrationStates[action] = .disabled
            case .assigned:
                registrationStates[action] = .failed(desired: desired, failure: failure)
            }
        }
    }

    private func allocateRegistrationID() -> UInt32? {
        guard nextRegistrationID != 0 else { return nil }
        let result = nextRegistrationID
        nextRegistrationID = result == UInt32.max ? 0 : result + 1
        return result
    }

    private func takeActiveRecording() -> RecordingSession? {
        guard let session = activeRecording else { return nil }
        activeRecording = nil
        return session
    }

    private func installInputSourceObserver(epoch: UInt64) {
        let center = DistributedNotificationCenter.default()
        let name = Notification.Name(
            rawValue: kTISNotifySelectedKeyboardInputSourceChanged as String
        )
        inputSourceObserver = center.addObserver(
            forName: name,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            // The Notification and TIS objects stay inside the framework
            // callback. Only this primitive lifecycle epoch crosses to the
            // short MainActor task.
            Task { @MainActor [weak self] in
                guard
                    let self,
                    self.lifecycle == .started,
                    self.lifecycleEpoch == epoch
                else { return }
                self.presentationRevision &+= 1
                Self.logger.info(
                    "event=shortcut.presentation.input_source_changed result=refreshed revision=\(self.presentationRevision, privacy: .public)"
                )
            }
        }
    }

    private func removeInputSourceObserver() {
        guard let inputSourceObserver else { return }
        DistributedNotificationCenter.default().removeObserver(inputSourceObserver)
        self.inputSourceObserver = nil
    }

    private func logValidationFailure(
        action: ShortcutAction,
        failure: ShortcutValidationFailure
    ) {
        Self.logger.notice(
            "event=shortcut.validation.rejected action=\(action.rawValue, privacy: .public) reason=\(Self.logValue(failure), privacy: .public)"
        )
    }

    private func logRecordingEnded(_ session: RecordingSession, reason: RecordingEndReason) {
        Self.logger.info(
            "event=shortcut.recording.ended session_id=\(session.id.rawValue.uuidString, privacy: .public) owner_id=\(session.owner.rawValue.uuidString, privacy: .public) host=\(session.host.rawValue, privacy: .public) reason=\(reason.rawValue, privacy: .public) duration_ms=\(Self.durationMilliseconds(since: session.startedAt), privacy: .public)"
        )
    }

    private func logDroppedEvent(
        registrationID: UInt32,
        action: ShortcutAction?,
        reason: String
    ) {
        Self.logger.debug(
            "event=shortcut.dispatch.dropped registration_id=\(registrationID, privacy: .public) action=\(action?.rawValue ?? "none", privacy: .public) reason=\(reason, privacy: .public)"
        )
    }

    private func logUnregistration(
        entry: RegistrationEntry,
        status: OSStatus,
        ownershipAfter: String
    ) {
        Self.logger.log(
            level: status == noErr ? .info : .error,
            "event=shortcut.unregistration action=\(entry.action.rawValue, privacy: .public) registration_id=\(entry.id, privacy: .public) os_status=\(status, privacy: .public) ownership_after=\(ownershipAfter, privacy: .public)"
        )
    }

    private func logPlatformResult(
        operation: ShortcutRegistrationFailure.Operation,
        status: OSStatus,
        result: String
    ) {
        Self.logger.log(
            level: status == noErr ? .info : .error,
            "event=shortcut.platform operation=\(operation.rawValue, privacy: .public) result=\(result, privacy: .public) os_status=\(status, privacy: .public)"
        )
    }

    private func logReconcile(
        reason: ShortcutReconcileReason,
        outcome: String,
        startedAt: ContinuousClock.Instant
    ) {
        Self.logger.info(
            "event=shortcut.reconcile reason=\(reason.rawValue, privacy: .public) outcome=\(outcome, privacy: .public) duration_ms=\(Self.durationMilliseconds(since: startedAt), privacy: .public)"
        )
    }

    private static func carbonModifiers(from modifiers: ShortcutModifiers) -> UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        return result
    }

    private static func logValue(_ failure: ShortcutValidationFailure) -> String {
        switch failure {
        case .unsupportedModifierBits: "unsupported_modifier_bits"
        case .primaryModifierRequired: "primary_modifier_required"
        case let .duplicate(action): "duplicate:\(action.rawValue)"
        }
    }

    private static func durationMilliseconds(since start: ContinuousClock.Instant) -> Int64 {
        let components = start.duration(to: ContinuousClock().now).components
        return components.seconds * 1_000
            + components.attoseconds / 1_000_000_000_000_000
    }
}
