//
//  CaptureError.swift
//  Mio
//
//  Sendable error type for capture failures.
//  Separated from CaptureEvent to keep file single-responsibility.
//
//  Note: underlying is String? (not Error?) because Error is not Sendable.
//  SCStreamError and other non-Sendable errors must be converted to
//  descriptions inside their respective actors before crossing boundaries.
//

import Foundation

nonisolated public struct CaptureError: Error, LocalizedError, Sendable {
    public let message: String
    public let underlyingDescription: String?

    public init(_ message: String, underlyingDescription: String? = nil) {
        self.message = message
        self.underlyingDescription = underlyingDescription
    }

    public var errorDescription: String? { message }
}
