//
//  SelectionPresenter.swift
//  Mio
//
//  Module 05's sole owner of area/screen presentation. A process-lifetime
//  @MainActor presenter holds at most one internal one-shot presentation; the
//  presentation owns its panels, the awaiting continuation, and every teardown
//  path. There is no shell NSWindow, no global event monitor, and no live
//  WindowServer query — Escape arrives through a nonactivating key panel's
//  responder chain, and the presentation is the sole orderer/closer of its
//  panels so termination signals are deterministic (windowWillClose + a
//  focus-loss check), all funnelling into one idempotent finish.
//

import AppKit
import Foundation
import OSLog

// MARK: - Shared nonactivating panel

@MainActor
final class SelectionPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        // The presentation owns lifetime and calls close() during finish; it
        // must not deallocate the panel while its view is mid-event.
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Presenter

@MainActor
final class SelectionPresenter {
    private var active: SelectionPresentation?

    func selectArea(
        input: AreaSelectionInput,
        sessionID: CaptureSessionID
    ) async throws -> AreaSelectionDecision {
        try Self.validate(input.screens)
        let outcome = try await run(kind: .area, sessionID: sessionID) { presentation in
            presentation.buildAreaPanels(input: input)
        }
        guard case let .area(decision) = outcome else {
            preconditionFailure("area presentation produced a non-area outcome")
        }
        return decision
    }

    func chooseScreen(
        input: ScreenChoiceInput,
        sessionID: CaptureSessionID
    ) async throws -> ScreenChoiceDecision {
        try Self.validate(input.screens)
        guard input.screens.ordered.count >= 2 else {
            throw SelectionPresentationError.insufficientScreensForChooser(count: input.screens.ordered.count)
        }
        let outcome = try await run(kind: .screen, sessionID: sessionID) { presentation in
            presentation.buildScreenPanels(input: input)
        }
        guard case let .screen(decision) = outcome else {
            preconditionFailure("screen presentation produced a non-screen outcome")
        }
        return decision
    }

    private func run(
        kind: SelectionPresentation.Kind,
        sessionID: CaptureSessionID,
        build: @escaping (SelectionPresentation) -> Void
    ) async throws -> SelectionOutcome {
        guard active == nil else { throw SelectionPresentationError.alreadyPresenting }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let presentation = SelectionPresentation(
                    sessionID: sessionID,
                    kind: kind,
                    onFinished: { [weak self] in self?.active = nil }
                )
                build(presentation)
                do {
                    try presentation.start(continuation: continuation)
                    active = presentation
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(sessionID: sessionID)
            }
        }
    }

    /// Matching-identity teardown entry. Used both by 03's synchronous terminal
    /// path and by the async cancellation fallback; only the presentation that
    /// belongs to `sessionID` is torn down, so a stale cancel cannot end a
    /// later session's presentation. Idempotent via the one-shot finish.
    func cancel(sessionID: CaptureSessionID) {
        guard let active, active.sessionID == sessionID else { return }
        active.finishByTaskCancellation()
    }

    private static func validate(_ screens: FrozenScreens) throws {
        guard !screens.ordered.isEmpty else { throw SelectionPresentationError.emptyScreens }
        var seen: Set<CGDirectDisplayID> = []
        for screen in screens.ordered {
            guard seen.insert(screen.displayID).inserted else {
                throw SelectionPresentationError.duplicateDisplayID(screen.displayID)
            }
            let frame = screen.frameInAppKitPoints
            guard frame.width > 0, frame.height > 0,
                  frame.width.isFinite, frame.height.isFinite,
                  frame.minX.isFinite, frame.minY.isFinite else {
                throw SelectionPresentationError.invalidScreenGeometry(screen.displayID)
            }
        }
    }
}

// MARK: - Internal erased outcome

enum SelectionOutcome: Sendable {
    case area(AreaSelectionDecision)
    case screen(ScreenChoiceDecision)
}

// MARK: - One-shot presentation

@MainActor
final class SelectionPresentation: NSObject, NSWindowDelegate {
    enum Kind { case area, screen }
    private enum Phase { case building, visible, finished }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.iSoldLeo.Mio",
        category: "selection"
    )

    let presentationID = UUID()
    let sessionID: CaptureSessionID
    let kind: Kind

    private var phase: Phase = .building
    private var panels: [SelectionPanel] = []
    private var continuation: CheckedContinuation<SelectionOutcome, Error>?
    private var focusCheckTask: Task<Void, Never>?
    private let onFinished: () -> Void

    init(sessionID: CaptureSessionID, kind: Kind, onFinished: @escaping () -> Void) {
        self.sessionID = sessionID
        self.kind = kind
        self.onFinished = onFinished
        super.init()
    }

    // MARK: Build

    func buildAreaPanels(input: AreaSelectionInput) {
        for screen in input.screens.ordered {
            let view = AreaSelectionView(
                frame: NSRect(origin: .zero, size: screen.frameInAppKitPoints.size),
                configuration: .screenshot,
                displayID: screen.displayID,
                backgroundImage: screen.image
            )
            view.onDecision = { [weak self] decision in self?.finish(.area(decision)) }
            appendPanel(frame: screen.frameInAppKitPoints, view: view)
        }
    }

    func buildScreenPanels(input: ScreenChoiceInput) {
        for screen in input.screens.ordered {
            let view = ScreenChoiceView(
                frame: NSRect(origin: .zero, size: screen.frameInAppKitPoints.size),
                displayID: screen.displayID,
                backgroundImage: screen.image
            )
            view.onDecision = { [weak self] decision in self?.finish(.screen(decision)) }
            appendPanel(frame: screen.frameInAppKitPoints, view: view)
        }
    }

    private func appendPanel(frame: CGRect, view: NSView) {
        let panel = SelectionPanel(contentRect: frame)
        panel.setFrame(frame, display: false)
        panel.delegate = self
        panel.contentView = view
        panels.append(panel)
    }

    // MARK: Show

    /// Orders all panels front without activating Mio, establishes a keyboard
    /// anchor for responder-chain Escape, and only then stores the continuation.
    func start(continuation: CheckedContinuation<SelectionOutcome, Error>) throws {
        for panel in panels {
            panel.ignoresMouseEvents = false
            panel.orderFrontRegardless()
        }
        guard let anchor = anchorPanel() else {
            teardownPanels()
            throw SelectionPresentationError.emptyScreens
        }
        anchor.makeKeyAndOrderFront(nil)
        guard let anchorView = anchor.contentView, anchor.makeFirstResponder(anchorView) else {
            teardownPanels()
            throw SelectionPresentationError.keyboardFocusUnavailable
        }
        self.continuation = continuation
        phase = .visible
        Self.logger.info(
            "event=selection.presentation_visible session_id=\(self.sessionID.rawValue.uuidString, privacy: .public) presentation_id=\(self.presentationID.uuidString, privacy: .public) panel_count=\(self.panels.count, privacy: .public)"
        )
        // Establishment check: makeFirstResponder succeeding does not prove the
        // nonactivating panel actually took keyboard ownership. If no owned
        // panel is key on the next turn, fail closed (focusLost) rather than
        // leaving an overlay whose only Escape path is dead.
        scheduleFocusCheck()
    }

    private func anchorPanel() -> SelectionPanel? {
        let mouse = NSEvent.mouseLocation
        return panels.first(where: { $0.frame.contains(mouse) }) ?? panels.first
    }

    // MARK: Terminal signals (all funnel into one idempotent finish)

    func finish(_ outcome: SelectionOutcome) { complete(.success(outcome)) }

    func finishByTaskCancellation() { complete(.failure(CancellationError())) }

    private func finishCancelled(_ trigger: SelectionCancelTrigger) {
        switch kind {
        case .area: complete(.success(.area(.cancelled(trigger))))
        case .screen: complete(.success(.screen(.cancelled(trigger))))
        }
    }

    // NSWindowDelegate is @MainActor on the current SDK. The presentation is the
    // sole orderer/closer of its panels; observers are removed (delegate = nil)
    // before our own close(), so windowWillClose only fires for external closes.
    func windowWillClose(_ notification: Notification) {
        finishCancelled(.unexpectedClose)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard phase == .visible else { return }
        scheduleFocusCheck()
    }

    /// Next-turn check for keyboard ownership. Replaces any prior check; the
    /// superseded task observes cancellation after `yield` and returns without
    /// acting, so only the current, non-cancelled check can decide focus loss.
    private func scheduleFocusCheck() {
        focusCheckTask?.cancel()
        focusCheckTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled, self.phase == .visible else { return }
            if !self.panels.contains(where: { $0.isKeyWindow }) {
                self.finishCancelled(.focusLost)
            } else {
                // Successful handoff: clear the now-completed handle.
                self.focusCheckTask = nil
            }
        }
    }

    private func complete(_ result: Result<SelectionOutcome, Error>) {
        guard phase == .visible, let continuation else {
            // One-shot: late/duplicate signals (repeat Escape, reentrant
            // windowWillClose, cancel after decision) are ignored.
            if phase != .finished {
                Self.logger.debug("event=selection.stale_event_ignored presentation_id=\(self.presentationID.uuidString, privacy: .public)")
            }
            return
        }
        phase = .finished
        self.continuation = nil
        focusCheckTask?.cancel()
        focusCheckTask = nil
        let panelCount = panels.count
        teardownPanels()
        onFinished()
        logTerminal(result, panelCount: panelCount)
        continuation.resume(with: result)
    }

    private func logTerminal(_ result: Result<SelectionOutcome, Error>, panelCount: Int) {
        switch result {
        case let .success(outcome):
            switch outcome {
            case .area(.rectangle):
                logEvent("decision", detail: "kind=rectangle")
            case .area(.window):
                logEvent("decision", detail: "kind=window")
            case .screen(.selected):
                logEvent("decision", detail: "kind=screen")
            case let .area(.cancelled(trigger)), let .screen(.cancelled(trigger)):
                logEvent("cancelled", detail: "trigger=\(Self.triggerCode(trigger))")
            }
        case .failure:
            logEvent("task_cancellation_observed", detail: "")
        }
        logEvent("dismissed", detail: "panel_count=\(panelCount) order_out_count=\(panelCount) close_count=\(panelCount)")
    }

    private func logEvent(_ event: StaticString, detail: String) {
        Self.logger.info(
            "event=selection.\(event) session_id=\(self.sessionID.rawValue.uuidString, privacy: .public) presentation_id=\(self.presentationID.uuidString, privacy: .public) \(detail, privacy: .public)"
        )
    }

    private static func triggerCode(_ trigger: SelectionCancelTrigger) -> String {
        switch trigger {
        case let .user(user):
            switch user {
            case .escape: "user_escape"
            case .rightClick: "user_right_click"
            case .tooSmall: "user_too_small"
            }
        case .focusLost: "focus_lost"
        case .presentationInvisible: "presentation_invisible"
        case .unexpectedClose: "unexpected_close"
        }
    }

    private func teardownPanels() {
        for panel in panels {
            (panel.contentView as? AreaSelectionView)?.onDecision = nil
            (panel.contentView as? ScreenChoiceView)?.onDecision = nil
            panel.delegate = nil
            panel.ignoresMouseEvents = true
        }
        for panel in panels { panel.orderOut(nil) }
        for panel in panels { panel.close() }
        panels.removeAll()
    }
}
