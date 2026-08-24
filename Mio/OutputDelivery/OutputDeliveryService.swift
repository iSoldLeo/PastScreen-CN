//
//  OutputDeliveryService.swift
//  Mio
//
//  The sole owner of sink ordering and cumulative DeliveryOutcome derivation.
//  It creates no Task: caller-owned structured awaits define its lifetime.
//

import AppKit
import Foundation
import OSLog

actor OutputDeliveryService {
    nonisolated private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.iSoldLeo.Mio",
        category: "output.delivery"
    )

    private let fileOutput: FileOutputService
    private let clipboardOutput: ClipboardOutputService

    init(fileOutput: FileOutputService, clipboardOutput: ClipboardOutputService) {
        self.fileOutput = fileOutput
        self.clipboardOutput = clipboardOutput
    }

    func deliver(_ request: DeliveryRequest) async -> DeliveryOutcome {
        await perform(request, previous: nil, operation: "initial")
    }

    func retryPendingSinks(
        originalRequest: DeliveryRequest,
        after previous: DeliveryOutcome
    ) async -> DeliveryOutcome {
        DeliveryOutcome.validateShape(policy: originalRequest.policy, file: previous.file)
        guard previous.file.isPending || previous.clipboard.isPending else {
            let operationID = UUID()
            Self.logger.info(
                "event=delivery.retry.noop correlation_id=\(originalRequest.correlationID.uuidString, privacy: .public) operation_id=\(operationID.uuidString, privacy: .public) result=already_complete duration_ms=0"
            )
            return previous
        }

        return await perform(originalRequest, previous: previous, operation: "retry")
    }

    private func perform(
        _ request: DeliveryRequest,
        previous: DeliveryOutcome?,
        operation: StaticString
    ) async -> DeliveryOutcome {
        let operationID = UUID()
        let startedAt = ContinuousClock().now
        Self.logger.info(
            "event=delivery.started correlation_id=\(request.correlationID.uuidString, privacy: .public) operation_id=\(operationID.uuidString, privacy: .public) operation=\(operation, privacy: .public) policy=\(request.policy.logCode, privacy: .public)"
        )
        let encoded = encodeRepresentations(
            for: request.image,
            needsClipboard: previous?.clipboard.isPending ?? true
        )

        let clipboard: ClipboardDeliveryOutcome
        if let previous, !previous.clipboard.isPending {
            clipboard = previous.clipboard
        } else {
            clipboard = await attemptClipboard(png: encoded.png, tiff: encoded.tiff)
        }
        let clipboardCompletedAt = ContinuousClock().now
        let fileStartedAt = ContinuousClock().now
        let file = await attemptFile(
            encodedPNG: encoded.png,
            request: request,
            previous: previous?.file
        )
        let outcome = DeliveryOutcome.derive(
            policy: request.policy,
            file: file,
            clipboard: clipboard
        )
        logFinished(
            outcome,
            request: request,
            operationID: operationID,
            operation: operation,
            startedAt: startedAt,
            clipboardCompletedAt: clipboardCompletedAt,
            fileStartedAt: fileStartedAt
        )
        return outcome
    }

    private func attemptClipboard(png: Data?, tiff: Data?) async -> ClipboardDeliveryOutcome {
        guard !Task.isCancelled else { return .cancelledBeforeAttempt }
        return await clipboardOutput.copy(png: png, tiff: tiff)
    }

    private func attemptFile(
        encodedPNG: Data?,
        request: DeliveryRequest,
        previous: FileDeliveryOutcome?
    ) async -> FileDeliveryOutcome {
        guard let organization = request.policy.fileOrganization else { return .notRequested }
        if let previous, !previous.isPending { return previous }
        guard !Task.isCancelled else { return .cancelledBeforeAttempt }
        guard let encodedPNG else { return .failed(.pngEncodingFailed) }
        return await fileOutput.write(
            pngData: encodedPNG,
            capturedAt: request.capturedAt,
            organization: organization
        )
    }

    private func encodeRepresentations(
        for image: CaptureImage,
        needsClipboard: Bool
    ) -> (png: Data?, tiff: Data?) {
        guard !Task.isCancelled else {
            return (nil, nil)
        }
        let representation = NSBitmapImageRep(cgImage: image.cgImage)
        representation.size = image.size
        let png = representation.representation(using: .png, properties: [:])
        let tiff = needsClipboard && !Task.isCancelled
            ? representation.representation(using: .tiff, properties: [:])
            : nil
        return (png, tiff)
    }

    private func logFinished(
        _ outcome: DeliveryOutcome,
        request: DeliveryRequest,
        operationID: UUID,
        operation: StaticString,
        startedAt: ContinuousClock.Instant,
        clipboardCompletedAt: ContinuousClock.Instant,
        fileStartedAt: ContinuousClock.Instant
    ) {
        let finishedAt = ContinuousClock().now
        Self.logger.info(
            "event=delivery.finished correlation_id=\(request.correlationID.uuidString, privacy: .public) operation_id=\(operationID.uuidString, privacy: .public) operation=\(operation, privacy: .public) completion=\(outcome.completion.rawValue, privacy: .public) file=\(outcome.file.logCode, privacy: .public) clipboard=\(outcome.clipboard.logCode, privacy: .public) clipboard_available_ms=\(Self.durationMilliseconds(from: startedAt, to: clipboardCompletedAt), privacy: .public) file_duration_ms=\(Self.durationMilliseconds(from: fileStartedAt, to: finishedAt), privacy: .public) duration_ms=\(Self.durationMilliseconds(from: startedAt, to: finishedAt), privacy: .public)"
        )
    }

    nonisolated private static func durationMilliseconds(
        from start: ContinuousClock.Instant,
        to end: ContinuousClock.Instant
    ) -> Int64 {
        let components = start.duration(to: end).components
        return components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
    }
}
