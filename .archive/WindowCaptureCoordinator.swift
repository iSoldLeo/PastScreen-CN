//
//  WindowCaptureCoordinator.swift
//  PastScreen
//
//  Hybrid Quartz hit-testing + ScreenCaptureKit metadata/screenshot for windows.
//

import Foundation
import AppKit
import CoreGraphics
import QuartzCore
// TODO: Remove @preconcurrency once Apple marks ScreenCaptureKit types as Sendable.
// SCWindow, SCContentFilter, SCStreamConfiguration, SCShareableContent, etc. are not marked Sendable by Apple.
@preconcurrency import ScreenCaptureKit

@MainActor
final class WindowCaptureCoordinator {
    static let shared = WindowCaptureCoordinator()

    /// Resolve ScreenCaptureKit metadata and screenshot for a CGWindowID.
    /// Uses SCShareableContent.excludingDesktopWindows(_, onScreenWindowsOnly: true) for a visible-only set.
    func captureWindow(with windowID: CGWindowID, applyBorder: Bool = true) async throws -> WindowCaptureInfo {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
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
            let settings = AppSettings.shared
            let borderEnabled = applyBorder && settings.windowBorderEnabled
            let borderPoints = CGFloat(settings.windowBorderWidth)
            let borderCornerRadius = CGFloat(settings.windowBorderCornerRadius)
            let borderColor = settings.windowBorderColor.cgColor ?? CGColor(gray: 1, alpha: 1)

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            var paddingPoints = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            let finalImage: CGImage
            if borderEnabled, borderPoints > 0 {
                if let bordered = addBorderIfNeeded(
                    to: image,
                    borderPoints: borderPoints,
                    cornerRadiusPoints: borderCornerRadius,
                    scale: scaleCGFloat,
                    color: borderColor
                ) {
                    finalImage = bordered.image
                    paddingPoints = bordered.paddingPoints
                } else {
                    finalImage = image
                }
            } else {
                finalImage = image
            }

            return WindowCaptureInfo(
                image: SendableCGImage(finalImage),
                windowFrame: scWindow.frame,
                appBundleID: scWindow.owningApplication?.bundleIdentifier,
                appName: scWindow.owningApplication?.applicationName,
                paddingPoints: EdgeInsetValues(paddingPoints)
            )
        } catch let streamError as SCStreamError {
            let description: String = switch streamError.code {
            case .userDeclined:
                NSLocalizedString("屏幕录制权限被拒绝。请前往\"隐私与安全性 → 屏幕录制\"开启。", comment: "")
            case .systemStoppedStream:
                NSLocalizedString("截图被系统中断", comment: "")
            default:
                streamError.localizedDescription
            }
            throw WindowCaptureError.streamError(description: description)
        } catch {
            throw WindowCaptureError.generic(error.localizedDescription)
        }
    }

    func captureWindow(using hitResult: WindowHitTestResult, applyBorder: Bool = true) async throws -> WindowCaptureInfo {
        try await captureWindow(with: hitResult.windowID, applyBorder: applyBorder)
    }

    /// Add an outer border around the captured window image.
    private struct BorderRenderResult {
        let image: CGImage
        let paddingPoints: NSEdgeInsets
    }

    private func addBorderIfNeeded(
        to image: CGImage,
        borderPoints: CGFloat,
        cornerRadiusPoints: CGFloat,
        scale: CGFloat,
        color: CGColor = CGColor(gray: 0, alpha: 0.18)
    ) -> BorderRenderResult? {
        let borderPixels = max(1, Int(ceil(borderPoints * scale)))
        let newWidth = image.width + borderPixels * 2
        let newHeight = image.height + borderPixels * 2
        let cornerRadiusPixels = max(0, cornerRadiusPoints * scale)

        guard let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        guard let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: image.bitsPerComponent,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        // Fill border area with rounded corners using continuous curve
        let shapeLayer = CALayer()
        shapeLayer.frame = CGRect(x: 0, y: 0, width: newWidth, height: newHeight)
        shapeLayer.backgroundColor = color
        shapeLayer.cornerRadius = cornerRadiusPixels
        shapeLayer.cornerCurve = .continuous
        shapeLayer.masksToBounds = true
        shapeLayer.contentsScale = scale
        shapeLayer.render(in: context)

        // Draw original image inside the border
        context.draw(
            image,
            in: CGRect(
                x: borderPixels,
                y: borderPixels,
                width: image.width,
                height: image.height
            )
        )

        guard let bordered = context.makeImage() else { return nil }

        let paddingPoints = NSEdgeInsets(
            top: CGFloat(borderPixels) / scale,
            left: CGFloat(borderPixels) / scale,
            bottom: CGFloat(borderPixels) / scale,
            right: CGFloat(borderPixels) / scale
        )

        return BorderRenderResult(image: bordered, paddingPoints: paddingPoints)
    }
}
