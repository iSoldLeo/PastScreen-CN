//
//  ScreenshotService.swift
//  PastScreen
//
//  Screenshot capture service with Liquid Glass selection UI
//

import Foundation
@preconcurrency import AppKit  // NSBitmapImageRep, NSImage 等未标记 Sendable
import CoreGraphics
import SwiftUI
import UserNotifications
// @preconcurrency: SCDisplay, SCWindow, SCContentFilter, SCStreamConfiguration, etc.
// are not marked Sendable by Apple. Suppresses warnings for framework types only.
@preconcurrency import ScreenCaptureKit
import QuartzCore

// MARK: - App Category Detection

/// CGImage 的 Sendable 包装。CGImage 是不可变的 Core Foundation 引用类型，
/// 创建后像素数据不可修改，因此跨并发域读取是安全的。
struct SendableCGImage: @unchecked Sendable {
    let image: CGImage

    init(_ image: CGImage) {
        self.image = image
    }
}

enum AppCategory: Sendable {
    case codeEditor
    case webBrowser
    case designTool
    case unknown
}

enum CaptureMode {
    case quick
    case advanced
}

enum CaptureItemCaptureType: Int, Codable, CaseIterable, Sendable {
    case area = 0
    case window = 1
    case fullscreen = 2
}

@MainActor
class ScreenshotService: NSObject, SelectionWindowDelegate {
    private var previousApp: NSRunningApplication? // Store app that was active before capture
    private var selectionWindow: SelectionWindow? // Custom selection window
    private var frozenDisplaySnapshots: [CGDirectDisplayID: SendableCGImage] = [:] // Per-display snapshots captured via ScreenCaptureKit
    private var frozenWindowSnapshots: [CGWindowID: FrozenWindowSnapshot] = [:] // Per-window snapshots captured via ScreenCaptureKit
    private struct FrozenWindowSnapshot: Sendable {
        let image: SendableCGImage
        let padding: EdgeInsetValues
        let pointSize: CGSize
        let borderApplied: Bool
        let scale: CGFloat
        let appBundleID: String?
        let appName: String?
    }

    private var captureMode: CaptureMode = .quick
    private var captureTrigger: CaptureTrigger = .menuBar
    private var selectionSessionID: UUID?
    private var windowSnapshotTask: Task<Void, Never>?
    private let appBundleID = Bundle.main.bundleIdentifier
    private var maxFrozenWindowSnapshotsPerDisplay: Int {
        max(AppSettings.shared.frozenWindowLimitPerDisplay, 5)
    }

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

    func captureScreenshot(trigger: CaptureTrigger = .menuBar) {
        // CRITICAL: Force cleanup of any existing selection window before creating new one
        // (prevents overlay windows from persisting if user takes multiple screenshots rapidly)
        if let existingWindow = selectionWindow {
            existingWindow.hide()
            endSelectionSession()
            selectionWindow = nil
        }

        captureMode = .quick
        captureTrigger = trigger
        startSelectionFlow(overlayConfiguration: .screenshot)
    }

    // NEW: Full screen capture using ScreenCaptureKit
    func captureFullScreen(trigger: CaptureTrigger = .menuBar) {
        captureTrigger = trigger
        // Calculate combined frame covering all screens
        let screenFrame = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
        performCapture(rect: screenFrame, captureType: .fullscreen, trigger: trigger)
    }

    // MARK: - SelectionWindowDelegate

    func selectionWindow(_ window: SelectionWindow, didSelectRect rect: CGRect) {
        // Get overlay window IDs BEFORE hiding (for ScreenCaptureKit exclusion)
        let overlayWindowIDs = window.getOverlayWindowIDs()
        let shouldPostCaptureFlowEnded = captureMode != .advanced
        let trigger = captureTrigger

        // Hide all selection windows
        window.hide()

        // If we're not going into an in-app editor, restore focus immediately so the previously
        // active window doesn't remain unfocused while we capture/copy in the background.
        if captureMode != .advanced {
            restorePreviousAppFocus()
        }

        // CRITICAL: Wait for windows to be visually hidden before capturing
        // ScreenCaptureKit captures everything on screen, including overlays
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self = self else { return }

            if let frozen = self.frozenCapture(for: rect) {
                switch self.captureMode {
                case .advanced:
                    logError("Advanced capture mode is not implemented; falling back to quick capture", category: "SCREENSHOT")
                    fallthrough
                case .quick:
                    self.handleSuccessfulCapture(cgImage: frozen, selectionRect: rect, captureType: .area, trigger: trigger)
                }
                self.frozenDisplaySnapshots.removeAll()
                self.frozenWindowSnapshots.removeAll()
                self.scheduleSelectionCleanup(postCaptureFlowEnded: shouldPostCaptureFlowEnded)
                return
            }

            // Now perform capture with overlay windows excluded
            switch self.captureMode {
            case .advanced:
                logError("Advanced capture mode is not implemented; falling back to quick capture", category: "SCREENSHOT")
                fallthrough
            case .quick:
                self.performCapture(rect: rect, captureType: .area, trigger: trigger, excludeWindowIDs: overlayWindowIDs)
            }

            self.frozenDisplaySnapshots.removeAll()
            self.frozenWindowSnapshots.removeAll()
            // Cleanup window reference
            self.scheduleSelectionCleanup(postCaptureFlowEnded: shouldPostCaptureFlowEnded)
        }
    }

    func selectionWindow(_ window: SelectionWindow, didSelectWindow windowResult: WindowHitTestResult) {
        let overlayWindowIDs = window.getOverlayWindowIDs()
        let shouldPostCaptureFlowEnded = captureMode != .advanced
        let trigger = captureTrigger

        window.hide()

        if captureMode != .advanced {
            restorePreviousAppFocus()
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self = self else { return }

            if var frozenWindow = self.frozenWindowSnapshots[windowResult.windowID] {
                if !frozenWindow.borderApplied {
                    let (bordered, padding) = self.applyFrozenBorderIfNeeded(to: frozenWindow.image.image, scale: frozenWindow.scale)
                    let selectionSize = CGSize(
                        width: frozenWindow.pointSize.width + padding.left + padding.right,
                        height: frozenWindow.pointSize.height + padding.top + padding.bottom
                    )
                    frozenWindow = FrozenWindowSnapshot(
                        image: SendableCGImage(bordered),
                        padding: EdgeInsetValues(padding),
                        pointSize: selectionSize,
                        borderApplied: true,
                        scale: frozenWindow.scale,
                        appBundleID: frozenWindow.appBundleID,
                        appName: frozenWindow.appName
                    )
                    self.frozenWindowSnapshots[windowResult.windowID] = frozenWindow
                }
                let selectionRect = CGRect(origin: .zero, size: frozenWindow.pointSize)
                switch self.captureMode {
                case .advanced:
                    logError("Advanced capture mode is not implemented; falling back to quick capture", category: "SCREENSHOT")
                    fallthrough
                case .quick:
                    self.handleSuccessfulCapture(
                        cgImage: frozenWindow.image.image,
                        selectionRect: selectionRect,
                        captureType: .window,
                        trigger: trigger,
                        appBundleID: frozenWindow.appBundleID,
                        appName: frozenWindow.appName
                    )
                }
                self.frozenDisplaySnapshots.removeAll()
                self.frozenWindowSnapshots.removeAll()
                self.scheduleSelectionCleanup(postCaptureFlowEnded: shouldPostCaptureFlowEnded)
                return
            }

            switch self.captureMode {
            case .advanced:
                logError("Advanced capture mode is not implemented; falling back to quick capture", category: "SCREENSHOT")
                fallthrough
            case .quick:
                self.performWindowCapture(hitResult: windowResult, captureType: .window, trigger: trigger, excludeWindowIDs: overlayWindowIDs)
            }

            self.frozenDisplaySnapshots.removeAll()
            self.frozenWindowSnapshots.removeAll()
            self.scheduleSelectionCleanup(postCaptureFlowEnded: shouldPostCaptureFlowEnded)
        }
    }

    func selectionWindowDidCancel(_ window: SelectionWindow) {
        // Hide all selection windows
        window.hide()

        captureMode = .quick
        restorePreviousAppFocus()
        scheduleSelectionCleanup()
    }
    private func showErrorAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("error.capture_error", comment: "")
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func scheduleSelectionCleanup(postCaptureFlowEnded: Bool = true) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard let self else { return }
            self.endSelectionSession()
            self.selectionWindow = nil
            self.frozenDisplaySnapshots.removeAll()
            self.frozenWindowSnapshots.removeAll()
            if postCaptureFlowEnded {
                NotificationCenter.default.post(name: .captureFlowEnded, object: nil)
            }
        }
    }

    func captureWindowUnderMouse(trigger: CaptureTrigger = .menuBar, mode: CaptureMode = .quick) {
        captureTrigger = trigger

        let excludingWindowIDs: Set<CGWindowID> = []
        let excludingPIDs: Set<pid_t> = []

        do {
            let hit = try WindowCaptureCoordinator.shared.hitTestFrontmostWindowAtMouse(
                excludingPIDs: excludingPIDs,
                excludingWindowIDs: excludingWindowIDs,
                skipSelfWindows: true
            )
            switch mode {
            case .advanced:
                logError("Advanced capture mode is not implemented; falling back to quick capture", category: "SCREENSHOT")
                fallthrough
            case .quick:
                performWindowCapture(hitResult: hit, captureType: .window, trigger: trigger, excludeWindowIDs: [])
            }
        } catch {
            showErrorNotification(error: error)
        }
    }

    // MARK: - Selection session lifecycle

    private func beginSelectionSession() -> UUID {
        windowSnapshotTask?.cancel()
        windowSnapshotTask = nil
        let id = UUID()
        selectionSessionID = id
        return id
    }

    private func endSelectionSession() {
        windowSnapshotTask?.cancel()
        windowSnapshotTask = nil
        selectionSessionID = nil
    }

    private func isCurrentSelectionSession(_ id: UUID) -> Bool {
        selectionSessionID == id
    }

    // MARK: - Frozen screenshot helpers

    private func startSelectionFlow(overlayConfiguration: SelectionOverlayView.Configuration) {
        let sessionID = beginSelectionSession()
        Task { [weak self] in
            guard let self = self else { return }
            do {
                // Capture display snapshots BEFORE showing overlays, so the dimming mask never gets baked into the frozen background.
                let displaySnapshots = try await self.prepareFrozenDisplaySnapshotsWithScreenCaptureKit()
                guard self.isCurrentSelectionSession(sessionID) else { return }

                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    guard self.isCurrentSelectionSession(sessionID) else { return }
                    self.frozenDisplaySnapshots = displaySnapshots
                    self.frozenWindowSnapshots.removeAll()

                    // Convert SendableCGImage → CGImage for SelectionWindow (UI layer)
                    let rawSnapshots = displaySnapshots.mapValues { $0.image }
                    let window = SelectionWindow(
                        frozenScreenshots: rawSnapshots,
                        overlayConfiguration: overlayConfiguration
                    )
                    window.selectionDelegate = self
                    window.show()
                    self.selectionWindow = window
                }

                // Window snapshots are optional and can be expensive; compute them after the UI is visible.
                self.windowSnapshotTask = Task { [weak self] in
                    guard let self else { return }
                    guard self.isCurrentSelectionSession(sessionID) else { return }
                    var overlayWindowIDs = await MainActor.run { [weak self] () -> [CGWindowID] in
                        guard let self else { return [] }
                        return self.selectionWindow?.getOverlayWindowIDs() ?? []
                    }
                    // 有时窗口刚创建时 windowNumber 还没准备好，导致排除列表为空；稍等一帧再取一次，避免把遮罩本身截图进背景导致“双重遮罩”。
                    if overlayWindowIDs.isEmpty {
                        try? await Task.sleep(nanoseconds: 50_000_000) // 50 ms
                        guard self.isCurrentSelectionSession(sessionID) else { return }
                        overlayWindowIDs = await MainActor.run { [weak self] in
                            guard let self else { return [] }
                            return self.selectionWindow?.getOverlayWindowIDs() ?? []
                        }
                    }

                    do {
                        let windowSnapshots = try await self.prepareFrozenWindowSnapshotsWithScreenCaptureKit(
                            excludingWindowIDs: overlayWindowIDs
                        )
                        guard self.isCurrentSelectionSession(sessionID) else { return }
                        await MainActor.run { [weak self] in
                            guard let self else { return }
                            guard self.isCurrentSelectionSession(sessionID) else { return }
                            self.frozenWindowSnapshots = windowSnapshots
                        }
                    } catch {
                        // Best-effort: window capture fallback paths still work without frozen window snapshots.
                    }
                }
            } catch {
                guard self.isCurrentSelectionSession(sessionID) else { return }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    guard self.isCurrentSelectionSession(sessionID) else { return }
                    self.frozenDisplaySnapshots.removeAll()
                    self.frozenWindowSnapshots.removeAll()

                    let window = SelectionWindow(
                        frozenScreenshots: [:],
                        overlayConfiguration: overlayConfiguration
                    )
                    window.selectionDelegate = self
                    window.show()
                    self.selectionWindow = window

                    self.showErrorAlert(error.localizedDescription)
                    self.selectionWindow?.setOverlayAlpha(1)
                }
            }
        }
    }

    private func prepareFrozenDisplaySnapshotsWithScreenCaptureKit() async throws -> [CGDirectDisplayID: SendableCGImage] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)

        var displaySnapshots: [CGDirectDisplayID: SendableCGImage] = [:]
        for screen in NSScreen.screens {
            guard
                let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                let scDisplay = content.displays.first(where: { $0.displayID == displayID })
            else { continue }

            if let image = try? await captureDisplaySnapshot(
                screen: screen,
                scDisplay: scDisplay,
                excludedWindows: []
            ) {
                displaySnapshots[displayID] = SendableCGImage(image)
            }
        }

        return displaySnapshots
    }

    private func prepareFrozenWindowSnapshotsWithScreenCaptureKit(excludingWindowIDs: [CGWindowID]) async throws -> [CGWindowID: FrozenWindowSnapshot] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let excludeSet = Set(excludingWindowIDs)
        let visibleWindowIDsByDisplay = self.visibleWindowIDsByDisplay(excludingWindowIDs: excludeSet)
        let prioritizedWindowIDs = Set(visibleWindowIDsByDisplay.values.flatMap { $0 })

        var windowSnapshots: [CGWindowID: FrozenWindowSnapshot] = [:]
        for window in content.windows {
            let windowID = CGWindowID(window.windowID)
            if excludeSet.contains(windowID) { continue }
            if let appBundleID, window.owningApplication?.bundleIdentifier == appBundleID { continue }
            // Only freeze a limited set of frontmost visible windows per display; if the
            // prioritization failed, fall back to freezing all (old behavior).
            if !prioritizedWindowIDs.isEmpty && !prioritizedWindowIDs.contains(windowID) {
                continue
            }
            do {
                let snapshot = try await captureWindowSnapshot(window: window, applyBorder: false)
                windowSnapshots[windowID] = snapshot
            } catch {
                continue
            }
        }

        return windowSnapshots
    }

    /// Return front-to-back window IDs grouped by display, capped per display to avoid freezing every window.
    private func visibleWindowIDsByDisplay(excludingWindowIDs: Set<CGWindowID>) -> [CGDirectDisplayID: [CGWindowID]] {
        var result: [CGDirectDisplayID: [CGWindowID]] = [:]

        guard let windowInfoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return result
        }

        let normalLevel = Int(CGWindowLevelForKey(.normalWindow))
        let popupLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height

        func appKitRect(fromQuartz rect: CGRect) -> CGRect {
            let y = mainHeight - rect.origin.y - rect.height
            return CGRect(x: rect.origin.x, y: y, width: rect.width, height: rect.height)
        }

        let screens: [(CGDirectDisplayID, NSScreen)] = NSScreen.screens.compactMap { screen in
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return nil
            }
            return (displayID, screen)
        }

        func displayID(for rect: CGRect) -> CGDirectDisplayID? {
            var best: (CGDirectDisplayID, CGFloat)?
            for (displayID, screen) in screens {
                let intersection = screen.frame.intersection(rect)
                let area = intersection.width * intersection.height
                guard area > 0 else { continue }
                if let current = best {
                    if area > current.1 {
                        best = (displayID, area)
                    }
                } else {
                    best = (displayID, area)
                }
            }
            return best?.0
        }

        for info in windowInfoList {
            guard
                let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                let quartzBounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                let windowIDNumber = info[kCGWindowNumber as String] as? NSNumber
            else { continue }

            let windowID = windowIDNumber.uint32Value
            if excludingWindowIDs.contains(windowID) { continue }

            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            if layer < normalLevel || layer > popupLevel { continue }

            if let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha <= 0 {
                continue
            }
            if let onscreen = (info[kCGWindowIsOnscreen as String] as? NSNumber), onscreen.boolValue == false {
                continue
            }

            let appKitBounds = appKitRect(fromQuartz: quartzBounds)
            guard let displayID = displayID(for: appKitBounds) else { continue }

            // Respect per-display cap to avoid blocking UI when many windows exist.
            if result[displayID, default: []].count >= maxFrozenWindowSnapshotsPerDisplay {
                continue
            }

            result[displayID, default: []].append(windowID)
        }

        return result
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

        // Extract app info at capture point — SCRunningApplication is not Sendable
        let appBundleID = window.owningApplication?.bundleIdentifier
        let appName = window.owningApplication?.applicationName

        if applyBorder {
            let (bordered, padding) = applyFrozenBorderIfNeeded(to: image, scale: scaleCGFloat)
            let pointSize = CGSize(
                width: rect.width + padding.left + padding.right,
                height: rect.height + padding.top + padding.bottom
            )
            return FrozenWindowSnapshot(
                image: SendableCGImage(bordered),
                padding: EdgeInsetValues(padding),
                pointSize: pointSize,
                borderApplied: true,
                scale: scaleCGFloat,
                appBundleID: appBundleID,
                appName: appName
            )
        } else {
            let pointSize = CGSize(width: rect.width, height: rect.height)
            return FrozenWindowSnapshot(
                image: SendableCGImage(image),
                padding: .zero,
                pointSize: pointSize,
                borderApplied: false,
                scale: scaleCGFloat,
                appBundleID: appBundleID,
                appName: appName
            )
        }
    }

    private func frozenCapture(for rect: CGRect) -> CGImage? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) else { return nil }
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
        guard let snapshot = frozenDisplaySnapshots[displayID]?.image else { return nil }

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

    private func performCapture(
        rect: CGRect,
        captureType: CaptureItemCaptureType,
        trigger: CaptureTrigger,
        excludeWindowIDs: [CGWindowID] = []
    ) {
        guard rect.width > 0 && rect.height > 0 else {
            showErrorNotification(error: NSError(domain: "ScreenshotService", code: -1, userInfo: [NSLocalizedDescriptionKey: "选区无效"]))
            return
        }

        Task { [weak self] in
            guard let self = self else { return }

            do {
                let cgImage = try await self.captureWithScreenCaptureKit(rect: rect, excludeWindowIDs: excludeWindowIDs)
                await MainActor.run {
                    self.handleSuccessfulCapture(cgImage: cgImage, selectionRect: rect, captureType: captureType, trigger: trigger)
                }

            } catch {
                await MainActor.run { [weak self] in
                    self?.showErrorNotification(error: error)
                }
            }
        }
    }

    private func performWindowCapture(
        hitResult: WindowHitTestResult,
        captureType: CaptureItemCaptureType,
        trigger: CaptureTrigger,
        excludeWindowIDs: [CGWindowID]
    ) {
        _ = excludeWindowIDs // 已通过命中窗口过滤，本次捕获不需要排除其它窗口
        Task { [weak self] in
            guard let self = self else { return }

            do {
                let captureResult = try await WindowCaptureCoordinator.shared.captureWindow(using: hitResult)
                let padding = captureResult.paddingPoints
                let sizeRect = CGRect(
                    origin: .zero,
                    size: CGSize(
                        width: captureResult.windowFrame.size.width + padding.left + padding.right,
                        height: captureResult.windowFrame.size.height + padding.top + padding.bottom
                    )
                )
                await MainActor.run {
                    self.handleSuccessfulCapture(
                        cgImage: captureResult.image.image,
                        selectionRect: sizeRect,
                        captureType: captureType,
                        trigger: trigger,
                        appBundleID: captureResult.appBundleID,
                        appName: captureResult.appName
                    )
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

    // Gestion commune du succès
    private func handleSuccessfulCapture(
        cgImage: CGImage,
        selectionRect: CGRect,
        captureType: CaptureItemCaptureType,
        trigger: CaptureTrigger,
        appBundleID: String? = nil,
        appName: String? = nil
    ) {
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
            pointSize: selectionRect.size,
            allowSaving: allowSaving
        )

        let appInfo = resolvedAppInfo(appBundleID: appBundleID, appName: appName)

        guard allowSaving else {
            self.showSuccessNotification(filePath: nil)
            return
        }

        if let filePath = clipboardFilePath {
            NotificationCenter.default.post(name: .screenshotCaptured, object: nil, userInfo: ["filePath": filePath])
            settings.addToHistory(filePath)
            self.showSuccessNotification(filePath: filePath)
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let savedPath = await self.saveToDiskAsync(cgImage: cgImage, pointSize: selectionRect.size)
            if let filePath = savedPath {
                NotificationCenter.default.post(name: .screenshotCaptured, object: nil, userInfo: ["filePath": filePath])
                settings.addToHistory(filePath)
            }
            self.showSuccessNotification(filePath: savedPath)
        }
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

    private func restorePreviousAppFocus() {
        guard let app = previousApp else { return }
        if let appBundleID, app.bundleIdentifier == appBundleID { return }
        app.activate(options: [.activateAllWindows])
    }

    /// Detect the application category based on previously captured app
    private func detectFrontmostApp() -> AppCategory {
        guard let app = previousApp,
              let bundleID = app.bundleIdentifier else {
            return .unknown
        }
        return appCategoryMap[bundleID] ?? .unknown
    }

    private func resolvedAppInfo(appBundleID: String? = nil, appName: String? = nil) -> (bundleID: String?, appName: String?, pid: Int?) {
        if appBundleID != nil || appName != nil {
            let bundleID = sanitizedAppString(appBundleID) ?? sanitizedAppString(previousApp?.bundleIdentifier)
            let name = sanitizedAppString(appName) ?? sanitizedAppString(previousApp?.localizedName)
            return (bundleID, name, previousApp.map { Int($0.processIdentifier) })
        }

        return (
            sanitizedAppString(previousApp?.bundleIdentifier),
            sanitizedAppString(previousApp?.localizedName),
            previousApp.map { Int($0.processIdentifier) }
        )
    }

    private func sanitizedAppString(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// Copy image to clipboard - SIMPLE LOGIC
    /// Default: Image only (works everywhere including AI agents)
    /// Path override: Path text only (for terminals)
    @discardableResult
    private func copyToClipboard(
        image: NSImage,
        cgImage: CGImage,
        pointSize: CGSize,
        allowSaving: Bool
    ) -> String? {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let settings = AppSettings.shared

        let effectiveFormat = settings.captureClipboardFormat

        let filePath: String? = {
            switch effectiveFormat {
            case .image:
                return nil
            case .path, .markdownImage:
                guard allowSaving else { return nil }
                return saveToFileAndGetPath(cgImage: cgImage, pointSize: pointSize)
            }
        }()

        switch effectiveFormat {
        case .image:
            if let pngData = makePNGClipboardData(cgImage: cgImage, pointSize: pointSize) {
                let item = NSPasteboardItem()
                item.setData(pngData, forType: .png)

                if let tiffData = image.tiffRepresentation {
                    item.setData(tiffData, forType: .tiff)
                }

                pasteboard.writeObjects([item])
            } else {
                pasteboard.writeObjects([image])
            }
            return nil

        case .path:
            if let filePath, !filePath.isEmpty {
                pasteboard.setString(filePath, forType: .string)
                return filePath
            }
            pasteboard.writeObjects([image])
            return nil

        case .markdownImage:
            if let filePath, let markdown = makeMarkdownImageReference(filePath: filePath) {
                pasteboard.setString(markdown, forType: .string)
                return filePath
            }
            pasteboard.writeObjects([image])
            return nil
        }
    }

    private func makePNGClipboardData(cgImage: CGImage, pointSize: CGSize) -> Data? {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = pointSize
        return rep.representation(using: .png, properties: [:])
    }

    private func makeMarkdownImageReference(filePath: String) -> String? {
        let url = URL(fileURLWithPath: filePath)
        let alt = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "]", with: "")
            .replacingOccurrences(of: "[", with: "")
        let ref = url.absoluteString
        guard !ref.isEmpty else { return nil }
        return "![\(alt)](\(ref))"
    }

    /// Save to disk on a background task, then return the path on MainActor.
    private func saveToDiskAsync(
        cgImage: CGImage,
        pointSize: CGSize
    ) async -> String? {
        // Gather @MainActor settings before hopping to background
        let imageFormat = AppSettings.shared.imageFormat
        var seq = AppSettings.shared.screenshotSequence
        AppSettings.shared.ensureFolderExists()
        let folderPath = AppSettings.shared.saveFolderPath
        let sendableImage = SendableCGImage(cgImage)

        // Detached to cut @MainActor inheritance — background I/O
        let (savedPath, finalSeq) = await Task.detached(priority: .utility) {
            let savedPath = ScreenshotService.saveToFile(
                cgImage: sendableImage.image,
                pointSize: pointSize,
                imageFormat: imageFormat,
                sequence: &seq,
                folderPath: folderPath
            )
            return (savedPath, seq)
        }.value

        AppSettings.shared.screenshotSequence = finalSeq
        return savedPath
    }

    /// Pure file-save logic — no @MainActor dependencies. Called from background context.
    private nonisolated static func saveToFile(
        cgImage: CGImage,
        pointSize: CGSize,
        imageFormat: String,
        sequence: inout Int,
        folderPath: String
    ) -> String? {
        let bitmapImage = NSBitmapImageRep(cgImage: cgImage)
        bitmapImage.size = pointSize

        let fileType: NSBitmapImageRep.FileType
        let fileExtension: String

        switch imageFormat {
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

        var seq = sequence
        var filename = "Screen-\(seq).\(fileExtension)"

        let fileManager = FileManager.default
        var savePath = folderPath + filename

        while fileManager.fileExists(atPath: savePath) {
            seq += 1
            filename = "Screen-\(seq).\(fileExtension)"
            savePath = folderPath + filename
        }

        sequence = seq + 1

        do {
            try data.write(to: URL(fileURLWithPath: savePath))
            return savePath
        } catch {
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

    /// Synchronous save — called from @MainActor context (e.g. copyToClipboard).
    /// Reads settings directly, performs I/O on current thread.
    private func saveToFileAndGetPath(cgImage: CGImage, pointSize: CGSize) -> String? {
        let imageFormat = AppSettings.shared.imageFormat
        var seq = AppSettings.shared.screenshotSequence
        AppSettings.shared.ensureFolderExists()
        let folderPath = AppSettings.shared.saveFolderPath

        let result = ScreenshotService.saveToFile(
            cgImage: cgImage,
            pointSize: pointSize,
            imageFormat: imageFormat,
            sequence: &seq,
            folderPath: folderPath
        )
        AppSettings.shared.screenshotSequence = seq
        return result
    }

    private func showErrorNotification(error: Error) {
        let alert = NSAlert()
        alert.messageText = "截图错误"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "确定")
        alert.runModal()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
