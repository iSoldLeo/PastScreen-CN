//
//  SaveFolderAccess.swift
//  Mio
//
//  The sole owner of the security-scoped save-folder bookmark, selection UI,
//  authorization state and per-I/O lexical security scope.
//

import AppKit
import Combine
import Foundation
import OSLog

nonisolated enum SaveFolderAuthorizationState: Sendable, Equatable {
    case notSelected
    case restoring
    case selecting(previousDisplayName: String?)
    case ready(displayName: String)
    case needsSelection(SaveFolderFailure)
    case stopped
}

nonisolated enum SaveFolderFailure: Error, LocalizedError, Sendable, Equatable {
    case missingBookmark
    case invalidBookmark
    case staleRefreshFailed
    case accessDenied
    case unavailable

    var errorDescription: String? {
        switch self {
        case .missingBookmark:
            NSLocalizedString("settings.storage.folder_required", comment: "No save folder has been selected")
        case .invalidBookmark, .staleRefreshFailed, .accessDenied, .unavailable:
            NSLocalizedString("settings.storage.folder_reselect", comment: "The save folder must be selected again")
        }
    }

    var logCode: String {
        switch self {
        case .missingBookmark: "missing_bookmark"
        case .invalidBookmark: "invalid_bookmark"
        case .staleRefreshFailed: "stale_refresh_failed"
        case .accessDenied: "access_denied"
        case .unavailable: "unavailable"
        }
    }
}

nonisolated struct SaveFolderSelectionID: Hashable, Sendable {
    fileprivate let rawValue: UUID

    fileprivate init() {
        rawValue = UUID()
    }
}

nonisolated enum SaveFolderSelectionSource: String, Sendable, Equatable {
    case settings
    case onboarding
}

nonisolated enum SaveFolderSelectionResult: Sendable, Equatable {
    case selected(displayName: String)
    case cancelled
    case failed(SaveFolderFailure, retainedPrevious: Bool)
}

nonisolated struct SaveFolderSelectionCompletion: Sendable, Equatable {
    let id: SaveFolderSelectionID
    let source: SaveFolderSelectionSource
    let result: SaveFolderSelectionResult
}

@MainActor
final class SaveFolderAccess: ObservableObject {
    private enum Lifecycle {
        case constructed
        case started
        case stopped
    }

    /// Keeping identity, timing and handle in one record prevents terminal
    /// paths from clearing only part of an operation ledger.
    private struct RestoreOperation {
        let id: UUID
        let startedAt: ContinuousClock.Instant
        var task: Task<Void, Never>?
    }

    private struct SelectionOperation {
        let id: SaveFolderSelectionID
        let source: SaveFolderSelectionSource
        let startedAt: ContinuousClock.Instant
        var task: Task<Void, Never>?
    }

    private static let bookmarkKey = "saveFolderBookmark"
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.iSoldLeo.Mio",
        category: "Settings.FolderAccess"
    )

    @Published private(set) var state: SaveFolderAuthorizationState = .notSelected
    @Published private(set) var selectionCompletion: SaveFolderSelectionCompletion?

    private let defaults: UserDefaults
    private var lifecycle: Lifecycle = .constructed
    private var bookmarkRevision: UInt64 = 0
    private var restoreOperation: RestoreOperation?
    private var selectionOperation: SelectionOperation?
    private var activePanel: NSOpenPanel?

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func start() {
        selectionCompletion = nil
        switch lifecycle {
        case .constructed:
            lifecycle = .started
        case .started:
            Self.logger.debug("event=folder.lifecycle.start_ignored reason=already_started")
            return
        case .stopped:
            Self.logger.error("event=folder.lifecycle.start_rejected reason=lifecycle_stopped")
            return
        }

        let operationID = UUID()
        let startedAt = ContinuousClock().now
        logRestoreStarted(operationID: operationID)
        guard let bookmarkData = currentBookmarkData else {
            state = .notSelected
            logRestoreTerminal(
                operationID: operationID,
                result: "not_selected",
                stale: false,
                startedAt: startedAt
            )
            return
        }

        state = .restoring
        let revision = bookmarkRevision
        restoreOperation = RestoreOperation(id: operationID, startedAt: startedAt, task: nil)
        let task = Task(
            name: "mio.folder.restore.\(operationID.uuidString)",
            priority: .utility
        ) { @MainActor [weak self] in
            do {
                let prepared = try await SecurityScopedBookmark.resolve(bookmarkData)
                guard let self else { return }
                try self.completeRestore(
                    prepared,
                    originalData: bookmarkData,
                    revision: revision,
                    operationID: operationID
                )
                self.logRestoreTerminal(
                    operationID: operationID,
                    result: "ready",
                    stale: prepared.refreshedData != nil,
                    startedAt: startedAt
                )
            } catch is CancellationError {
                guard let self else { return }
                self.finishCancelledRestore(
                    operationID: operationID,
                    revision: revision,
                    startedAt: startedAt
                )
            } catch let failure as SaveFolderFailure {
                guard let self else { return }
                self.finishFailedRestore(
                    failure,
                    originalData: bookmarkData,
                    revision: revision,
                    operationID: operationID,
                    startedAt: startedAt
                )
            } catch {
                guard let self else { return }
                self.finishFailedRestore(
                    .unavailable,
                    originalData: bookmarkData,
                    revision: revision,
                    operationID: operationID,
                    startedAt: startedAt
                )
            }
        }
        if restoreOperation?.id == operationID {
            restoreOperation?.task = task
        }
    }

    func stop() {
        guard lifecycle != .stopped else { return }
        let restorePendingBefore = restoreOperation == nil ? 0 : 1
        let selectionPendingBefore = selectionOperation == nil ? 0 : 1
        let panelPresentBefore = activePanel != nil

        lifecycle = .stopped
        advanceRevision()
        state = .stopped
        selectionCompletion = nil

        let restore = restoreOperation
        if let restore {
            logRestoreTerminal(
                operationID: restore.id,
                result: "invalidated",
                stale: false,
                startedAt: restore.startedAt
            )
        }
        restoreOperation = nil
        restore?.task?.cancel()

        let selection = selectionOperation
        if let selection {
            logSelectionTerminal(
                operationID: selection.id,
                source: selection.source,
                result: "invalidated",
                retainedPrevious: false,
                startedAt: selection.startedAt
            )
        }
        selectionOperation = nil
        selection?.task?.cancel()

        if let panel = activePanel {
            activePanel = nil
            NSApp.abortModal()
            panel.orderOut(nil)
        }

        Self.logger.info(
            "event=settings.lifecycle.stopped result=stopped restore_pending_before=\(restorePendingBefore, privacy: .public) restore_pending_after=0 selection_pending_before=\(selectionPendingBefore, privacy: .public) selection_pending_after=0 panel_present_before=\(panelPresentBefore, privacy: .public) panel_present_after=false"
        )
    }

    @discardableResult
    func chooseFolder(source: SaveFolderSelectionSource) -> SaveFolderSelectionID? {
        let operationID = SaveFolderSelectionID()
        guard lifecycle == .started else {
            logSelectionRejected(
                operationID: operationID,
                source: source,
                reason: "lifecycle_not_started"
            )
            return nil
        }
        guard activePanel == nil, selectionOperation == nil else {
            logSelectionRejected(
                operationID: operationID,
                source: source,
                reason: "selection_busy"
            )
            return nil
        }
        selectionCompletion = nil

        if let restoreOperation {
            logRestoreTerminal(
                operationID: restoreOperation.id,
                result: "invalidated_by_selection",
                stale: false,
                startedAt: restoreOperation.startedAt
            )
        }
        restoreOperation?.task?.cancel()
        restoreOperation = nil

        let previousState = restorableState(from: state)
        let previousDisplayName = readyDisplayName(from: previousState)
        advanceRevision()
        let revision = bookmarkRevision
        let startedAt = ContinuousClock().now
        selectionOperation = SelectionOperation(
            id: operationID,
            source: source,
            startedAt: startedAt,
            task: nil
        )
        state = .selecting(previousDisplayName: previousDisplayName)
        logSelectionStarted(operationID: operationID, source: source)

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = NSLocalizedString("settings.select_folder.prompt", comment: "")
        panel.message = NSLocalizedString("settings.select_folder.message", comment: "")
        activePanel = panel

        let response = panel.runModal()
        guard
            lifecycle == .started,
            activePanel === panel,
            selectionOperation?.id == operationID,
            bookmarkRevision == revision
        else {
            if activePanel === panel { activePanel = nil }
            return operationID
        }
        activePanel = nil

        guard response == .OK else {
            state = previousState
            selectionCompletion = SaveFolderSelectionCompletion(
                id: operationID,
                source: source,
                result: .cancelled
            )
            selectionOperation = nil
            logSelectionTerminal(
                operationID: operationID,
                source: source,
                result: "cancelled",
                retainedPrevious: previousDisplayName != nil,
                startedAt: startedAt
            )
            return operationID
        }
        guard let selectedURL = panel.url else {
            finishSelectionFailure(
                .unavailable,
                previousState: previousState,
                revision: revision,
                operationID: operationID,
                source: source,
                startedAt: startedAt
            )
            return operationID
        }

        let task = Task(
            name: "mio.folder.selection.\(operationID.rawValue.uuidString)",
            priority: .userInitiated
        ) { @MainActor [weak self] in
            do {
                let candidate = try await SecurityScopedBookmark.create(from: selectedURL)
                guard let self else { return }
                try self.commitSelectedFolder(
                    candidate,
                    revision: revision,
                    operationID: operationID,
                    source: source
                )
                self.logSelectionTerminal(
                    operationID: operationID,
                    source: source,
                    result: "selected",
                    retainedPrevious: previousDisplayName != nil,
                    startedAt: startedAt
                )
            } catch is CancellationError {
                guard let self else { return }
                self.finishCancelledSelection(
                    operationID: operationID,
                    revision: revision,
                    previousState: previousState,
                    source: source,
                    startedAt: startedAt
                )
            } catch let failure as SaveFolderFailure {
                guard let self else { return }
                self.finishSelectionFailure(
                    failure,
                    previousState: previousState,
                    revision: revision,
                    operationID: operationID,
                    source: source,
                    startedAt: startedAt
                )
            } catch {
                guard let self else { return }
                self.finishSelectionFailure(
                    .unavailable,
                    previousState: previousState,
                    revision: revision,
                    operationID: operationID,
                    source: source,
                    startedAt: startedAt
                )
            }
        }
        if selectionOperation?.id == operationID {
            selectionOperation?.task = task
        }
        return operationID
    }

    func withAccess<T: Sendable>(
        _ operation: @Sendable (URL) async throws -> T
    ) async throws -> T {
        let leaseID = UUID()
        let startedAt = ContinuousClock().now
        logScopeStarted(leaseID: leaseID)
        guard lifecycle == .started else {
            logScopeTerminal(
                leaseID: leaseID,
                startResult: "not_attempted",
                operationResult: "lifecycle_invalidated",
                stopCount: 0,
                startedAt: startedAt
            )
            throw CancellationError()
        }
        guard activePanel == nil, selectionOperation == nil else {
            logScopeTerminal(
                leaseID: leaseID,
                startResult: "not_attempted",
                operationResult: "selection_in_progress",
                stopCount: 0,
                startedAt: startedAt
            )
            throw CancellationError()
        }
        guard let originalData = currentBookmarkData else {
            state = .notSelected
            logScopeTerminal(
                leaseID: leaseID,
                startResult: "not_attempted",
                operationResult: SaveFolderFailure.missingBookmark.logCode,
                stopCount: 0,
                startedAt: startedAt
            )
            throw SaveFolderFailure.missingBookmark
        }

        let revision = bookmarkRevision
        guard !Task.isCancelled else {
            logScopeTerminal(
                leaseID: leaseID,
                startResult: "not_attempted",
                operationResult: "cancelled",
                stopCount: 0,
                startedAt: startedAt
            )
            throw CancellationError()
        }

        let prepared: PreparedSaveFolderBookmark
        do {
            prepared = try await SecurityScopedBookmark.resolve(originalData)
        } catch is CancellationError {
            logScopeTerminal(
                leaseID: leaseID,
                startResult: "not_attempted",
                operationResult: "cancelled",
                stopCount: 0,
                startedAt: startedAt
            )
            throw CancellationError()
        } catch let failure as SaveFolderFailure {
            commitAuthorizationFailureIfCurrent(
                failure,
                originalData: originalData,
                revision: revision
            )
            logScopeTerminal(
                leaseID: leaseID,
                startResult: "not_attempted",
                operationResult: failure.logCode,
                stopCount: 0,
                startedAt: startedAt
            )
            throw failure
        } catch {
            let failure = SaveFolderFailure.unavailable
            commitAuthorizationFailureIfCurrent(
                failure,
                originalData: originalData,
                revision: revision
            )
            logScopeTerminal(
                leaseID: leaseID,
                startResult: "not_attempted",
                operationResult: failure.logCode,
                stopCount: 0,
                startedAt: startedAt
            )
            throw failure
        }

        guard !Task.isCancelled else {
            logScopeTerminal(
                leaseID: leaseID,
                startResult: "not_attempted",
                operationResult: "cancelled",
                stopCount: 0,
                startedAt: startedAt
            )
            throw CancellationError()
        }
        guard matches(revision: revision, originalData: originalData) else {
            logScopeTerminal(
                leaseID: leaseID,
                startResult: "not_attempted",
                operationResult: "invalidated",
                stopCount: 0,
                startedAt: startedAt
            )
            throw CancellationError()
        }
        guard prepared.url.startAccessingSecurityScopedResource() else {
            let failure = SaveFolderFailure.accessDenied
            commitAuthorizationFailureIfCurrent(
                failure,
                originalData: originalData,
                revision: revision
            )
            logScopeTerminal(
                leaseID: leaseID,
                startResult: "false",
                operationResult: failure.logCode,
                stopCount: 0,
                startedAt: startedAt
            )
            throw failure
        }

        var operationResult = "completed"
        defer {
            prepared.url.stopAccessingSecurityScopedResource()
            logScopeTerminal(
                leaseID: leaseID,
                startResult: "true",
                operationResult: operationResult,
                stopCount: 1,
                startedAt: startedAt
            )
        }

        guard !Task.isCancelled else {
            operationResult = "cancelled"
            throw CancellationError()
        }
        guard matches(revision: revision, originalData: originalData) else {
            operationResult = "invalidated"
            throw CancellationError()
        }
        if let refreshedData = prepared.refreshedData {
            defaults.set(refreshedData, forKey: Self.bookmarkKey)
        }
        state = .ready(displayName: prepared.displayName)

        do {
            return try await operation(prepared.url)
        } catch is CancellationError {
            operationResult = "cancelled"
            throw CancellationError()
        } catch {
            operationResult = "operation_failed"
            throw error
        }
    }

    isolated deinit {
        restoreOperation?.task?.cancel()
        selectionOperation?.task?.cancel()
    }

    // MARK: - Restore completion

    private func completeRestore(
        _ prepared: PreparedSaveFolderBookmark,
        originalData: Data,
        revision: UInt64,
        operationID: UUID
    ) throws {
        guard matchesRestore(operationID: operationID, revision: revision, originalData: originalData) else {
            throw CancellationError()
        }
        guard prepared.url.startAccessingSecurityScopedResource() else {
            throw SaveFolderFailure.accessDenied
        }
        defer { prepared.url.stopAccessingSecurityScopedResource() }
        try Task.checkCancellation()
        guard matchesRestore(operationID: operationID, revision: revision, originalData: originalData) else {
            throw CancellationError()
        }

        if let refreshedData = prepared.refreshedData {
            defaults.set(refreshedData, forKey: Self.bookmarkKey)
        }
        state = .ready(displayName: prepared.displayName)
        restoreOperation = nil
    }

    private func finishCancelledRestore(
        operationID: UUID,
        revision: UInt64,
        startedAt: ContinuousClock.Instant
    ) {
        guard lifecycle == .started, restoreOperation?.id == operationID, bookmarkRevision == revision else { return }
        restoreOperation = nil
        let result: String
        if case .restoring = state {
            state = currentBookmarkData == nil ? .notSelected : .needsSelection(.unavailable)
            result = "cancelled"
        } else {
            // A concurrent matching lease may already have refreshed the same
            // bookmark and moved authorization to ready. Preserve that newer
            // observable truth instead of reintroducing a busy state.
            result = "invalidated"
        }
        logRestoreTerminal(operationID: operationID, result: result, stale: false, startedAt: startedAt)
    }

    private func finishFailedRestore(
        _ failure: SaveFolderFailure,
        originalData: Data,
        revision: UInt64,
        operationID: UUID,
        startedAt: ContinuousClock.Instant
    ) {
        guard
            lifecycle == .started,
            restoreOperation?.id == operationID,
            bookmarkRevision == revision
        else { return }
        guard currentBookmarkData == originalData else {
            restoreOperation = nil
            logRestoreTerminal(
                operationID: operationID,
                result: "invalidated",
                stale: false,
                startedAt: startedAt
            )
            return
        }
        restoreOperation = nil
        state = .needsSelection(failure)
        logRestoreTerminal(operationID: operationID, result: failure.logCode, stale: false, startedAt: startedAt)
    }

    // MARK: - Selection completion

    private func commitSelectedFolder(
        _ candidate: PreparedSaveFolderBookmark,
        revision: UInt64,
        operationID: SaveFolderSelectionID,
        source: SaveFolderSelectionSource
    ) throws {
        guard matchesSelection(operationID: operationID, revision: revision) else {
            throw CancellationError()
        }
        guard candidate.url.startAccessingSecurityScopedResource() else {
            throw SaveFolderFailure.accessDenied
        }
        defer { candidate.url.stopAccessingSecurityScopedResource() }
        try Task.checkCancellation()
        guard matchesSelection(operationID: operationID, revision: revision) else {
            throw CancellationError()
        }

        guard let committedData = candidate.refreshedData else {
            throw SaveFolderFailure.unavailable
        }
        defaults.set(committedData, forKey: Self.bookmarkKey)
        advanceRevision()
        state = .ready(displayName: candidate.displayName)
        selectionCompletion = SaveFolderSelectionCompletion(
            id: operationID,
            source: source,
            result: .selected(displayName: candidate.displayName)
        )
        selectionOperation = nil
    }

    private func finishCancelledSelection(
        operationID: SaveFolderSelectionID,
        revision: UInt64,
        previousState: SaveFolderAuthorizationState,
        source: SaveFolderSelectionSource,
        startedAt: ContinuousClock.Instant
    ) {
        guard lifecycle == .started, selectionOperation?.id == operationID, bookmarkRevision == revision else { return }
        state = previousState
        selectionCompletion = SaveFolderSelectionCompletion(
            id: operationID,
            source: source,
            result: .cancelled
        )
        selectionOperation = nil
        logSelectionTerminal(
            operationID: operationID,
            source: source,
            result: "cancelled",
            retainedPrevious: readyDisplayName(from: previousState) != nil,
            startedAt: startedAt
        )
    }

    private func finishSelectionFailure(
        _ failure: SaveFolderFailure,
        previousState: SaveFolderAuthorizationState,
        revision: UInt64,
        operationID: SaveFolderSelectionID,
        source: SaveFolderSelectionSource,
        startedAt: ContinuousClock.Instant
    ) {
        guard matchesSelection(operationID: operationID, revision: revision) else { return }
        let retainedPrevious = readyDisplayName(from: previousState) != nil
        state = retainedPrevious ? previousState : .needsSelection(failure)
        selectionCompletion = SaveFolderSelectionCompletion(
            id: operationID,
            source: source,
            result: .failed(failure, retainedPrevious: retainedPrevious)
        )
        selectionOperation = nil
        logSelectionTerminal(
            operationID: operationID,
            source: source,
            result: failure.logCode,
            retainedPrevious: retainedPrevious,
            startedAt: startedAt
        )
    }

    // MARK: - Gates and state

    private var currentBookmarkData: Data? {
        defaults.data(forKey: Self.bookmarkKey)
    }

    private func advanceRevision() {
        bookmarkRevision &+= 1
    }

    private func matches(revision: UInt64, originalData: Data) -> Bool {
        lifecycle == .started
            && bookmarkRevision == revision
            && currentBookmarkData == originalData
    }

    private func matchesRestore(operationID: UUID, revision: UInt64, originalData: Data) -> Bool {
        restoreOperation?.id == operationID && matches(revision: revision, originalData: originalData)
    }

    private func matchesSelection(operationID: SaveFolderSelectionID, revision: UInt64) -> Bool {
        lifecycle == .started
            && selectionOperation?.id == operationID
            && bookmarkRevision == revision
    }

    private func commitAuthorizationFailureIfCurrent(
        _ failure: SaveFolderFailure,
        originalData: Data,
        revision: UInt64
    ) {
        guard matches(revision: revision, originalData: originalData) else { return }
        state = failure == .missingBookmark ? .notSelected : .needsSelection(failure)
    }

    private func restorableState(from state: SaveFolderAuthorizationState) -> SaveFolderAuthorizationState {
        switch state {
        case .ready, .needsSelection, .notSelected:
            state
        case .restoring, .selecting, .stopped:
            .notSelected
        }
    }

    private func readyDisplayName(from state: SaveFolderAuthorizationState) -> String? {
        guard case let .ready(displayName) = state else { return nil }
        return displayName
    }

    // MARK: - Privacy-safe logging

    private func logRestoreStarted(operationID: UUID) {
        Self.logger.info(
            "event=folder.restore.started correlation_id=\(operationID.uuidString, privacy: .public) operation_id=\(operationID.uuidString, privacy: .public) source=system result=started"
        )
    }

    private func logRestoreTerminal(
        operationID: UUID,
        result: String,
        stale: Bool,
        startedAt: ContinuousClock.Instant
    ) {
        Self.logger.info(
            "event=folder.restore.finished correlation_id=\(operationID.uuidString, privacy: .public) operation_id=\(operationID.uuidString, privacy: .public) source=system result=\(result, privacy: .public) stale=\(stale, privacy: .public) duration_ms=\(Self.durationMilliseconds(since: startedAt), privacy: .public)"
        )
    }

    private func logSelectionStarted(
        operationID: SaveFolderSelectionID,
        source: SaveFolderSelectionSource
    ) {
        Self.logger.info(
            "event=folder.selection.started correlation_id=\(operationID.rawValue.uuidString, privacy: .public) operation_id=\(operationID.rawValue.uuidString, privacy: .public) source=\(source.rawValue, privacy: .public) result=started"
        )
    }

    private func logSelectionRejected(
        operationID: SaveFolderSelectionID,
        source: SaveFolderSelectionSource,
        reason: String
    ) {
        Self.logger.info(
            "event=folder.selection.rejected correlation_id=\(operationID.rawValue.uuidString, privacy: .public) operation_id=\(operationID.rawValue.uuidString, privacy: .public) source=\(source.rawValue, privacy: .public) result=rejected reason=\(reason, privacy: .public)"
        )
    }

    private func logSelectionTerminal(
        operationID: SaveFolderSelectionID,
        source: SaveFolderSelectionSource,
        result: String,
        retainedPrevious: Bool,
        startedAt: ContinuousClock.Instant
    ) {
        Self.logger.info(
            "event=folder.selection.finished correlation_id=\(operationID.rawValue.uuidString, privacy: .public) operation_id=\(operationID.rawValue.uuidString, privacy: .public) source=\(source.rawValue, privacy: .public) result=\(result, privacy: .public) retained_previous=\(retainedPrevious, privacy: .public) duration_ms=\(Self.durationMilliseconds(since: startedAt), privacy: .public)"
        )
    }

    private func logScopeStarted(leaseID: UUID) {
        Self.logger.info(
            "event=folder.scope.started correlation_id=\(leaseID.uuidString, privacy: .public) lease_id=\(leaseID.uuidString, privacy: .public) source=output result=started"
        )
    }

    private func logScopeTerminal(
        leaseID: UUID,
        startResult: String,
        operationResult: String,
        stopCount: Int,
        startedAt: ContinuousClock.Instant
    ) {
        Self.logger.info(
            "event=folder.scope.finished correlation_id=\(leaseID.uuidString, privacy: .public) lease_id=\(leaseID.uuidString, privacy: .public) source=output start_result=\(startResult, privacy: .public) operation_result=\(operationResult, privacy: .public) stop_count=\(stopCount, privacy: .public) duration_ms=\(Self.durationMilliseconds(since: startedAt), privacy: .public)"
        )
    }

    private static func durationMilliseconds(since start: ContinuousClock.Instant) -> Int64 {
        let components = start.duration(to: ContinuousClock().now).components
        return components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
    }
}
