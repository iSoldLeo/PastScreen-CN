//
//  CaptureOutputWriting.swift
//  Mio
//
//  Domain protocols for persisting captures (file + clipboard).
//

import Foundation

public protocol FileWriting: Sendable {
    /// Save a capture to disk and return the on-disk path. Sequence number
    /// management is internal to the implementation — Phase 5 moved that
    /// state out of AppSettings into the file output service.
    func write(image: CaptureImage, config: CaptureConfiguration) async throws -> String?

    /// Reset the internal filename sequence counter. Invoked after the user
    /// clears the save folder.
    func resetSequence() async
}

public protocol ClipboardWriting: Sendable {
    func copy(image: CaptureImage, config: CaptureConfiguration, filePath: String?) async throws
}
