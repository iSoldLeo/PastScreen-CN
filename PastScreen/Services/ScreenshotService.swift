//
//  ScreenshotService.swift
//  PastScreen
//
//  Screenshot capture service with Liquid Glass selection UI
//

import Foundation
import AppKit
import CoreGraphics
import SwiftUI
import UserNotifications
import ScreenCaptureKit
import Vision
import QuartzCore

// MARK: - App Category Detection

enum AppCategory {
    case codeEditor
    case webBrowser
    case designTool
    case unknown
}

class ScreenshotService: NSObject, SelectionWindowDelegate {
    private var previousApp: NSRunningApplication? // Store app that was active before capture
    private var selectionWindow: SelectionWindow? // Custom selection window
    private var frozenDisplaySnapshots: [CGDirectDisplayID: CGImage] = [:] // Per-display snapshots captured via ScreenCaptureKit
    private var frozenWindowSnapshots: [CGWindowID: FrozenWindowSnapshot] = [:] // Per-window snapshots captured via ScreenCaptureKit
    private struct FrozenWindowSnapshot {
        let image: CGImage
        let padding: NSEdgeInsets
        let pointSize: CGSize
        let borderApplied: Bool
        let scale: CGFloat
    }

    private enum CaptureMode {
        case quick
        case advanced
        case ocr
    }

    private var captureMode: CaptureMode = .quick

    // Bundle IDs of known applications
    private let appCategoryMap: [String: AppCategory] = [
        // Code Editors
        "com.microsoft.VSCode": .codeEditor,
        "com.microsoft.VSCodeInsiders": .codeEditor,
        "dev.zed.Zed": .codeEditor,
        "com.todesktop.230313mzl4w4u92": .codeEditor, // Cursor
        "com.cursor.Cursor": .codeEditor,
        "com.sublimetext.4": .codeEditor,
        "com.apple.dt.Xcode": .codeEditor,
        "com.jetbrains.intellij": .codeEditor,
        "com.jetbrains.pycharm": .codeEditor,
        "com.github.atom": .codeEditor,
        "com.uranusjr.macdown": .codeEditor,
        "abnerworks.Typora": .codeEditor,
        "md.obsidian": .codeEditor,

        // Terminals
        "com.apple.Terminal": .codeEditor,
        "com.googlecode.iterm2": .codeEditor,
        "co.zeit.hyper": .codeEditor,
        "net.kovidgoyal.kitty": .codeEditor,
        "org.alacritty": .codeEditor,

        // Web Browsers
        "com.apple.Safari": .webBrowser,
        "com.apple.SafariTechnologyPreview": .webBrowser,
        "com.google.Chrome": .webBrowser,
        "com.google.Chrome.canary": .webBrowser,
        "org.mozilla.firefox": .webBrowser,
        "org.mozilla.firefoxdeveloperedition": .webBrowser,
        "com.microsoft.edgemac": .webBrowser,
        "com.microsoft.edgemac.Dev": .webBrowser,
        "com.brave.Browser": .webBrowser,
        "com.brave.Browser.dev": .webBrowser,
        "com.operasoftware.Opera": .webBrowser,
        "com.operasoftware.OperaGX": .webBrowser,
        "company.thebrowser.Browser": .webBrowser, // Arc
        "company.thebrowser.dia": .webBrowser, // DIA
        "com.vivaldi.Vivaldi": .webBrowser,
        "org.chromium.Chromium": .webBrowser,
        "com.kagi.kagimacOS": .webBrowser, // Orion
        "com.pushplaylabs.Sidekick": .webBrowser,
        "com.maxthon.mac.Maxthon": .webBrowser,
        "com.microsoft.Outlook": .webBrowser,

        // Design & Communication Tools
        "com.figma.Desktop": .designTool,
        "com.tinyspeck.slackmacgap": .designTool,
        "com.hnc.Discord": .designTool,
        "com.linear": .designTool,
        "notion.id": .designTool,
        "com.sketch.app": .designTool,
        "com.bohemiancoding.sketch3": .designTool,
        "com.adobe.PhotoshopCC": .designTool,
        "com.framerx.Framer": .designTool
    ]

    func captureScreenshot() {
        // CRITICAL: Force cleanup of any existing selection window before creating new one
        // (prevents overlay windows from persisting if user takes multiple screenshots rapidly)
        if let existingWindow = selectionWindow {
            existingWindow.hide()
            selectionWindow = nil
        }

        captureMode = .quick
        startSelectionFlow(overlayConfiguration: .screenshot)
    }
    
    func captureAdvancedScreenshot() {
        // CRITICAL: Force cleanup of any existing selection window before creating new one
        if let existingWindow = selectionWindow {
            existingWindow.hide()
            selectionWindow = nil
        }

        captureMode = .advanced
        startSelectionFlow(overlayConfiguration: .screenshot)
    }

    func captureOCRScreenshot() {
        if let existingWindow = selectionWindow {
            existingWindow.hide()
            selectionWindow = nil
        }

        captureMode = .ocr
        startSelectionFlow(overlayConfiguration: .ocr)
    }

    // NEW: Full screen capture using ScreenCaptureKit
    func captureFullScreen() {
        // Calculate combined frame covering all screens
        let screenFrame = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
        performCapture(rect: screenFrame)
    }

    // MARK: - SelectionWindowDelegate

    func selectionWindow(_ window: SelectionWindow, didSelectRect rect: CGRect) {
        // Get overlay window IDs BEFORE hiding (for ScreenCaptureKit exclusion)
        let overlayWindowIDs = window.getOverlayWindowIDs()

        // Hide all selection windows
        window.hide()

        // CRITICAL: Wait for windows to be visually hidden before capturing
        // ScreenCaptureKit captures everything on screen, including overlays
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self else { return }

            if let frozen = self.frozenCapture(for: rect) {
                switch self.captureMode {
                case .advanced:
                    self.handleAdvancedCapture(cgImage: frozen, selectionRect: rect)
                case .ocr:
                    self.performOCRFrozenCapture(cgImage: frozen, selectionRect: rect)
                case .quick:
                    self.handleSuccessfulCapture(cgImage: frozen, selectionRect: rect)
                }
                self.frozenDisplaySnapshots.removeAll()
                self.frozenWindowSnapshots.removeAll()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.selectionWindow = nil
                }
                return
            }

            // Now perform capture with overlay windows excluded
            switch self.captureMode {
            case .advanced:
                self.performAdvancedCapture(rect: rect, excludeWindowIDs: overlayWindowIDs)
            case .ocr:
                self.performOCRCapture(rect: rect, excludeWindowIDs: overlayWindowIDs)
            case .quick:
                self.performCapture(rect: rect, excludeWindowIDs: overlayWindowIDs)
            }

            self.frozenDisplaySnapshots.removeAll()
            self.frozenWindowSnapshots.removeAll()
            // Cleanup window reference
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.selectionWindow = nil
            }
        }
    }

    func selectionWindow(_ window: SelectionWindow, didSelectWindow windowResult: WindowHitTestResult) {
        let overlayWindowIDs = window.getOverlayWindowIDs()

        window.hide()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self else { return }

            if var frozenWindow = self.frozenWindowSnapshots[windowResult.windowID] {
                if !frozenWindow.borderApplied {
                    let (bordered, padding) = self.applyFrozenBorderIfNeeded(to: frozenWindow.image, scale: frozenWindow.scale)
                    let selectionSize = CGSize(
                        width: frozenWindow.pointSize.width + padding.left + padding.right,
                        height: frozenWindow.pointSize.height + padding.top + padding.bottom
                    )
                    frozenWindow = FrozenWindowSnapshot(
                        image: bordered,
                        padding: padding,
                        pointSize: selectionSize,
                        borderApplied: true,
                        scale: frozenWindow.scale
                    )
                    self.frozenWindowSnapshots[windowResult.windowID] = frozenWindow
                }
                let selectionRect = CGRect(origin: .zero, size: frozenWindow.pointSize)
                switch self.captureMode {
                case .advanced:
                    self.handleAdvancedCapture(cgImage: frozenWindow.image, selectionRect: selectionRect)
                case .ocr:
                    self.performOCRFrozenCapture(cgImage: frozenWindow.image, selectionRect: selectionRect)
                case .quick:
                    self.handleSuccessfulCapture(cgImage: frozenWindow.image, selectionRect: selectionRect)
                }
                self.frozenDisplaySnapshots.removeAll()
                self.frozenWindowSnapshots.removeAll()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.selectionWindow = nil
                }
                return
            } else if let frozen = self.frozenCapture(for: windowResult.bounds) {
                switch self.captureMode {
                case .advanced:
                    let sizeRect = CGRect(origin: .zero, size: windowResult.bounds.size)
                    self.handleAdvancedCapture(cgImage: frozen, selectionRect: sizeRect)
                case .ocr:
                    self.performOCRFrozenCapture(cgImage: frozen, selectionRect: windowResult.bounds)
                case .quick:
                    let sizeRect = CGRect(origin: .zero, size: windowResult.bounds.size)
                    self.handleSuccessfulCapture(cgImage: frozen, selectionRect: sizeRect)
                }
                self.frozenDisplaySnapshots.removeAll()
                self.frozenWindowSnapshots.removeAll()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.selectionWindow = nil
                }
                return
            }

            switch self.captureMode {
            case .advanced:
                self.performAdvancedWindowCapture(hitResult: windowResult, excludeWindowIDs: overlayWindowIDs)
            case .ocr:
                self.performOCRWindowCapture(hitResult: windowResult, excludeWindowIDs: overlayWindowIDs)
            case .quick:
                self.performWindowCapture(hitResult: windowResult, excludeWindowIDs: overlayWindowIDs)
            }

            self.frozenDisplaySnapshots.removeAll()
            self.frozenWindowSnapshots.removeAll()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.selectionWindow = nil
            }
        }
    }

    func selectionWindowDidCancel(_ window: SelectionWindow) {
        // Hide all selection windows
        window.hide()

        captureMode = .quick

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.selectionWindow = nil
            self?.frozenDisplaySnapshots.removeAll()
            self?.frozenWindowSnapshots.removeAll()
        }
    }
    private func showErrorAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("error.capture_error", comment: "")
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: - Frozen screenshot helpers

    private struct FrozenSnapshots {
        let displaySnapshots: [CGDirectDisplayID: CGImage]
        let windowSnapshots: [CGWindowID: FrozenWindowSnapshot]
    }

    private func startSelectionFlow(overlayConfiguration: SelectionOverlayView.Configuration) {
        Task { [weak self] in
            guard let self = self else { return }
            var overlayWindowIDs: [CGWindowID] = await MainActor.run { [weak self] in
                guard let self = self else { return [] }
                let window = SelectionWindow(
                    frozenScreenshots: self.frozenDisplaySnapshots,
                    overlayConfiguration: overlayConfiguration
                )
                window.selectionDelegate = self
                window.show()
                self.selectionWindow = window
                return window.getOverlayWindowIDs()
            }
            // 有时窗口刚创建时 windowNumber 还没准备好，导致排除列表为空；稍等一帧再取一次，避免把遮罩本身截图进背景导致“双重遮罩”。
            if overlayWindowIDs.isEmpty {
                try? await Task.sleep(nanoseconds: 50_000_000) // 50 ms
                overlayWindowIDs = await MainActor.run { [weak self] in
                    guard let self = self else { return [] }
                    return self.selectionWindow?.getOverlayWindowIDs() ?? []
                }
            }
            if overlayWindowIDs.isEmpty {
                return
            }
            do {
                let snapshots = try await self.prepareFrozenSnapshotsWithScreenCaptureKit(excludingWindowIDs: overlayWindowIDs)
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.frozenDisplaySnapshots = snapshots.displaySnapshots
                    self.frozenWindowSnapshots = snapshots.windowSnapshots
                    self.selectionWindow?.updateBackgroundSnapshots(snapshots.displaySnapshots)
                }
            } catch {
                await MainActor.run {
                    self.showErrorAlert(error.localizedDescription)
                }
            }
        }
    }

    private func prepareFrozenSnapshotsWithScreenCaptureKit(excludingWindowIDs: [CGWindowID]) async throws -> FrozenSnapshots {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let excludeSet = Set(excludingWindowIDs)
        let excludedWindows = content.windows.filter { excludeSet.contains(CGWindowID($0.windowID)) }

        var displaySnapshots: [CGDirectDisplayID: CGImage] = [:]
        for screen in NSScreen.screens {
            guard
                let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                let scDisplay = content.displays.first(where: { $0.displayID == displayID })
            else { continue }

            if let image = try? await captureDisplaySnapshot(screen: screen, scDisplay: scDisplay, excludedWindows: excludedWindows) {
                displaySnapshots[displayID] = image
            }
        }

        var windowSnapshots: [CGWindowID: FrozenWindowSnapshot] = [:]
        for window in content.windows {
            if excludeSet.contains(CGWindowID(window.windowID)) { continue }
            do {
                let snapshot = try await captureWindowSnapshot(window: window, applyBorder: false)
                windowSnapshots[CGWindowID(window.windowID)] = snapshot
            } catch {
                // Skip windows that fail to capture to avoid blocking the whole flow
                continue
            }
        }

        return FrozenSnapshots(displaySnapshots: displaySnapshots, windowSnapshots: windowSnapshots)
    }

    private func captureDisplaySnapshot(
        screen: NSScreen,
        scDisplay: SCDisplay,
        excludedWindows: [SCWindow]
    ) async throws -> CGImage {
        let filter = SCContentFilter(display: scDisplay, excludingWindows: excludedWindows)
        let config = SCStreamConfiguration()
        let scale = screen.backingScaleFactor
        config.width = Int(screen.frame.width * scale)
        config.height = Int(screen.frame.height * scale)
        config.sourceRect = CGRect(origin: .zero, size: screen.frame.size)
        config.captureResolution = .best
        config.showsCursor = false
        config.scalesToFit = false

        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    private func captureWindowSnapshot(window: SCWindow, applyBorder: Bool) async throws -> FrozenWindowSnapshot {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let rect = filter.contentRect
        let scale = filter.pointPixelScale

        let config = SCStreamConfiguration()
        let scaleCGFloat = CGFloat(scale)
        config.width = max(1, Int(rect.width * scaleCGFloat))
        config.height = max(1, Int(rect.height * scaleCGFloat))
        config.captureResolution = .best
        config.showsCursor = false
        config.scalesToFit = false

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )

        if applyBorder {
            let (bordered, padding) = applyFrozenBorderIfNeeded(to: image, scale: scaleCGFloat)
            let pointSize = CGSize(
                width: rect.width + padding.left + padding.right,
                height: rect.height + padding.top + padding.bottom
            )
            return FrozenWindowSnapshot(
                image: bordered,
                padding: padding,
                pointSize: pointSize,
                borderApplied: true,
                scale: scaleCGFloat
            )
        } else {
            let padding = NSEdgeInsets()
            let pointSize = CGSize(width: rect.width, height: rect.height)
            return FrozenWindowSnapshot(
                image: image,
                padding: padding,
                pointSize: pointSize,
                borderApplied: false,
                scale: scaleCGFloat
            )
        }
    }

    private func frozenCapture(for rect: CGRect) -> CGImage? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) else { return nil }
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
        guard let snapshot = frozenDisplaySnapshots[displayID] else { return nil }

        let frame = screen.frame
        // Use the captured image dimensions to derive scale (handles Retina)
        let scaleX = CGFloat(snapshot.width) / frame.width
        let scaleY = CGFloat(snapshot.height) / frame.height
        let scale = max(scaleX, scaleY)

        let offsetX = (rect.origin.x - frame.origin.x) * scale
        let offsetY = (rect.origin.y - frame.origin.y) * scale
        let width = rect.width * scale
        let height = rect.height * scale

        let imageHeight = CGFloat(snapshot.height)
        let cropRect = CGRect(
            x: offsetX,
            y: imageHeight - offsetY - height,
            width: width,
            height: height
        )
        let boundedCrop = cropRect.intersection(CGRect(origin: .zero, size: CGSize(width: snapshot.width, height: snapshot.height)))
        guard boundedCrop.width > 0, boundedCrop.height > 0 else { return nil }

        return snapshot.cropping(to: boundedCrop)
    }

    private func performOCRFrozenCapture(cgImage: CGImage, selectionRect: CGRect) {
        captureMode = .quick

        Task { [weak self] in
            guard let self else { return }

            do {
                let settings = AppSettings.shared
                if settings.playSoundOnCapture {
                    let systemSoundPath = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
                    if let sound = NSSound(contentsOfFile: systemSoundPath, byReference: true) {
                        sound.play()
                    } else if let fallback = NSSound(named: NSSound.Name("Glass")) {
                        fallback.play()
                    }
                }

                guard let ocrImage = self.makePNGImageForOCR(cgImage: cgImage, pointSize: selectionRect.size) else {
                    await MainActor.run {
                        self.showOCRFeedback(style: .failure, key: "toast.ocr.failure", fallback: "OCR 失败")
                    }
                    return
                }

                let text = try await OCRService.recognizeText(
                    in: ocrImage,
                    region: nil,
                    preferredLanguages: settings.ocrRecognitionLanguages
                )

                await MainActor.run {
                    self.handleOCRResult(text)
                }
            } catch {
                await MainActor.run {
                    self.showOCRFeedback(style: .failure, key: "toast.ocr.failure", fallback: "OCR 失败")
                }
            }
        }
    }

    private func applyFrozenBorderIfNeeded(to image: CGImage, scale: CGFloat) -> (CGImage, NSEdgeInsets) {
        let settings = AppSettings.shared
        let borderEnabled = settings.windowBorderEnabled
        let borderPoints = CGFloat(settings.windowBorderWidth)
        let borderCornerRadius = CGFloat(settings.windowBorderCornerRadius)
        guard borderEnabled, borderPoints > 0 else { return (image, NSEdgeInsets()) }

        let borderColor = settings.windowBorderColor.cgColor ?? CGColor(gray: 1, alpha: 1)
        let borderPixels = max(1, Int(ceil(borderPoints * scale)))
        let newWidth = image.width + borderPixels * 2
        let newHeight = image.height + borderPixels * 2
        let cornerRadiusPixels = max(0, borderCornerRadius * scale)

        guard let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else {
            return (image, NSEdgeInsets())
        }

        guard let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: image.bitsPerComponent,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return (image, NSEdgeInsets())
        }

        // Fill border area with rounded corners using continuous curve
        let shapeLayer = CALayer()
        shapeLayer.frame = CGRect(x: 0, y: 0, width: newWidth, height: newHeight)
        shapeLayer.backgroundColor = borderColor
        shapeLayer.cornerRadius = cornerRadiusPixels
        shapeLayer.cornerCurve = .continuous
        shapeLayer.masksToBounds = true
        shapeLayer.contentsScale = scale
        shapeLayer.render(in: context)

        context.draw(
            image,
            in: CGRect(
                x: borderPixels,
                y: borderPixels,
                width: image.width,
                height: image.height
            )
        )

        guard let bordered = context.makeImage() else {
            return (image, NSEdgeInsets())
        }

        let paddingPoints = NSEdgeInsets(
            top: CGFloat(borderPixels) / scale,
            left: CGFloat(borderPixels) / scale,
            bottom: CGFloat(borderPixels) / scale,
            right: CGFloat(borderPixels) / scale
        )

        return (bordered, paddingPoints)
    }

    // MARK: - Notification Routing

    /// Affiche une notification macOS native (toujours UNUserNotification)
    private func showSuccessNotification(filePath: String?) {
        let content = UNMutableNotificationContent()
        content.title = "PastScreen-CN"
        content.body = NSLocalizedString("notification.screenshot_saved", comment: "")
        content.sound = nil  // conserver uniquement le son "Glass" joué avant la notification

        if let filePath = filePath {
            content.userInfo = ["filePath": filePath]
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        // Send notification without changing activation policy
        // (avoids Dock icon flash that confuses users)
        UNUserNotificationCenter.current().add(request) { _ in }

        DynamicIslandManager.shared.show(message: "已保存", duration: 3.0)
    }

    private func performCapture(rect: CGRect, excludeWindowIDs: [CGWindowID] = []) {
        // Vérifier que le rectangle est valide
        guard rect.width > 0 && rect.height > 0 else {
            DispatchQueue.main.async { [weak self] in
                self?.showErrorNotification(error: NSError(domain: "ScreenshotService", code: -1, userInfo: [NSLocalizedDescriptionKey: "选区无效"]))
            }
            return
        }

        Task { [weak self] in
            guard let self = self else { return }

            do {
                // Essayer d'abord avec ScreenCaptureKit (moderne)
                let cgImage = try await self.captureWithScreenCaptureKit(rect: rect, excludeWindowIDs: excludeWindowIDs)
                await MainActor.run {
                    self.handleSuccessfulCapture(cgImage: cgImage, selectionRect: rect)
                }

            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.showErrorNotification(error: error)
                }
            }
        }
    }
    
    private func performAdvancedCapture(rect: CGRect, excludeWindowIDs: [CGWindowID] = []) {
        captureMode = .quick

        // Vérifier que le rectangle est valide
        guard rect.width > 0 && rect.height > 0 else {
            DispatchQueue.main.async { [weak self] in
                self?.showErrorNotification(error: NSError(domain: "ScreenshotService", code: -1, userInfo: [NSLocalizedDescriptionKey: "选区无效"]))
            }
            return
        }

        Task { [weak self] in
            guard let self = self else { return }

            do {
                // Capture screenshot with ScreenCaptureKit
                let cgImage = try await self.captureWithScreenCaptureKit(rect: rect, excludeWindowIDs: excludeWindowIDs)
                await MainActor.run {
                    self.handleAdvancedCapture(cgImage: cgImage, selectionRect: rect)
                }

            } catch {
                await MainActor.run { [weak self] in
                    self?.showErrorNotification(error: error)
                }
            }
        }
    }

    private func performWindowCapture(hitResult: WindowHitTestResult, excludeWindowIDs: [CGWindowID]) {
        _ = excludeWindowIDs // 已通过命中窗口过滤，本次捕获不需要排除其它窗口
        Task { [weak self] in
            guard let self = self else { return }

            do {
                let captureResult = try await WindowCaptureCoordinator.shared.captureWindow(using: hitResult)
                let padding = captureResult.paddingPoints
                let sizeRect = CGRect(
                    origin: .zero,
                    size: CGSize(
                        width: captureResult.window.frame.size.width + padding.left + padding.right,
                        height: captureResult.window.frame.size.height + padding.top + padding.bottom
                    )
                )
                await MainActor.run {
                    self.handleSuccessfulCapture(cgImage: captureResult.image, selectionRect: sizeRect)
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.showErrorNotification(error: error)
                }
            }
        }
    }

    private func performAdvancedWindowCapture(hitResult: WindowHitTestResult, excludeWindowIDs: [CGWindowID]) {
        _ = excludeWindowIDs // 已通过命中窗口过滤，本次捕获不需要排除其它窗口
        captureMode = .quick
        Task { [weak self] in
            guard let self = self else { return }

            do {
                let captureResult = try await WindowCaptureCoordinator.shared.captureWindow(using: hitResult)
                let padding = captureResult.paddingPoints
                let sizeRect = CGRect(
                    origin: .zero,
                    size: CGSize(
                        width: captureResult.window.frame.size.width + padding.left + padding.right,
                        height: captureResult.window.frame.size.height + padding.top + padding.bottom
                    )
                )
                await MainActor.run {
                    self.handleAdvancedCapture(cgImage: captureResult.image, selectionRect: sizeRect)
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.showErrorNotification(error: error)
                }
            }
        }
    }

    // Nouvelle méthode avec ScreenCaptureKit
    private func captureWithScreenCaptureKit(rect: CGRect, excludeWindowIDs: [CGWindowID]) async throws -> CGImage {
        return try await captureScreenRegion(rect: rect, excludeWindowIDs: excludeWindowIDs)
    }

    // Handle successful advanced capture - show editing window
    private func handleAdvancedCapture(cgImage: CGImage, selectionRect: CGRect) {
        captureMode = .quick
        // Create NSImage from CGImage
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = selectionRect.size
        let nsImage = NSImage(size: selectionRect.size)
        nsImage.addRepresentation(rep)

        // Show editing window
        let editingWindow = ImageEditingWindow(
            image: nsImage,
            onCompletion: { [weak self] editedImage in
                self?.handleEditedImage(editedImage: editedImage, selectionRect: selectionRect)
            },
            onCancel: {
                // Just close editing window, no further action - user cancelled
            }
        )
        
        editingWindow.show()
    }

    private func performOCRCapture(rect: CGRect, excludeWindowIDs: [CGWindowID] = []) {
        captureMode = .quick

        guard rect.width > 0, rect.height > 0 else {
            showOCRFeedback(style: .failure, key: "toast.ocr.failure", fallback: "OCR 失败")
            return
        }

        Task { [weak self] in
            guard let self else { return }

            do {
                let cgImage = try await self.captureWithScreenCaptureKit(rect: rect, excludeWindowIDs: excludeWindowIDs)

                let settings = AppSettings.shared
                if settings.playSoundOnCapture {
                    let systemSoundPath = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
                    if let sound = NSSound(contentsOfFile: systemSoundPath, byReference: true) {
                        sound.play()
                    } else if let fallback = NSSound(named: NSSound.Name("Glass")) {
                        fallback.play()
                    }
                }

                guard let ocrImage = self.makePNGImageForOCR(cgImage: cgImage, pointSize: rect.size) else {
                    await MainActor.run {
                        self.showOCRFeedback(style: .failure, key: "toast.ocr.failure", fallback: "OCR 失败")
                    }
                    return
                }

                let text = try await OCRService.recognizeText(
                    in: ocrImage,
                    region: nil,
                    preferredLanguages: settings.ocrRecognitionLanguages
                )

                await MainActor.run {
                    self.handleOCRResult(text)
                }
            } catch {
                await MainActor.run {
                    self.showOCRFeedback(style: .failure, key: "toast.ocr.failure", fallback: "OCR 失败")
                }
            }
        }
    }

    private func performOCRWindowCapture(hitResult: WindowHitTestResult, excludeWindowIDs: [CGWindowID]) {
        _ = excludeWindowIDs // 已通过命中窗口过滤，本次捕获不需要排除其它窗口
        captureMode = .quick

        Task { [weak self] in
            guard let self else { return }

            do {
                let captureResult = try await WindowCaptureCoordinator.shared.captureWindow(
                    using: hitResult,
                    applyBorder: false
                )

                let settings = AppSettings.shared
                if settings.playSoundOnCapture {
                    let systemSoundPath = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
                    if let sound = NSSound(contentsOfFile: systemSoundPath, byReference: true) {
                        sound.play()
                    } else if let fallback = NSSound(named: NSSound.Name("Glass")) {
                        fallback.play()
                    }
                }

                let padding = captureResult.paddingPoints
                let pointSize = CGSize(
                    width: captureResult.window.frame.size.width + padding.left + padding.right,
                    height: captureResult.window.frame.size.height + padding.top + padding.bottom
                )

                guard let ocrImage = self.makePNGImageForOCR(cgImage: captureResult.image, pointSize: pointSize) else {
                    await MainActor.run {
                        self.showOCRFeedback(style: .failure, key: "toast.ocr.failure", fallback: "OCR 失败")
                    }
                    return
                }

                let text = try await OCRService.recognizeText(
                    in: ocrImage,
                    region: nil,
                    preferredLanguages: settings.ocrRecognitionLanguages
                )

                await MainActor.run {
                    self.handleOCRResult(text)
                }
            } catch {
                await MainActor.run {
                    self.showOCRFeedback(style: .failure, key: "toast.ocr.failure", fallback: "OCR 失败")
                }
            }
        }
    }

    private func makePNGImageForOCR(cgImage: CGImage, pointSize: CGSize) -> NSImage? {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = pointSize
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        return NSImage(data: data)
    }

    private func handleOCRResult(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showOCRFeedback(style: .failure, key: "toast.ocr.no_text", fallback: "未识别到文字")
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(trimmed, forType: .string)

        showOCRFeedback(style: .success, key: "toast.ocr.success", fallback: "OCR 已复制")
    }

    private func showOCRFeedback(style: DynamicIslandManager.Style, key: String, fallback: String) {
        DynamicIslandManager.shared.show(
            message: NSLocalizedString(key, value: fallback, comment: ""),
            duration: 2.0,
            style: style
        )
    }
    
    // Handle the edited image from the editing window
    private func handleEditedImage(editedImage: NSImage, selectionRect: CGRect) {
        let settings = AppSettings.shared
        let allowSaving = settings.saveToFile && settings.hasValidSaveFolder

        // Play capture sound if enabled
        if settings.playSoundOnCapture {
            let systemSoundPath = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
            if let sound = NSSound(contentsOfFile: systemSoundPath, byReference: true) {
                sound.play()
            } else if let fallback = NSSound(named: NSSound.Name("Glass")) {
                fallback.play()
            }
        }

        // Convert NSImage back to CGImage for clipboard operations
        guard let cgImage = editedImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            showErrorNotification(error: NSError(domain: "ScreenshotService", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法处理编辑后的图片"]))
            return
        }

        let clipboardFilePath = self.copyToClipboard(
            image: editedImage,
            cgImage: cgImage,
            pointSize: selectionRect.size
        )

        // Save to file if enabled (or reuse path already created for clipboard)
        var filePath: String? = clipboardFilePath
        if allowSaving && filePath == nil {
            filePath = self.saveToFileAndGetPath(
                cgImage: cgImage,
                pointSize: selectionRect.size
            )
        }

        if allowSaving, let filePath = filePath {
            NotificationCenter.default.post(name: .screenshotCaptured, object: nil, userInfo: ["filePath": filePath])
            settings.addToHistory(filePath)
        }

        // Show notification and visual feedback
        self.showSuccessNotification(filePath: filePath)
    }

    // Gestion commune du succès
    private func handleSuccessfulCapture(cgImage: CGImage, selectionRect: CGRect) {
        let settings = AppSettings.shared
        let allowSaving = settings.saveToFile && settings.hasValidSaveFolder

        // Play capture sound if enabled
        if settings.playSoundOnCapture {
            let systemSoundPath = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
            if let sound = NSSound(contentsOfFile: systemSoundPath, byReference: true) {
                sound.play()
            } else if let fallback = NSSound(named: NSSound.Name("Glass")) {
                fallback.play()
            }
        }

        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = selectionRect.size
        let nsImage = NSImage(size: selectionRect.size)
        nsImage.addRepresentation(rep)

        let clipboardFilePath = self.copyToClipboard(
            image: nsImage,
            cgImage: cgImage,
            pointSize: selectionRect.size
        )

        // Save to file if enabled (or reuse path already created for clipboard)
        var filePath: String? = clipboardFilePath
        if allowSaving && filePath == nil {
            filePath = self.saveToFileAndGetPath(
                cgImage: cgImage,
                pointSize: selectionRect.size
            )
        }

        if allowSaving, let filePath = filePath {
            NotificationCenter.default.post(name: .screenshotCaptured, object: nil, userInfo: ["filePath": filePath])
            settings.addToHistory(filePath)
        }

        // Show notification and visual feedback
        self.showSuccessNotification(filePath: filePath)
    }

    private func captureScreenRegion(rect: CGRect, excludeWindowIDs: [CGWindowID]) async throws -> CGImage {
        // Vérification de base du rectangle
        guard rect.width > 0 && rect.height > 0 else {
            throw NSError(domain: "ScreenshotService", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "无效选区：\(rect)"
            ])
        }

        do {
            // 1. Obtenir le contenu partageable
            let content = try await SCShareableContent.current

            // 2. Find NSScreen that contains the selection rect
                guard let nsScreen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) else {
                    throw NSError(domain: "ScreenshotService", code: -2, userInfo: [
                        NSLocalizedDescriptionKey: "未找到包含所选区域的屏幕"
                    ])
                }

            // 3. Match NSScreen to SCDisplay by displayID
            let displayID = nsScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            let targetDisplay: SCDisplay
            if let matchedDisplay = content.displays.first(where: { $0.displayID == displayID }) {
                targetDisplay = matchedDisplay
            } else {
                guard let fallbackDisplay = content.displays.first else {
                        throw NSError(domain: "ScreenshotService", code: -3, userInfo: [
                            NSLocalizedDescriptionKey: "未找到可用显示器"
                        ])
                    }
                targetDisplay = fallbackDisplay
            }

            let screenFrame = nsScreen.frame
            // AppKit uses a global coordinate system origin at bottom-left,
            // but our SelectionWindow delivers a rect in global coordinates with the origin
            // still bottom-left yet user selection is visually referenced from the top-left
            // of each screen. ScreenCaptureKit expects the rect relative to the display's
            // coordinate space with origin top-left, so we need to flip the Y axis.
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
                    throw NSError(domain: "ScreenshotService", code: -4, userInfo: [
                        NSLocalizedDescriptionKey: "选区完全位于屏幕范围之外"
                    ])
                }
            }

            // 4. Convert window IDs to SCWindow objects for exclusion
            let excludeWindows = content.windows.filter {
                excludeWindowIDs.contains(CGWindowID($0.windowID))
            }

            // 5. Créer le filtre de contenu (capture le BON écran, SAUF les overlays)
            let filter = SCContentFilter(display: targetDisplay, excludingWindows: excludeWindows)

            // 6. Determine backing scale factor (Retina = 2.0, non-Retina = 1.0)
            // Use the nsScreen we already found
            let scaleFactor = nsScreen.backingScaleFactor

            // 7. Configuration avec résolution native (points × scale factor = pixels)
            let config = SCStreamConfiguration()
            config.width = Int(relativeRect.width * scaleFactor)  // Convert points to pixels
            config.height = Int(relativeRect.height * scaleFactor)  // Convert points to pixels
            config.sourceRect = relativeRect  // Relative to target display coordinates
            config.scalesToFit = false
            config.showsCursor = false
            config.captureResolution = .best

            // 8. Capture avec l'API officielle
            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )

            return cgImage

        } catch let error as SCStreamError {
            // Gestion spécifique des erreurs ScreenCaptureKit
            switch error.code {
            case .userDeclined:
                throw NSError(domain: "ScreenshotService", code: -10, userInfo: [
                    NSLocalizedDescriptionKey: "屏幕录制权限被拒绝。请前往“系统设置 → 隐私与安全性 → 屏幕录制”。"
                ])
            case .systemStoppedStream:
                throw NSError(domain: "ScreenshotService", code: -11, userInfo: [
                    NSLocalizedDescriptionKey: "截图被系统中断"
                ])
            default:
                throw NSError(domain: "ScreenshotService", code: -12, userInfo: [
                    NSLocalizedDescriptionKey: "截图错误：\(error.localizedDescription)"
                ])
            }

        } catch {
            throw NSError(domain: "ScreenshotService", code: -13, userInfo: [
                NSLocalizedDescriptionKey: "截图失败：\(error.localizedDescription)"
            ])
        }
    }

    // MARK: - Smart Clipboard Detection

    /// Capture the frontmost application BEFORE showing selection window
    func capturePreviousApp() {
        previousApp = NSWorkspace.shared.frontmostApplication
    }

    /// Detect the application category based on previously captured app
    private func detectFrontmostApp() -> AppCategory {
        guard let app = previousApp,
              let bundleID = app.bundleIdentifier else {
            return .unknown
        }
        return appCategoryMap[bundleID] ?? .unknown
    }

    /// Copy image to clipboard - SIMPLE LOGIC
    /// Default: Image only (works everywhere including AI agents)
    /// Path override: Path text only (for terminals)
    @discardableResult
    private func copyToClipboard(
        image: NSImage,
        cgImage: CGImage,
        pointSize: CGSize
    ) -> String? {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let settings = AppSettings.shared
        let allowSaving = settings.saveToFile && settings.hasValidSaveFolder

        // Only save when user enabled it and a valid folder is configured
        var filePath: String?
        if allowSaving {
            filePath = saveToFileAndGetPath(cgImage: cgImage, pointSize: pointSize)
        }

        // Check for App Override
        var usePathOnly = false
        if let bundleID = previousApp?.bundleIdentifier,
           let override = settings.getOverride(for: bundleID) {
            if override == .path {
                usePathOnly = true
            }
        }

        if usePathOnly {
            // PATH ONLY - For terminals
            if let imagePath = filePath {
                pasteboard.setString(imagePath, forType: .string)
            } else {
                // Fallback to image copy if no path is available
                pasteboard.writeObjects([image])
            }
        } else {
            // IMAGE ONLY - Default behavior (works with AI agents, browsers, etc.)
            pasteboard.writeObjects([image])
        }

        return filePath
    }

    /// Save image to file (with DPI metadata) and return the path
    private func saveToFileAndGetPath(
        cgImage: CGImage,
        pointSize: CGSize
    ) -> String? {
        let bitmapImage = NSBitmapImageRep(cgImage: cgImage)
        bitmapImage.size = pointSize

        let fileType: NSBitmapImageRep.FileType
        let fileExtension: String

        switch AppSettings.shared.imageFormat {
        case "jpeg":
            fileType = .jpeg
            fileExtension = "jpg"
        default:
            fileType = .png
            fileExtension = "png"
        }

        guard let data = bitmapImage.representation(using: fileType, properties: [:]) else {
            return nil
        }

        // Incremental naming logic: Screen-1.png, Screen-2.png...
        var seq = AppSettings.shared.screenshotSequence
        var filename = "Screen-\(seq).\(fileExtension)"

        // Ensure folder exists
        AppSettings.shared.ensureFolderExists()
        let folderPath = AppSettings.shared.saveFolderPath

        // Ensure uniqueness
        let fileManager = FileManager.default
        var savePath = folderPath + filename

        while fileManager.fileExists(atPath: savePath) {
            seq += 1
            filename = "Screen-\(seq).\(fileExtension)"
            savePath = folderPath + filename
        }

        // Save next sequence number
        AppSettings.shared.screenshotSequence = seq + 1

        do {
            try data.write(to: URL(fileURLWithPath: savePath))
            return savePath
        } catch {
            // Fallback to Temporary Directory if main save fails (Sandbox/Permission issues)
            let tempFolder = NSTemporaryDirectory()
            let tempPath = (tempFolder as NSString).appendingPathComponent(filename)

            do {
                try data.write(to: URL(fileURLWithPath: tempPath))
                return tempPath
            } catch {
                return nil
            }
        }
    }

    private func showErrorNotification(error: Error) {
        // For errors, show a proper alert dialog
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "截图错误"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "确定")
            alert.runModal()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
