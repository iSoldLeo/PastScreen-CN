//
//  CaptureOutputWriting.swift
//  Mio
//
//  Domain protocols for persisting captures (file + clipboard).
//

import Foundation

public protocol FileWriting: Sendable {
    /// Save a capture to disk and return the on-disk path. Sequence number
    /// management is internal to the implementation.
    func write(image: CaptureImage, config: CaptureConfiguration) async throws -> String?
}

public protocol ClipboardWriting: Sendable {
    func copy(image: CaptureImage) async throws
}
