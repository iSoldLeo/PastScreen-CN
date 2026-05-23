//
//  EventBusing.swift
//  Mio
//
//  Domain protocol for the capture-pipeline event bus. Producers
//  (CapturePipeline) call `emit(_:)` to broadcast progress; consumers
//  (CaptureCoordinator) iterate `events` to react.
//
//  Aligns with the other service protocols (`FileWriting`,
//  `ClipboardWriting`, `ScreenCapturing`) so all pipeline dependencies
//  cross actor boundaries through a `Sendable` abstraction rather than
//  concrete types.
//

import Foundation

public protocol EventBusing: Sendable {
    /// Asynchronous stream of pipeline events. Each subscriber should
    /// iterate this once via `for await`.
    nonisolated var events: AsyncStream<CaptureEvent> { get }

    /// Emit a single event. Safe to call from any actor.
    nonisolated func emit(_ event: CaptureEvent)

    /// Close the stream. Subsequent `events` iterations terminate.
    nonisolated func finish()
}
