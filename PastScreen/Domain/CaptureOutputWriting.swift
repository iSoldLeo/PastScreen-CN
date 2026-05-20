//
//  CaptureOutputWriting.swift
//  PastScreen
//
//  Domain protocol for persisting captures (file + clipboard).
//

import Foundation

public protocol FileWriting: Sendable {
    func write(image: CaptureImage, config: CaptureConfiguration, sequence: Int) async throws -> (path: String?, nextSequence: Int)
}

public protocol ClipboardWriting: Sendable {
    func copy(image: CaptureImage, config: CaptureConfiguration, filePath: String?) async throws
}
