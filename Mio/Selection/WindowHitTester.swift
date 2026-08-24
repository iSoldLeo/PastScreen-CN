//
//  WindowHitTester.swift
//  Mio
//
//  Live Quartz window hit-test, restored verbatim (in logic) from the v2.0.0
//  release. Window RECOGNITION is Quartz-only and live: each hover re-queries
//  CGWindowListCopyWindowInfo for the frontmost selectable window under the
//  cursor, skipping Mio's own overlay panels. This deliberately replaces the
//  module-04 frozen WindowSelectionCatalog for hover/selection (per user
//  decision: adopt the proven v2.0.0 window logic). Window OUTPUT still goes
//  through module 04's on-demand SCK capture.
//

import AppKit

/// Quartz window hit-test result. `bounds` is in AppKit screen coordinates
/// (bottom-left origin, points).
nonisolated struct WindowHitTestResult: Sendable, Equatable {
    let windowID: CGWindowID
    let bounds: CGRect
    let ownerPID: pid_t
    let ownerName: String?
    let layer: Int
}

@MainActor
enum WindowHitTester {
    private static let systemProcessBlacklist: Set<String> = [
        "Window Server",
        "Dock",
        "SystemUIServer"
    ]

    private struct Candidate {
        let windowID: CGWindowID
        let quartzBounds: CGRect
        let ownerPID: pid_t
        let ownerName: String?
        let layer: Int
        var area: CGFloat { quartzBounds.width * quartzBounds.height }
    }

    /// Height of the main display in Quartz coordinates (top-left origin).
    private static var mainHeight: CGFloat {
        let id = CGMainDisplayID()
        guard id != 0 else { return 0 }
        return CGDisplayBounds(id).height
    }

    /// Frontmost selectable window under the current mouse, or nil if none.
    /// `skipSelfWindows` skips Mio's own PID so the live overlay panels (which
    /// are frontmost while hovering) are ignored and the real window behind is
    /// found — this is what makes live hit-test work under the overlay.
    static func hitTestAtMouse(skipSelfWindows: Bool = true) -> WindowHitTestResult? {
        let appKit = NSEvent.mouseLocation
        let quartzPoint = CGPoint(x: appKit.x, y: mainHeight - appKit.y)
        return hitTest(quartzPoint: quartzPoint, skipSelfWindows: skipSelfWindows)
    }

    private static func hitTest(quartzPoint: CGPoint, skipSelfWindows: Bool) -> WindowHitTestResult? {
        let skipPIDs: Set<pid_t> = skipSelfWindows ? [getpid()] : []
        let mainBounds = CGDisplayBounds(CGMainDisplayID())
        let screenWidth = mainBounds.width
        let screenHeight = mainBounds.height
        guard screenWidth > 0, screenHeight > 0 else { return nil }

        // Quartz returns on-screen windows front → back.
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let normalLevel = Int(CGWindowLevelForKey(.normalWindow))
        let popupLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))

        var frontmost: Candidate?
        var best: Candidate?
        var frontmostContainment: CGRect?

        for info in list {
            guard
                let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                let quartzBounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            guard quartzBounds.contains(quartzPoint) else { continue }
            guard let windowID = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }

            let ownerPID: pid_t = (info[kCGWindowOwnerPID as String] as? NSNumber).map { pid_t($0.int32Value) } ?? 0
            if skipPIDs.contains(ownerPID) { continue }

            let ownerName = info[kCGWindowOwnerName as String] as? String
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0

            // Allow standard + floating/modal/popup layers; drop higher system overlays.
            guard layer >= normalLevel, layer <= popupLevel else { continue }
            if let alpha = info[kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue <= 0 { continue }
            if let onscreen = info[kCGWindowIsOnscreen as String] as? NSNumber, onscreen.boolValue == false { continue }
            if let ownerName, systemProcessBlacklist.contains(ownerName) { continue }
            // Skip full-screen overlays (Mission Control, spaces, etc.).
            if quartzBounds.width >= screenWidth - 1, quartzBounds.height >= screenHeight - 1 { continue }

            let candidate = Candidate(
                windowID: windowID,
                quartzBounds: quartzBounds,
                ownerPID: ownerPID,
                ownerName: ownerName,
                layer: layer
            )

            if frontmost == nil {
                frontmost = candidate
                best = candidate
                frontmostContainment = quartzBounds.insetBy(dx: -1, dy: -1)
                continue
            }

            // Promote a same-PID parent window that fully contains the frontmost
            // window (Chromium/Electron child → parent) for consistent selection.
            guard
                let frontmost,
                candidate.ownerPID == frontmost.ownerPID,
                let containment = frontmostContainment,
                candidate.quartzBounds.contains(containment)
            else { continue }

            if let currentBest = best, candidate.area > currentBest.area { best = candidate }
        }

        guard let best else { return nil }
        let appKitBounds = CGRect(
            x: best.quartzBounds.origin.x,
            y: mainHeight - best.quartzBounds.origin.y - best.quartzBounds.height,
            width: best.quartzBounds.width,
            height: best.quartzBounds.height
        )
        return WindowHitTestResult(
            windowID: best.windowID,
            bounds: appKitBounds,
            ownerPID: best.ownerPID,
            ownerName: best.ownerName,
            layer: best.layer
        )
    }
}
