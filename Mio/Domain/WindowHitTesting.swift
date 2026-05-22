//
//  WindowHitTesting.swift
//  Mio
//
//  Protocol for Quartz window hit-testing.
//

import CoreGraphics

public protocol WindowHitTesting: Sendable {
    @MainActor
    func hitTestFrontmostWindowAtMouse(
        excludingWindowIDs: Set<CGWindowID>,
        skipSelfWindows: Bool
    ) throws -> WindowHitTestResult
}
