//
//  CaptureSession.swift
//  Mio
//
//  Stable module-03 command admission values. Presentation, acquisition,
//  delivery and editor payloads remain owned by their feature modules.
//

import Foundation

nonisolated struct CaptureSessionID: Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

nonisolated enum CapturePhase: String, Sendable, Equatable {
    case preparing
    case selectingArea = "selecting_area"
    case choosingScreen = "choosing_screen"
    case finalizing
}

nonisolated enum CaptureStartRejection: Sendable, Equatable {
    case busy(activeSessionID: CaptureSessionID, phase: CapturePhase)
    case stopped
}

nonisolated enum CaptureStartDisposition: Sendable, Equatable {
    case accepted(CaptureSessionID)
    case rejected(CaptureStartRejection)
}

/// Only reasons with a production source are present. Module 05 adds
/// `selectionPresentationLost`; module 12 已扩展本枚举（`systemSuspension` /
/// `userSessionResign` / `displayEnvironmentChange`）。
nonisolated enum CaptureCancellationReason: String, Sendable, Equatable {
    case userInteraction = "user_interaction"
    case taskCancellation = "task_cancellation"
    case applicationStopping = "application_stopping"
    case selectionPresentationLost = "selection_presentation_lost"
    // Module-12 system lifecycle sources (M12-03).
    case systemSuspension = "system_suspension"
    case userSessionResign = "user_session_resign"
    case displayEnvironmentChange = "display_environment_change"
}
