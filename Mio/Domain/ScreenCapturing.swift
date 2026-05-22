//
//  ScreenCapturing.swift
//  Mio
//
//  Domain protocol for display and window capture.
//

import Foundation
import CoreGraphics

public protocol ScreenCapturing: Sendable {
    func captureDisplay(rect: CGRect, excludingWindowIDs: [CGWindowID]) async throws -> CaptureImage
    func captureWindow(windowID: CGWindowID) async throws -> CaptureImage
    func captureFrozenDisplaySnapshots() async -> [CGDirectDisplayID: CaptureImage]
    func cropFrozenSnapshot(frozenSnapshots: [CGDirectDisplayID: CaptureImage], rect: CGRect) async -> CaptureImage?
}
