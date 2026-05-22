//
//  CaptureEventBus.swift
//  Mio
//
//  Production implementation of `EventBusing`. Thread-safe by virtue of
//  `AsyncStream.Continuation`, whose `yield` and `finish` methods are
//  documented thread-safe by Apple.
//
//  @unchecked Sendable: the stored properties are an immutable
//  AsyncStream and its Continuation. The Continuation is the only
//  mutable conduit; all callers funnel through `yield`/`finish` which
//  the standard library guarantees safe across actors.
//

import Foundation

nonisolated public final class CaptureEventBus: EventBusing, @unchecked Sendable {
    private let stream: AsyncStream<CaptureEvent>
    private let continuation: AsyncStream<CaptureEvent>.Continuation

    public var events: AsyncStream<CaptureEvent> { stream }

    public init() {
        let (s, c) = AsyncStream<CaptureEvent>.makeStream()
        self.stream = s
        self.continuation = c
    }

    /// Thread-safe by contract: AsyncStream.Continuation.yield() is safe across actors.
    nonisolated public func emit(_ event: CaptureEvent) {
        continuation.yield(event)
    }

    /// Thread-safe by contract: AsyncStream.Continuation.finish() is safe across actors.
    nonisolated public func finish() {
        continuation.finish()
    }

    deinit {
        continuation.finish()
    }
}
