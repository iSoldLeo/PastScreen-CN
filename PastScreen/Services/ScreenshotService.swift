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
    private var isAdvancedCapture: Bool = false // Flag to distinguish advanced capture

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

        // Create and show custom selection window (one per screen for multi-monitor support)
        selectionWindow = SelectionWindow()
        selectionWindow?.selectionDelegate = self
        selectionWindow?.show()
    }
    
    func captureAdvancedScreenshot() {
        // CRITICAL: Force cleanup of any existing selection window before creating new one
        if let existingWindow = selectionWindow {
            existingWindow.hide()
            selectionWindow = nil
        }
        
        // Set flag for advanced capture
        isAdvancedCapture = true

        // Create and show custom selection window for advanced capture
        selectionWindow = SelectionWindow()
        selectionWindow?.selectionDelegate = self
        selectionWindow?.show()
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

            // Now perform capture with overlay windows excluded
            if self.isAdvancedCapture {
                self.performAdvancedCapture(rect: rect, excludeWindowIDs: overlayWindowIDs)
            } else {
                self.performCapture(rect: rect, excludeWindowIDs: overlayWindowIDs)
            }

            // Cleanup window reference
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.selectionWindow = nil
            }
        }
    }

    func selectionWindowDidCancel(_ window: SelectionWindow) {
        // Hide all selection windows
        window.hide()
        
        // Reset advanced capture flag
        isAdvancedCapture = false

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.selectionWindow = nil
        }
    }
    private func showErrorAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("error.capture_error", comment: "")
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
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
                    // Reset the advanced capture flag on error
                    self?.isAdvancedCapture = false
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
        // Create NSImage from CGImage
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = selectionRect.size
        let nsImage = NSImage(size: selectionRect.size)
        nsImage.addRepresentation(rep)
        
        // Reset the advanced capture flag
        isAdvancedCapture = false
        
        // Show editing window
        let editingWindow = ImageEditingWindow(
            image: nsImage,
            onCompletion: { [weak self] editedImage in
                self?.handleEditedImage(editedImage: editedImage, selectionRect: selectionRect)
            },
            onCancel: { [weak self] in
                // Just close editing window, no further action - user cancelled
            }
        )
        
        editingWindow.show()
    }
    
    // Handle the edited image from the editing window
    private func handleEditedImage(editedImage: NSImage, selectionRect: CGRect) {
        // Play capture sound if enabled
        if AppSettings.shared.playSoundOnCapture {
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
        if AppSettings.shared.saveToFile {
            if filePath == nil {
                filePath = self.saveToFileAndGetPath(
                    cgImage: cgImage,
                    pointSize: selectionRect.size
                )
            }
        }

        if let filePath = filePath {
            NotificationCenter.default.post(name: .screenshotCaptured, object: nil, userInfo: ["filePath": filePath])
            AppSettings.shared.addToHistory(filePath)
        }

        // Show notification and visual feedback
        self.showSuccessNotification(filePath: filePath)
    }

    // Gestion commune du succès
    private func handleSuccessfulCapture(cgImage: CGImage, selectionRect: CGRect) {
        // Play capture sound if enabled
        if AppSettings.shared.playSoundOnCapture {
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
        if AppSettings.shared.saveToFile {
            if filePath == nil {
                filePath = self.saveToFileAndGetPath(
                    cgImage: cgImage,
                    pointSize: selectionRect.size
                )
            }
        }

        if let filePath = filePath {
            NotificationCenter.default.post(name: .screenshotCaptured, object: nil, userInfo: ["filePath": filePath])
            AppSettings.shared.addToHistory(filePath)
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

        // Always save file first (for history and potential path use)
        let filePath = saveToFileAndGetPath(cgImage: cgImage, pointSize: pointSize)

        // Check for App Override
        var usePathOnly = false
        if let bundleID = previousApp?.bundleIdentifier,
           let override = AppSettings.shared.getOverride(for: bundleID) {
            if override == .path {
                usePathOnly = true
            }
        }

        if usePathOnly {
            // PATH ONLY - For terminals
            if let imagePath = filePath {
                pasteboard.setString(imagePath, forType: .string)
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
