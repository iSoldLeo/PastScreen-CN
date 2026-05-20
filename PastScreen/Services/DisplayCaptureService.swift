//
//  DisplayCaptureService.swift
//  PastScreen
//
//  Actor for ScreenCaptureKit display/region/window capture.
//

import Foundation
import CoreGraphics
// TODO: Remove @preconcurrency once Apple marks AppKit types as Sendable.
@preconcurrency import AppKit
// TODO: Remove @preconcurrency once Apple marks ScreenCaptureKit types as Sendable.
@preconcurrency import ScreenCaptureKit

public actor DisplayCaptureService: ScreenCapturing {
    public init() {}

    // MARK: - Display / Region capture

    public func captureDisplay(rect: CGRect, excludingWindowIDs: [CGWindowID]) async throws -> CaptureImage {
        guard rect.width > 0, rect.height > 0 else {
            throw CaptureError("Invalid capture rect: \(rect)")
        }

        let content = try await SCShareableContent.current

        // NSScreen is not Sendable; extract Sendable primitives on MainActor.
        let screenInfo: (displayID: CGDirectDisplayID, frame: CGRect, scaleFactor: CGFloat)? = await MainActor.run {
            guard let nsScreen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) else {
                return nil
            }
            let displayID = nsScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            return (displayID: displayID, frame: nsScreen.frame, scaleFactor: nsScreen.backingScaleFactor)
        }
        guard let screenInfo else {
            throw CaptureError("No screen contains the selected region")
        }

        let targetDisplay: SCDisplay
        if let matchedDisplay = content.displays.first(where: { $0.displayID == screenInfo.displayID }) {
            targetDisplay = matchedDisplay
        } else {
            guard let fallbackDisplay = content.displays.first else {
                throw CaptureError("No available display found")
            }
            targetDisplay = fallbackDisplay
        }

        let screenFrame = screenInfo.frame
        let offsetX = rect.origin.x - screenFrame.origin.x
        let offsetY = rect.origin.y - screenFrame.origin.y
        let flippedY = screenFrame.size.height - offsetY - rect.size.height

        let rectInScreenPoints = CGRect(
            x: offsetX,
            y: flippedY,
            width: rect.width,
            height: rect.height
        )

        let screenBounds = CGRect(origin: .zero, size: screenFrame.size)
        var relativeRect = rectInScreenPoints
        if !screenBounds.contains(rectInScreenPoints) {
            relativeRect = rectInScreenPoints.intersection(screenBounds)
            guard !relativeRect.isNull else {
                throw CaptureError("Selection is completely outside screen bounds")
            }
        }

        let excludeWindows = content.windows.filter {
            excludingWindowIDs.contains(CGWindowID($0.windowID))
        }

        let filter = SCContentFilter(display: targetDisplay, excludingWindows: excludeWindows)
        let scaleFactor = screenInfo.scaleFactor

        let config = SCStreamConfiguration()
        config.width = Int(relativeRect.width * scaleFactor)
        config.height = Int(relativeRect.height * scaleFactor)
        config.sourceRect = relativeRect
        config.scalesToFit = false
        config.showsCursor = false
        config.captureResolution = .best

        do {
            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            return CaptureImage(cgImage: cgImage, scale: scaleFactor, size: relativeRect.size)
        } catch let streamError as SCStreamError {
            let description: String = switch streamError.code {
            case .userDeclined:
                NSLocalizedString("屏幕录制权限被拒绝。请前往\"系统设置 → 隐私与安全性 → 屏幕录制\"开启。", comment: "")
            case .systemStoppedStream:
                NSLocalizedString("截图被系统中断", comment: "")
            default:
                streamError.localizedDescription
            }
            throw CaptureError(description)
        } catch {
            throw CaptureError("截图失败：\(error.localizedDescription)")
        }
    }

    // MARK: - Window capture

    public func captureWindow(windowID: CGWindowID) async throws -> CaptureImage {
        let scContent = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let scWindow = scContent.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError("窗口 \(windowID) 未在可共享内容中找到")
        }

        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let rect = filter.contentRect
        let scale = CGFloat(filter.pointPixelScale)

        guard rect.width > 0, rect.height > 0 else {
            throw CaptureError("Invalid window size: \(rect)")
        }

        let config = SCStreamConfiguration()
        config.width = max(1, Int(rect.width * scale))
        config.height = max(1, Int(rect.height * scale))
        config.captureResolution = .best
        config.showsCursor = false
        config.scalesToFit = false

        do {
            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            return CaptureImage(cgImage: cgImage, scale: scale, size: CGSize(width: rect.width, height: rect.height))
        } catch let streamError as SCStreamError {
            let description: String = switch streamError.code {
            case .userDeclined:
                NSLocalizedString("屏幕录制权限被拒绝。请前往\"系统设置 → 隐私与安全性 → 屏幕录制\"开启。", comment: "")
            case .systemStoppedStream:
                NSLocalizedString("截图被系统中断", comment: "")
            default:
                streamError.localizedDescription
            }
            throw CaptureError(description)
        } catch {
            throw CaptureError("窗口截图失败：\(error.localizedDescription)")
        }
    }
}
