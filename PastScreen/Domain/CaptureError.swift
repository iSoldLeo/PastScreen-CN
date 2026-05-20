//
//  CaptureError.swift
//  PastScreen
//
//  Sendable error type for capture failures.
//  Separated from CaptureEvent to keep file single-responsibility.
//
//  Note: underlying is String? (not Error?) because Error is not Sendable.
//  SCStreamError and other non-Sendable errors must be converted to
//  descriptions inside their respective actors before crossing boundaries.
//

public struct CaptureError: Error, Sendable {
    public let message: String
    public let underlyingDescription: String?

    public init(_ message: String, underlyingDescription: String? = nil) {
        self.message = message
        self.underlyingDescription = underlyingDescription
    }
}
