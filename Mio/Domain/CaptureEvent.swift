//
//  CaptureEvent.swift
//  Mio
//
//  Type-safe events emitted during the capture pipeline.
//
//  Failures are NOT delivered through this stream. They surface as
//  thrown errors from `CapturePipeline.execute` and are presented by
//  `CaptureCoordinator` directly — keeping the success-path event bus
//  free of error-handling forks.
//

nonisolated public enum CaptureEvent: Sendable {
    case savedToFile(path: String)
    case copiedToClipboard
}
