//
//  WindowCaptureCoordinator.swift
//  PastScreen
//
//  Hybrid Quartz hit-testing + ScreenCaptureKit metadata/screenshot for windows.
//

import Foundation
import AppKit
import CoreGraphics
import ScreenCaptureKit

struct WindowHitTestResult {
    let windowID: CGWindowID
    let bounds: CGRect
    let ownerPID: pid_t
    let ownerName: String?
    let layer: Int
}

struct WindowCaptureResult {
    let image: CGImage
    let window: SCWindow
    let application: SCRunningApplication?
}

enum WindowCaptureError: LocalizedError {
    case mouseLocationUnavailable
    case noWindowAtPoint
    case shareableWindowNotFound(CGWindowID)
    case invalidWindowSize
    case streamError(SCStreamError)
    case generic(String)

    var errorDescription: String? {
        switch self {
        case .mouseLocationUnavailable:
            return NSLocalizedString("无法获取鼠标位置", comment: "")
        case .noWindowAtPoint:
            return NSLocalizedString("找不到命中的窗口", comment: "")
        case .shareableWindowNotFound(let id):
            return String(format: NSLocalizedString("未在 ScreenCaptureKit 集合中找到窗口（ID: %u）", comment: ""), id)
        case .invalidWindowSize:
            return NSLocalizedString("窗口尺寸无效，无法截图", comment: "")
        case .streamError(let error):
            switch error.code {
            case .userDeclined:
                return NSLocalizedString("屏幕录制权限被拒绝。请前往“隐私与安全性 → 屏幕录制”开启。", comment: "")
            case .systemStoppedStream:
                return NSLocalizedString("截图被系统中断", comment: "")
            default:
                return error.localizedDescription
            }
        case .generic(let message):
            return message
        }
    }
}

final class WindowCaptureCoordinator {
    static let shared = WindowCaptureCoordinator()
    private let selfPID: pid_t = getpid()

    private struct QuartzSpace {
        static var mainHeight: CGFloat { CGDisplayBounds(CGMainDisplayID()).height }

        static func quartzPoint(fromAppKitGlobal point: CGPoint) -> CGPoint {
            CGPoint(x: point.x, y: mainHeight - point.y)
        }

        static func appKitRect(fromQuartz rect: CGRect) -> CGRect {
            let ay = mainHeight - rect.origin.y - rect.height
            return CGRect(x: rect.origin.x, y: ay, width: rect.width, height: rect.height)
        }
    }

    /// Use Quartz (CGWindowListCopyWindowInfo) to find the frontmost on-screen window under a point.
    /// By default, windows owned by this process are skipped so overlay UIs don't get picked.
    func hitTestFrontmostWindow(
        quartzPoint: CGPoint,
        excludingPIDs: Set<pid_t> = [],
        excludingWindowIDs: Set<CGWindowID> = []
    ) throws -> WindowHitTestResult {
        let skipPIDs = excludingPIDs.union([selfPID])
        let skipWindowIDs = excludingWindowIDs

        // Quartz returns on-screen windows ordered front → back.
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowInfoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            throw WindowCaptureError.noWindowAtPoint
        }

        for info in windowInfoList {
            guard
                let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                let quartzBounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
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

            // Filter out non-standard layers (Dock, menu bar, system overlays)
            guard layer == 0 else { continue }

            if let alphaNum = info[kCGWindowAlpha as String] as? NSNumber, alphaNum.doubleValue <= 0 {
                continue
            }
            if let onscreen = info[kCGWindowIsOnscreen as String] as? NSNumber, onscreen.boolValue == false {
                continue
            }

            // Exclude Dock explicitly
            if ownerName == "Dock" { continue }

            let appKitBounds = QuartzSpace.appKitRect(fromQuartz: quartzBounds)

            return WindowHitTestResult(
                windowID: windowID,
                bounds: appKitBounds,
                ownerPID: ownerPID,
                ownerName: ownerName,
                layer: layer
            )
        }

        throw WindowCaptureError.noWindowAtPoint
    }

    /// Convenience: hit-test at current mouse location (Quartz coordinates).
    func hitTestFrontmostWindowAtMouse(
        excludingPIDs: Set<pid_t> = [],
        excludingWindowIDs: Set<CGWindowID> = []
    ) throws -> WindowHitTestResult {
        // Use AppKit mouse location (bottom-left origin) then convert to Quartz (top-left origin)
        let appKitPoint = NSEvent.mouseLocation
        let cgPoint = QuartzSpace.quartzPoint(fromAppKitGlobal: appKitPoint)
        return try hitTestFrontmostWindow(
            quartzPoint: cgPoint,
            excludingPIDs: excludingPIDs,
            excludingWindowIDs: excludingWindowIDs
        )
    }

    /// Resolve ScreenCaptureKit metadata and screenshot for a CGWindowID.
    /// Uses SCShareableContent.excludingDesktopWindows(_, onScreenWindowsOnly: true) for a visible-only set.
    func captureWindow(with windowID: CGWindowID) async throws -> WindowCaptureResult {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else {
            throw WindowCaptureError.shareableWindowNotFound(windowID)
        }

        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let rect = filter.contentRect
        let scale = filter.pointPixelScale

        guard rect.width > 0, rect.height > 0 else {
            throw WindowCaptureError.invalidWindowSize
        }

        let config = SCStreamConfiguration()
        let scaleCGFloat = CGFloat(scale)
        config.width = max(1, Int(rect.width * scaleCGFloat))
        config.height = max(1, Int(rect.height * scaleCGFloat))
        config.captureResolution = .best
        config.showsCursor = false
        config.scalesToFit = false

        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )

            return WindowCaptureResult(
                image: image,
                window: scWindow,
                application: scWindow.owningApplication
            )
        } catch let streamError as SCStreamError {
            throw WindowCaptureError.streamError(streamError)
        } catch {
            throw WindowCaptureError.generic(error.localizedDescription)
        }
    }

    func captureWindow(using hitResult: WindowHitTestResult) async throws -> WindowCaptureResult {
        try await captureWindow(with: hitResult.windowID)
    }

    // MARK: - Coordinate helpers

    private func convertQuartzRectToAppKit(_ rect: CGRect) -> CGRect {
        QuartzSpace.appKitRect(fromQuartz: rect)
    }
}
