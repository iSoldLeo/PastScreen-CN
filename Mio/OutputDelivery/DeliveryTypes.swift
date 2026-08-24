//
//  DeliveryTypes.swift
//  Mio
//
//  Immutable module-07 request, policy and cumulative outcome values.
//  These values deliberately contain no path, bookmark, sound or UI state.
//

import Foundation

nonisolated struct CaptureTimestamp: Sendable, Equatable {
    let instant: Date
    let timeZoneIdentifier: String
}

nonisolated enum FileOrganization: Sendable, Equatable {
    case root
    case yearAndMonth
}

nonisolated enum DeliveryPolicy: Sendable, Equatable {
    case clipboardOnly
    case fileAndClipboard(organization: FileOrganization)

    init(preferences: CapturePreferencesSnapshot) {
        if preferences.saveToFile {
            self = .fileAndClipboard(
                organization: preferences.organizeByMonth ? .yearAndMonth : .root
            )
        } else {
            self = .clipboardOnly
        }
    }

    var fileOrganization: FileOrganization? {
        guard case let .fileAndClipboard(organization) = self else { return nil }
        return organization
    }

    var logCode: String {
        switch self {
        case .clipboardOnly:
            "clipboard_only"
        case .fileAndClipboard(.root):
            "file_and_clipboard_root"
        case .fileAndClipboard(.yearAndMonth):
            "file_and_clipboard_year_month"
        }
    }
}

nonisolated struct DeliveryRequest: Sendable {
    let correlationID: UUID
    let image: CaptureImage
    let capturedAt: CaptureTimestamp
    let policy: DeliveryPolicy
}

nonisolated enum FileDeliveryFailure: Error, Sendable, Equatable {
    case pngEncodingFailed
    case authorization(SaveFolderFailure)
    case authorizationUnavailable
    case invalidCaptureTimestamp
    case directoryCreationFailed
    case permissionDenied
    case diskFull
    case nameAllocationFailed
    case temporaryWriteFailed
    case atomicPublishUnsupported
    case atomicPublishFailed

    var logCode: String {
        switch self {
        case .pngEncodingFailed: "png_encoding_failed"
        case let .authorization(failure): "authorization_\(failure.logCode)"
        case .authorizationUnavailable: "authorization_unavailable"
        case .invalidCaptureTimestamp: "invalid_capture_timestamp"
        case .directoryCreationFailed: "directory_creation_failed"
        case .permissionDenied: "permission_denied"
        case .diskFull: "disk_full"
        case .nameAllocationFailed: "name_allocation_failed"
        case .temporaryWriteFailed: "temporary_write_failed"
        case .atomicPublishUnsupported: "atomic_publish_unsupported"
        case .atomicPublishFailed: "atomic_publish_failed"
        }
    }
}

nonisolated enum ClipboardDeliveryFailure: Error, Sendable, Equatable {
    case noEncodableRepresentation
    case representationRejected
    case writeRejected

    var logCode: String {
        switch self {
        case .noEncodableRepresentation: "no_encodable_representation"
        case .representationRejected: "representation_rejected"
        case .writeRejected: "write_rejected"
        }
    }
}

nonisolated enum FileDeliveryOutcome: Sendable, Equatable {
    case notRequested
    case saved
    case failed(FileDeliveryFailure)
    case cancelledBeforeAttempt
    case cancelledDuringAttempt

    var isSuccessful: Bool {
        if case .saved = self { return true }
        return false
    }

    var isCancelledBeforeAttempt: Bool {
        if case .cancelledBeforeAttempt = self { return true }
        return false
    }

    var isPending: Bool {
        switch self {
        case .failed, .cancelledBeforeAttempt, .cancelledDuringAttempt: true
        case .notRequested, .saved: false
        }
    }

    var logCode: String {
        switch self {
        case .notRequested: "not_requested"
        case .saved: "saved"
        case let .failed(failure): "failed_\(failure.logCode)"
        case .cancelledBeforeAttempt: "cancelled_before_attempt"
        case .cancelledDuringAttempt: "cancelled_during_attempt"
        }
    }
}

nonisolated enum ClipboardDeliveryOutcome: Sendable, Equatable {
    case copied
    case failed(ClipboardDeliveryFailure)
    case cancelledBeforeAttempt

    var isSuccessful: Bool {
        if case .copied = self { return true }
        return false
    }

    var isCancelledBeforeAttempt: Bool {
        if case .cancelledBeforeAttempt = self { return true }
        return false
    }

    var isPending: Bool {
        switch self {
        case .failed, .cancelledBeforeAttempt: true
        case .copied: false
        }
    }

    var logCode: String {
        switch self {
        case .copied: "copied"
        case let .failed(failure): "failed_\(failure.logCode)"
        case .cancelledBeforeAttempt: "cancelled_before_attempt"
        }
    }
}

nonisolated enum DeliveryCompletion: String, Sendable, Equatable {
    case complete
    case partial
    case failed
    case cancelled
}

nonisolated struct DeliveryOutcome: Sendable, Equatable {
    let file: FileDeliveryOutcome
    let clipboard: ClipboardDeliveryOutcome
    let completion: DeliveryCompletion

    private init(
        file: FileDeliveryOutcome,
        clipboard: ClipboardDeliveryOutcome,
        completion: DeliveryCompletion
    ) {
        self.file = file
        self.clipboard = clipboard
        self.completion = completion
    }

    static func derive(
        policy: DeliveryPolicy,
        file: FileDeliveryOutcome,
        clipboard: ClipboardDeliveryOutcome
    ) -> DeliveryOutcome {
        validateShape(policy: policy, file: file)

        let fileRequested = policy.fileOrganization != nil
        let requestedCount = fileRequested ? 2 : 1
        let successCount = (file.isSuccessful ? 1 : 0) + (clipboard.isSuccessful ? 1 : 0)
        let allCancelledBeforeAttempt = clipboard.isCancelledBeforeAttempt
            && (!fileRequested || file.isCancelledBeforeAttempt)

        let completion: DeliveryCompletion
        if allCancelledBeforeAttempt {
            completion = .cancelled
        } else if successCount == requestedCount {
            completion = .complete
        } else if successCount > 0 {
            completion = .partial
        } else {
            completion = .failed
        }

        return DeliveryOutcome(file: file, clipboard: clipboard, completion: completion)
    }

    static func validateShape(policy: DeliveryPolicy, file: FileDeliveryOutcome) {
        switch policy {
        case .clipboardOnly:
            precondition(file == .notRequested, "clipboardOnly requires file.notRequested")
        case .fileAndClipboard:
            precondition(file != .notRequested, "fileAndClipboard requires a requested file outcome")
        }
    }

    var hasSuccessfulSink: Bool {
        file.isSuccessful || clipboard.isSuccessful
    }
}
