//
//  WindowCaptureService.swift
//  Mio
//
//  Quartz window hit-test service.
//  hitTestFrontmostWindowAtMouse is @MainActor (NSEvent.mouseLocation requires main thread).
//  Internal hit-test work is delegated to the non-isolated hitTestFrontmostWindow,
//  which is safe to call synchronously from SelectionOverlayView.mouseMoved.
//

import Foundation
import AppKit
import CoreGraphics

public final class WindowCaptureService: WindowHitTesting, Sendable {
    public static let shared = WindowCaptureService()
    private let selfPID: pid_t = getpid()

    private static let systemProcessBlacklist: Set<String> = [
        "Window Server",
        "Dock",
        "SystemUIServer"
    ]

    private struct WindowCandidate {
        let windowID: CGWindowID
        let quartzBounds: CGRect
        let ownerPID: pid_t
        let ownerName: String?
        let layer: Int

        var area: CGFloat { quartzBounds.width * quartzBounds.height }
    }

    public init() {}

    /// Use Quartz (CGWindowListCopyWindowInfo) to find the frontmost on-screen window under a point.
    /// By default, windows owned by this process are skipped so overlay UIs don't get picked.
    private func hitTestFrontmostWindow(
        quartzPoint: CGPoint,
        excludingWindowIDs: Set<CGWindowID>,
        skipSelfWindows: Bool
    ) throws -> WindowHitTestResult {
        let skipPIDs: Set<pid_t> = skipSelfWindows ? [selfPID] : []
        let skipWindowIDs = excludingWindowIDs
        let mainDisplayBounds = CGDisplayBounds(CGMainDisplayID())
        let screenWidth = mainDisplayBounds.width
        let screenHeight = mainDisplayBounds.height

        // Guard against headless or zero-size display configurations
        guard screenWidth > 0, screenHeight > 0 else {
            throw WindowCaptureError.noWindowAtPoint
        }

        // Quartz returns on-screen windows ordered front → back.
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowInfoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            throw WindowCaptureError.noWindowAtPoint
        }

        var frontmostCandidate: WindowCandidate?
        var bestCandidate: WindowCandidate?
        var frontmostBoundsForContainment: CGRect?

        for info in windowInfoList {
            guard
                let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                let cfDict = boundsDict as CFDictionary?,
                let quartzBounds = CGRect(dictionaryRepresentation: cfDict)
            else {
                continue
            }

            guard quartzBounds.contains(quartzPoint) else { continue }

            guard let windowID = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
            if skipWindowIDs.contains(windowID) { continue }

            let ownerPID: pid_t = {
                if let n = info[kCGWindowOwnerPID as String] as? NSNumber { return pid_t(n.int32Value) }
                if let n = info[kCGWindowOwnerPID as String] as? Int { return pid_t(n) }
                return 0
            }()
            if skipPIDs.contains(ownerPID) { continue }

            let ownerName = info[kCGWindowOwnerName as String] as? String
            let layer: Int = {
                if let n = info[kCGWindowLayer as String] as? NSNumber { return n.intValue }
                if let n = info[kCGWindowLayer as String] as? Int { return n }
                return 0
            }()

            // Allow standard + floating/modal/popup layers; filter out higher system overlays.
            let normalLevel = Int(CGWindowLevelForKey(.normalWindow))
            let popupLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
            guard layer >= normalLevel && layer <= popupLevel else { continue }

            if let alphaNum = info[kCGWindowAlpha as String] as? NSNumber, alphaNum.doubleValue <= 0 {
                continue
            }
            if let onscreen = info[kCGWindowIsOnscreen as String] as? NSNumber, onscreen.boolValue == false {
                continue
            }

            if let ownerName, Self.systemProcessBlacklist.contains(ownerName) {
                continue
            }

            // Skip full-screen overlays (e.g., Mission Control, spaces) that cover the whole display.
            if quartzBounds.width >= screenWidth - 1 && quartzBounds.height >= screenHeight - 1 {
                continue
            }

            let candidate = WindowCandidate(
                windowID: windowID,
                quartzBounds: quartzBounds,
                ownerPID: ownerPID,
                ownerName: ownerName,
                layer: layer
            )

            // First match is the frontmost window under the point.
            if frontmostCandidate == nil {
                frontmostCandidate = candidate
                bestCandidate = candidate
                // Tolerate tiny rounding/shadow differences for containment checks.
                frontmostBoundsForContainment = quartzBounds.insetBy(dx: -1, dy: -1)
                continue
            }

            // Promote Chromium/Electron child windows to a larger same-PID parent that fully contains the frontmost window for consistent selection/preview.
            guard
                let frontmostCandidate,
                candidate.ownerPID == frontmostCandidate.ownerPID,
                let containmentBounds = frontmostBoundsForContainment,
                candidate.quartzBounds.contains(containmentBounds)
            else {
                continue
            }

            if let currentBest = bestCandidate, candidate.area > currentBest.area {
                bestCandidate = candidate
            }
        }

        if let bestCandidate {
            let appKitBounds = QuartzSpace.appKitRect(fromQuartz: bestCandidate.quartzBounds)
            return WindowHitTestResult(
                windowID: bestCandidate.windowID,
                bounds: appKitBounds,
                ownerPID: bestCandidate.ownerPID,
                ownerName: bestCandidate.ownerName,
                layer: bestCandidate.layer
            )
        }

        throw WindowCaptureError.noWindowAtPoint
    }

    /// Convenience: hit-test at current mouse location (Quartz coordinates).
    /// @MainActor because NSEvent.mouseLocation must be accessed on the main thread.
    @MainActor
    public func hitTestFrontmostWindowAtMouse(
        excludingWindowIDs: Set<CGWindowID> = [],
        skipSelfWindows: Bool = true
    ) throws -> WindowHitTestResult {
        // Use AppKit mouse location (bottom-left origin) then convert to Quartz (top-left origin)
        let appKitPoint = NSEvent.mouseLocation
        let cgPoint = QuartzSpace.quartzPoint(fromAppKitGlobal: appKitPoint)
        return try hitTestFrontmostWindow(
            quartzPoint: cgPoint,
            excludingWindowIDs: excludingWindowIDs,
            skipSelfWindows: skipSelfWindows
        )
    }
}
