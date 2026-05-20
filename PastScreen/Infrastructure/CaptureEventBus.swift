//
//  CaptureEventBus.swift
//  PastScreen
//
//  Thread-safe event bus using AsyncStream.
//  @unchecked Sendable: AsyncStream.Continuation.yield() is thread-safe by contract.
//

import Foundation

nonisolated public final class CaptureEventBus: @unchecked Sendable {
    private let stream: AsyncStream<CaptureEvent>
    private let continuation: AsyncStream<CaptureEvent>.Continuation

    public var events: AsyncStream<CaptureEvent> { stream }

    public init() {
        let (s, c) = AsyncStream<CaptureEvent>.makeStream()
        self.stream = s
        self.continuation = c
    }

    public func emit(_ event: CaptureEvent) {
        continuation.yield(event)
    }

    public func finish() {
        continuation.finish()
    }
}
