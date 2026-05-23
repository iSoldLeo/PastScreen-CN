//
//  WindowHitTestResult.swift
//  Mio
//
//  Domain-layer DTO for Quartz window hit-test results.
//

import Foundation
import CoreGraphics

nonisolated public struct WindowHitTestResult: Sendable {
    public let windowID: CGWindowID
    /// Bounds in AppKit screen coordinates (bottom-left origin, points).
    public let bounds: CGRect
    public let ownerPID: pid_t
    public let ownerName: String?
    public let layer: Int

    public init(
        windowID: CGWindowID,
        bounds: CGRect,
        ownerPID: pid_t,
        ownerName: String?,
        layer: Int
    ) {
        self.windowID = windowID
        self.bounds = bounds
        self.ownerPID = ownerPID
        self.ownerName = ownerName
        self.layer = layer
    }
}
