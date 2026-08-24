//
//  Shortcut.swift
//  Mio
//
//  Stable, layout-independent shortcut values and product validation.
//

import Foundation

nonisolated enum ShortcutAction: String, CaseIterable, Codable, Sendable {
    case windowCapture
    case advancedWindowCapture
    case fullScreenCapture
}

nonisolated struct ShortcutModifiers: OptionSet, Hashable, Codable, Sendable {
    let rawValue: UInt8

    init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    static let command = Self(rawValue: 1 << 0)
    static let option = Self(rawValue: 1 << 1)
    static let shift = Self(rawValue: 1 << 2)
    static let control = Self(rawValue: 1 << 3)

    static let supported: Self = [.command, .option, .shift, .control]
    static let primary: Self = [.command, .option, .control]
}

nonisolated struct Shortcut: Hashable, Codable, Sendable {
    let keyCode: UInt16
    let modifiers: ShortcutModifiers
}

nonisolated enum ShortcutAssignment: Hashable, Codable, Sendable {
    case disabled
    case assigned(Shortcut)

    var shortcut: Shortcut? {
        guard case let .assigned(shortcut) = self else { return nil }
        return shortcut
    }
}

nonisolated struct ShortcutAssignments: Equatable, Codable, Sendable {
    var windowCapture: ShortcutAssignment
    var advancedWindowCapture: ShortcutAssignment
    var fullScreenCapture: ShortcutAssignment

    subscript(action: ShortcutAction) -> ShortcutAssignment {
        get {
            switch action {
            case .windowCapture: windowCapture
            case .advancedWindowCapture: advancedWindowCapture
            case .fullScreenCapture: fullScreenCapture
            }
        }
        set {
            switch action {
            case .windowCapture: windowCapture = newValue
            case .advancedWindowCapture: advancedWindowCapture = newValue
            case .fullScreenCapture: fullScreenCapture = newValue
            }
        }
    }

    static let productDefaults = Self(
        windowCapture: .assigned(Shortcut(
            keyCode: 1,
            modifiers: [.option, .command]
        )),
        advancedWindowCapture: .assigned(Shortcut(
            keyCode: 14,
            modifiers: [.option, .command]
        )),
        fullScreenCapture: .assigned(Shortcut(
            keyCode: 5,
            modifiers: [.option, .command]
        ))
    )
}

nonisolated struct ShortcutStorePayload: Equatable, Codable, Sendable {
    let schemaVersion: UInt8
    let assignments: ShortcutAssignments
}

nonisolated enum ShortcutRegistrationFailure: Equatable, Sendable {
    nonisolated enum Operation: String, Sendable {
        case installHandler
        case register
        case unregister
        case removeHandler
    }

    case platform(operation: Operation, osStatus: Int32)
    case registrationIdentifierExhausted
}

nonisolated enum ShortcutRegistrationState: Equatable, Sendable {
    case notStarted
    case disabled
    case registered(Shortcut)
    case failed(desired: ShortcutAssignment, failure: ShortcutRegistrationFailure)
}

nonisolated enum ShortcutPersistenceFailure: String, Equatable, Sendable {
    case encodingFailed
}

nonisolated enum ShortcutValidationFailure: Equatable, Sendable {
    case unsupportedModifierBits
    case primaryModifierRequired
    case duplicate(existingAction: ShortcutAction)
}

nonisolated enum ShortcutSemanticFailure: Equatable, Sendable {
    case unsupportedModifierBits(action: ShortcutAction)
    case primaryModifierRequired(action: ShortcutAction)
    case duplicateAssignments(first: ShortcutAction, second: ShortcutAction)
}

nonisolated enum ShortcutStoreCommitFailure: Error, Equatable, Sendable {
    case semanticInvalid(ShortcutSemanticFailure)
    case persistence(ShortcutPersistenceFailure)
}

nonisolated enum ShortcutStoreLoadDisposition: Equatable, Sendable {
    case loaded
    case missingDefaulted
    case decodeFailedDefaulted
    case unsupportedVersionDefaulted
    case semanticInvalidDefaulted(ShortcutSemanticFailure)
}

nonisolated enum ShortcutReconcileReason: String, Sendable {
    case systemWake
    case sessionBecameActive
}

nonisolated enum ShortcutReconcileOutcome: Equatable, Sendable {
    case healthy
    case degraded(failedActions: [ShortcutAction])
    case failed(ShortcutRegistrationFailure)
    case serviceStopped
}

nonisolated enum ShortcutRecordingHost: String, Equatable, Sendable {
    case settings
    case onboarding
}

nonisolated struct RecorderOwnerID: Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

nonisolated struct RecordingSessionID: Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

nonisolated enum RecordingEndReason: String, Equatable, Sendable {
    case saved
    case saveFailed
    case cancelled
    case monitorInstallationFailed
    case windowResigned
    case windowClosed
    case viewDetached
    case hostHidden
    case pageChanged
    case hostCompleted
    case serviceStopped
    case deinitialized
}

nonisolated enum BeginRecordingRejection: Equatable, Sendable {
    case recordingBusy
    case serviceNotStarted
}

nonisolated enum BeginRecordingOutcome: Equatable, Sendable {
    case started(RecordingSessionID)
    case rejected(BeginRecordingRejection)
}

nonisolated enum ShortcutMutationOutcome: Equatable, Sendable {
    case applied(ShortcutRegistrationState)
    case rejectedValidation(ShortcutValidationFailure)
    case rejectedStore(ShortcutStoreCommitFailure)
    case rejectedRecordingActive
    case rejectedStaleSession
    case rejectedServiceNotStarted
}

nonisolated enum ShortcutStopOutcome: Equatable, Sendable {
    case stoppedCleanly
    case cleanupFailed(
        residualRegistrationCount: Int,
        handlerRetained: Bool,
        failures: [ShortcutRegistrationFailure]
    )
}

nonisolated enum ShortcutValidator {
    // HIToolbox virtual key codes. This explicit set is the approved D-001-C
    // bare-key allowlist; it must not be widened to navigation or text keys.
    private static let bareKeyCodes: Set<UInt16> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109,
        103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
        114 // kVK_Help; the physical PC key is labelled Insert.
    ]

    static func validate(
        action: ShortcutAction,
        candidate: Shortcut,
        in assignments: ShortcutAssignments
    ) -> ShortcutValidationFailure? {
        guard candidate.modifiers.subtracting(.supported).isEmpty else {
            return .unsupportedModifierBits
        }

        let hasPrimaryModifier = !candidate.modifiers.intersection(.primary).isEmpty
        guard hasPrimaryModifier || bareKeyCodes.contains(candidate.keyCode) else {
            return .primaryModifierRequired
        }

        for otherAction in ShortcutAction.allCases where otherAction != action {
            if assignments[otherAction].shortcut == candidate {
                return .duplicate(existingAction: otherAction)
            }
        }

        return nil
    }

    static func validateSnapshot(
        _ assignments: ShortcutAssignments
    ) -> ShortcutSemanticFailure? {
        for action in ShortcutAction.allCases {
            guard let shortcut = assignments[action].shortcut else { continue }

            guard shortcut.modifiers.subtracting(.supported).isEmpty else {
                return .unsupportedModifierBits(action: action)
            }

            let hasPrimaryModifier = !shortcut.modifiers.intersection(.primary).isEmpty
            guard hasPrimaryModifier || bareKeyCodes.contains(shortcut.keyCode) else {
                return .primaryModifierRequired(action: action)
            }
        }

        let actions = ShortcutAction.allCases
        for firstIndex in actions.indices {
            let first = actions[firstIndex]
            guard let firstShortcut = assignments[first].shortcut else { continue }

            for secondIndex in actions.index(after: firstIndex)..<actions.endIndex {
                let second = actions[secondIndex]
                if assignments[second].shortcut == firstShortcut {
                    return .duplicateAssignments(first: first, second: second)
                }
            }
        }

        return nil
    }
}
