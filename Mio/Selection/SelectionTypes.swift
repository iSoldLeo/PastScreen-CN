//
//  SelectionTypes.swift
//  Mio
//
//  Module 05 value boundary. 04-owned types (FrozenScreens,
//  CaptureWindowDescriptor, CaptureImage) are consumed by reference from
//  AcquisitionTypes.swift; 05 declares only its own inputs, decisions and
//  typed errors. No AppKit object crosses this boundary.
//

import CoreGraphics
import Foundation

/// Immutable input for an area/window selection presentation. Window hover is
/// resolved live via WindowHitTester, so no frozen window catalog is carried.
nonisolated struct AreaSelectionInput: Sendable {
    let screens: FrozenScreens
}

/// Immutable input for a multi-display screen chooser presentation.
nonisolated struct ScreenChoiceInput: Sendable {
    let screens: FrozenScreens
}

/// A rectangle chosen inside a single frozen display. The origin is that
/// display's bottom-left in AppKit points, so 03/06 never guess the source
/// display from a global rect centre.
nonisolated struct CropRequest: Sendable, Equatable {
    let displayID: CGDirectDisplayID
    let rectInDisplayPoints: CGRect
}

/// A window chosen by the user. Carries the full trigger descriptor so 03 can
/// hand it straight to 04's `captureWindowOnDemand(expected:)`, which matches
/// `windowID + ownerPID`.
nonisolated struct WindowSelection: Sendable, Equatable {
    let descriptor: CaptureWindowDescriptor
}

/// The user-driven cancel sources 05 can distinguish.
nonisolated enum UserCancelTrigger: Sendable, Equatable {
    case escape
    case rightClick
    case tooSmall
}

/// 05-local typed cancel source. 03 owns the session terminal and maps this to
/// its own `CaptureCancellationReason`; 05 never defines a session terminal.
nonisolated enum SelectionCancelTrigger: Sendable, Equatable {
    case user(UserCancelTrigger)
    case focusLost
    case presentationInvisible
    case unexpectedClose
}

nonisolated enum AreaSelectionDecision: Sendable, Equatable {
    case rectangle(CropRequest)
    case window(WindowSelection)
    case cancelled(SelectionCancelTrigger)
}

nonisolated enum ScreenChoiceDecision: Sendable, Equatable {
    case selected(CGDirectDisplayID)
    case cancelled(SelectionCancelTrigger)
}

/// Setup failures that must be reported before any panel becomes visible, or
/// when a keyboard anchor cannot be established. External Task cancellation is
/// NOT one of these — that path throws `CancellationError` after teardown.
nonisolated enum SelectionPresentationError: Error, Sendable, Equatable {
    case alreadyPresenting
    case emptyScreens
    case insufficientScreensForChooser(count: Int)
    case duplicateDisplayID(CGDirectDisplayID)
    case invalidScreenGeometry(CGDirectDisplayID)
    case keyboardFocusUnavailable
}
