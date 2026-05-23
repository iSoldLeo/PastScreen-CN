//
//  Capture.swift
//  Mio
//
//  Self-contained capture pipeline:
//  hotkey/menu → coordinator → pipeline → ScreenCaptureKit + output → event bus → UI feedback
//
//  All capture-related types co-located here. Previously split across 14 files
//  (Domain / Application / Infrastructure / Services / Views/DynamicIsland).
//
//  Single-file organization mirrors the domain's actual scope: 2 SCK capture
//  methods + 2 output methods + a thin coordinator. Protocol-implementation
//  pairs were removed because Mio has no test suite (XCTest unavailable in
//  Command Line Tools); reintroducing protocols when tests are added is a
//  localized refactor.
//
//  File order (top → bottom = dependency order; downstream depends on upstream):
//    - Sendable value types (CaptureImage / CaptureConfiguration / errors / events)
//    - Coordinate helpers (QuartzSpace)
//    - Capture request enum
//    - Event bus (success-path only)
//    - Window hit-testing service
//    - Display capture actor (SCK)
//    - File output actor (PNG sequence)
//    - Clipboard output (@MainActor)
//    - Pipeline actor (orchestration)
//    - Coordinator (@MainActor entry point + SelectionWindow lifecycle)
//    - Dynamic island UI feedback
//

import Foundation
import AppKit
import CoreGraphics
@preconcurrency import ScreenCaptureKit  // SCStreamError / SCDisplay / SCWindow not yet Sendable

// MARK: - Sendable value types

/// Single Sendable image DTO used across actor boundaries (capture pipeline,
/// file/clipboard output, window capture results).
///
/// Three independent claims justify `@unchecked Sendable`:
///   1. CGImage is an immutable Core Foundation reference type — pixel data
///      cannot be modified after creation. Apple has not yet declared CGImage
///      Sendable, but the immutability contract is documented in the Core
///      Graphics reference.
///   2. All stored properties are `let`; the struct itself is value-immutable,
///      so Sendability cannot be broken by a future mutation. **Adding a `var`
///      field to this struct is a SAFETY violation and must be reviewed.**
///   3. Cross-actor access is read-only. `CaptureImage` exposes no mutating API;
///      downstream consumers (FileOutputService, ClipboardOutputService) only
///      read the fields and pass the value by copy.
///
/// Carries `scale` (backing scale factor of the source display) and `size`
/// (point size of the image). FileOutputService stamps `NSBitmapImageRep.size`
/// with the point size so PNG metadata reports the correct on-disk dimensions;
/// ClipboardOutputService stamps the same point size on the pasteboard NSImage.
///
/// TODO: Remove `@unchecked` once Apple marks CGImage as Sendable.
nonisolated public struct CaptureImage: @unchecked Sendable {
    public let cgImage: CGImage
    public let scale: CGFloat
    public let size: CGSize

    public init(cgImage: CGImage, scale: CGFloat, size: CGSize) {
        self.cgImage = cgImage
        self.scale = scale
        self.size = size
    }
}

/// Pure-value snapshot of capture settings. Passed by value across actor
/// boundaries — no MainActor hop required.
nonisolated public struct CaptureConfiguration: Sendable {
    public let saveFolderPath: String
    public let hasValidSaveFolder: Bool
    public let playSoundOnCapture: Bool

    public init(
        saveFolderPath: String,
        hasValidSaveFolder: Bool,
        playSoundOnCapture: Bool
    ) {
        self.saveFolderPath = saveFolderPath
        self.hasValidSaveFolder = hasValidSaveFolder
        self.playSoundOnCapture = playSoundOnCapture
    }
}

/// Sendable error type for capture failures.
///
/// `underlyingDescription` is `String?` (not `Error?`) because Error is not
/// Sendable. SCStreamError and other non-Sendable errors must be converted to
/// descriptions inside their respective actors before crossing boundaries.
nonisolated public struct CaptureError: Error, LocalizedError, Sendable {
    public let message: String
    public let underlyingDescription: String?

    public init(_ message: String, underlyingDescription: String? = nil) {
        self.message = message
        self.underlyingDescription = underlyingDescription
    }

    public var errorDescription: String? { message }
}

/// Type-safe events emitted during the capture pipeline.
///
/// Failures are NOT delivered through this stream. They surface as thrown
/// errors from `CapturePipeline.execute` and are presented by
/// `CaptureCoordinator` directly — keeping the success-path event bus free
/// of error-handling forks.
nonisolated public enum CaptureEvent: Sendable {
    case savedToFile(path: String)
    case copiedToClipboard
}

/// Quartz window hit-test result DTO.
nonisolated public struct WindowHitTestResult: Sendable {
    public let windowID: CGWindowID
    /// Bounds in AppKit screen coordinates (bottom-left origin, points).
    public let bounds: CGRect
    public let ownerPID: pid_t
    public let ownerName: String?
    public let layer: Int

    public init(
        windowID: CGWindowID,
        bounds: CGRect,
        ownerPID: pid_t,
        ownerName: String?,
        layer: Int
    ) {
        self.windowID = windowID
        self.bounds = bounds
        self.ownerPID = ownerPID
        self.ownerName = ownerName
        self.layer = layer
    }
}

nonisolated public enum WindowCaptureError: LocalizedError, Sendable {
    case mouseLocationUnavailable
    case noWindowAtPoint

    public var errorDescription: String? {
        switch self {
        case .mouseLocationUnavailable: return "无法获取鼠标位置"
        case .noWindowAtPoint: return "鼠标下方未找到可截取的窗口"
        }
    }
}

// MARK: - Coordinate helpers

/// Coordinate conversion between AppKit (bottom-left origin) and Quartz
/// (top-left origin).
nonisolated public enum QuartzSpace {
    /// Height of the main display in Quartz coordinates.
    /// Quartz global coordinates use (0,0) at the top-left of the main display
    /// framebuffer. Returns 0 on headless systems; callers should validate
    /// before conversion.
    public static var mainHeight: CGFloat {
        let displayID = CGMainDisplayID()
        guard displayID != 0 else { return 0 }
        return CGDisplayBounds(displayID).height
    }

    /// Convert an AppKit-global point (bottom-left origin) to Quartz
    /// (top-left origin). Uses the main display height as the reference;
    /// assumes the point is on the main display.
    public static func quartzPoint(fromAppKitGlobal point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: mainHeight - point.y)
    }

    /// Convert a Quartz rect (top-left origin) to an AppKit screen rect
    /// (bottom-left origin). Uses the main display height as the reference;
    /// correct for windows on any display because Quartz global Y is always
    /// relative to the main display's top edge.
    public static func appKitRect(fromQuartz rect: CGRect) -> CGRect {
        let ay = mainHeight - rect.origin.y - rect.height
        return CGRect(x: rect.origin.x, y: ay, width: rect.width, height: rect.height)
    }
}

// MARK: - Capture request

nonisolated public enum CaptureRequest: Sendable {
    case area(CGRect, config: CaptureConfiguration)
    case window(windowID: CGWindowID, bounds: CGRect, config: CaptureConfiguration)
    case fullscreen(rect: CGRect, config: CaptureConfiguration)
}


// MARK: - Event bus

/// Production event bus for the capture pipeline. Thread-safe by virtue of
/// `AsyncStream.Continuation`, whose `yield` and `finish` methods are
/// documented thread-safe by Apple.
///
/// `@unchecked Sendable`: stored properties are an immutable AsyncStream and
/// its Continuation. The Continuation is the only mutable conduit; all
/// callers funnel through `yield`/`finish` which the standard library
/// guarantees safe across actors.
nonisolated public final class CaptureEventBus: @unchecked Sendable {
    private let stream: AsyncStream<CaptureEvent>
    private let continuation: AsyncStream<CaptureEvent>.Continuation

    public var events: AsyncStream<CaptureEvent> { stream }

    public init() {
        let (s, c) = AsyncStream<CaptureEvent>.makeStream()
        self.stream = s
        self.continuation = c
    }

    /// Thread-safe by contract: AsyncStream.Continuation.yield() is safe across actors.
    public func emit(_ event: CaptureEvent) {
        continuation.yield(event)
    }

    /// Thread-safe by contract: AsyncStream.Continuation.finish() is safe across actors.
    public func finish() {
        continuation.finish()
    }

    deinit {
        continuation.finish()
    }
}

// MARK: - Window hit-testing

/// Quartz window hit-test service.
///
/// `hitTestFrontmostWindowAtMouse` is `@MainActor` (NSEvent.mouseLocation
/// requires main thread). Internal hit-test work is delegated to the
/// non-isolated `hitTestFrontmostWindow`, which is safe to call synchronously
/// from `SelectionOverlayView.mouseMoved`.
public final class WindowCaptureService: Sendable {
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

    /// Use Quartz (CGWindowListCopyWindowInfo) to find the frontmost on-screen
    /// window under a point. By default, windows owned by this process are
    /// skipped so overlay UIs don't get picked.
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

            // Promote Chromium/Electron child windows to a larger same-PID parent that fully
            // contains the frontmost window for consistent selection/preview.
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
    /// `@MainActor` because `NSEvent.mouseLocation` must be accessed on the
    /// main thread.
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


// MARK: - Display capture (ScreenCaptureKit)

/// Actor for ScreenCaptureKit display/region/window capture.
public actor DisplayCaptureService {
    public init() {}

    // MARK: Display / Region capture

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

        // Derive scale factor from the NSScreen matching the target display,
        // not from the first screen that intersects the rect (which may differ).
        let scaleFactor: CGFloat = await MainActor.run {
            NSScreen.screens.first { screen in
                let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
                return displayID == targetDisplay.displayID
            }?.backingScaleFactor ?? 1.0
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
            throw CaptureError("截图失败:\(error.localizedDescription)")
        }
    }

    // MARK: Window capture

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
            throw CaptureError("窗口截图失败:\(error.localizedDescription)")
        }
    }
}

// MARK: - File output (PNG sequence)

/// Actor for disk I/O: saving captures to files. Owns the on-disk filename
/// sequence counter — it is a property of the file output pipeline, not a
/// user preference, so the state lives here rather than in AppSettings.
///
/// No `Task.detached` — actor isolation provides the background context.
public actor FileOutputService {

    /// UserDefaults key under which the next-to-write sequence number is persisted.
    nonisolated private static let sequenceDefaultsKey = "screenshotSequence"

    /// Cached sequence counter. Loaded lazily from UserDefaults on first
    /// `write` call. Always holds the *next* sequence number to try when
    /// generating a filename.
    private var currentSequence: Int?

    public init() {}

    /// Save image to disk as PNG.
    /// Writes atomically via a temporary file to avoid partial writes on crash.
    public func write(
        image: CaptureImage,
        config: CaptureConfiguration
    ) async throws -> String? {
        let cgImage = image.cgImage
        let pointSize = image.size
        let folderPath = config.saveFolderPath

        let bitmapImage = NSBitmapImageRep(cgImage: cgImage)
        bitmapImage.size = pointSize

        guard let data = bitmapImage.representation(using: .png, properties: [:]) else {
            throw CaptureError("Failed to encode image as PNG")
        }

        var seq = loadSequenceIfNeeded()
        var filename = "Screen-\(seq).png"

        let fileManager = FileManager.default
        let folderURL = URL(fileURLWithPath: folderPath, isDirectory: true)
        var saveURL = folderURL.appendingPathComponent(filename)

        while fileManager.fileExists(atPath: saveURL.path) {
            seq += 1
            filename = "Screen-\(seq).png"
            saveURL = folderURL.appendingPathComponent(filename)
        }

        // Ensure destination directory exists
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)

        // Atomic write: write to temp, then replace
        let tempURL = folderURL.appendingPathComponent(".pastscreen_\(UUID().uuidString).tmp")
        do {
            try data.write(to: tempURL)
            _ = try fileManager.replaceItemAt(saveURL, withItemAt: tempURL)
            // Persist the *next* number to try, so the following capture
            // does not have to walk all existing files again.
            persistSequence(seq + 1)
            return saveURL.path
        } catch {
            // Clean up temp file if it exists
            try? fileManager.removeItem(at: tempURL)
            throw CaptureError(
                "Failed to write screenshot to disk",
                underlyingDescription: error.localizedDescription
            )
        }
    }

    // MARK: Private

    private func loadSequenceIfNeeded() -> Int {
        if let cached = currentSequence {
            return cached
        }
        let stored = UserDefaults.standard.integer(forKey: Self.sequenceDefaultsKey)
        let seq = stored > 0 ? stored : 1
        currentSequence = seq
        return seq
    }

    private func persistSequence(_ value: Int) {
        currentSequence = value
        UserDefaults.standard.set(value, forKey: Self.sequenceDefaultsKey)
    }
}

// MARK: - Clipboard output

/// `@MainActor` service for NSPasteboard operations.
@MainActor
public final class ClipboardOutputService: Sendable {
    public init() {}

    /// Copy capture image to clipboard.
    public func copy(image: CaptureImage) async throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        if let pngData = makePNGClipboardData(from: image) {
            let item = NSPasteboardItem()
            item.setData(pngData, forType: .png)

            let nsImage = nsImage(from: image)
            if let tiffData = nsImage.tiffRepresentation {
                item.setData(tiffData, forType: .tiff)
            }

            pasteboard.writeObjects([item])
        } else {
            pasteboard.writeObjects([nsImage(from: image)])
        }
    }

    // MARK: Private helpers

    private func makePNGClipboardData(from image: CaptureImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image.cgImage)
        rep.size = image.size
        return rep.representation(using: .png, properties: [:])
    }

    private func nsImage(from image: CaptureImage) -> NSImage {
        let nsImage = NSImage(size: image.size)
        let rep = NSBitmapImageRep(cgImage: image.cgImage)
        rep.size = image.size
        nsImage.addRepresentation(rep)
        return nsImage
    }
}


// MARK: - Pipeline

/// Actor that executes the capture → output flow. All work happens off the
/// main thread.
public actor CapturePipeline {
    private let displayCapture: DisplayCaptureService
    private let fileOutput: FileOutputService
    private let clipboardOutput: ClipboardOutputService
    private let eventBus: CaptureEventBus

    public init(
        displayCapture: DisplayCaptureService,
        fileOutput: FileOutputService,
        clipboardOutput: ClipboardOutputService,
        eventBus: CaptureEventBus
    ) {
        self.displayCapture = displayCapture
        self.fileOutput = fileOutput
        self.clipboardOutput = clipboardOutput
        self.eventBus = eventBus
    }

    public func execute(request: CaptureRequest) async throws {
        let config: CaptureConfiguration = switch request {
        case .area(_, let cfg): cfg
        case .window(_, _, let cfg): cfg
        case .fullscreen(_, let cfg): cfg
        }

        try Task.checkCancellation()

        let capturedImage: CaptureImage

        switch request {
        case .area(let rect, _):
            capturedImage = try await displayCapture.captureDisplay(rect: rect, excludingWindowIDs: [])

        case .window(let windowID, _, _):
            capturedImage = try await displayCapture.captureWindow(windowID: windowID)

        case .fullscreen(let rect, _):
            capturedImage = try await displayCapture.captureDisplay(rect: rect, excludingWindowIDs: [])
        }

        try Task.checkCancellation()

        // File output (must happen before clipboard for the saved-path event).
        // The file output service owns the on-disk sequence counter internally.
        var filePath: String?
        if config.hasValidSaveFolder {
            filePath = try await fileOutput.write(image: capturedImage, config: config)
            try Task.checkCancellation()
        }

        // Clipboard output (async call automatically hops to @MainActor implementation)
        try await clipboardOutput.copy(image: capturedImage)

        // Play sound on main thread (NSSound requirement)
        if config.playSoundOnCapture {
            await MainActor.run {
                let systemSoundPath = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
                if let sound = NSSound(contentsOfFile: systemSoundPath, byReference: true) {
                    sound.play()
                } else if let fallback = NSSound(named: NSSound.Name("Glass")) {
                    fallback.play()
                }
            }
        }

        if let filePath {
            eventBus.emit(.savedToFile(path: filePath))
        }
        eventBus.emit(.copiedToClipboard)
    }
}

// MARK: - Coordinator

/// `@MainActor` coordinator that bridges UI entry points (hotkey, menu bar)
/// to the `CapturePipeline`. Manages `SelectionWindow` lifecycle and forwards
/// pipeline events to `DynamicIslandManager`.
///
/// The coordinator self-assembles the full capture stack in its initializer;
/// no separate dependency container is needed for a single-tenant app.
@MainActor
public final class CaptureCoordinator: SelectionWindowDelegate {
    private let pipeline: CapturePipeline
    private let eventBus: CaptureEventBus
    private var selectionWindow: SelectionWindow?
    private var eventTask: Task<Void, Never>?

    public init() {
        let eventBus = CaptureEventBus()
        self.eventBus = eventBus
        self.pipeline = CapturePipeline(
            displayCapture: DisplayCaptureService(),
            fileOutput: FileOutputService(),
            clipboardOutput: ClipboardOutputService(),
            eventBus: eventBus
        )
        startListeningToEvents()
    }

    // MARK: Public API

    /// Start an area-selection capture flow. Creates a `SelectionWindow` and
    /// waits for the user to drag a rect or click a window.
    public func startAreaCapture() {
        cleanupExistingWindow()

        let window = SelectionWindow(overlayConfiguration: .screenshot)
        window.selectionDelegate = self
        window.show()
        selectionWindow = window
    }

    /// Capture all screens immediately (no selection UI).
    public func startFullScreenCapture() {
        let screenFrame = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
        let config = makeCaptureConfiguration()
        let request = CaptureRequest.fullscreen(rect: screenFrame, config: config)

        Task { [weak self] in
            guard let self else { return }
            await self.executeCapture(request: request)
        }
    }

    // MARK: SelectionWindowDelegate

    func selectionWindow(_ window: SelectionWindow, didSelectRect rect: CGRect) {
        window.hide()

        let config = makeCaptureConfiguration()
        let request = CaptureRequest.area(rect, config: config)

        Task { [weak self] in
            guard let self else { return }
            await self.executeCapture(request: request)
            await MainActor.run { [weak self] in
                self?.cleanupSelectionWindow()
            }
        }
    }

    func selectionWindow(_ window: SelectionWindow, didSelectWindow windowResult: WindowHitTestResult) {
        window.hide()

        let config = makeCaptureConfiguration()
        let request = CaptureRequest.window(
            windowID: windowResult.windowID,
            bounds: windowResult.bounds,
            config: config
        )

        Task { [weak self] in
            guard let self else { return }
            await self.executeCapture(request: request)
            await MainActor.run { [weak self] in
                self?.cleanupSelectionWindow()
            }
        }
    }

    func selectionWindowDidCancel(_ window: SelectionWindow) {
        window.hide()
        cleanupSelectionWindow()
    }

    // MARK: Private

    private func executeCapture(request: CaptureRequest) async {
        do {
            try await pipeline.execute(request: request)
        } catch {
            showCaptureError(error)
        }
    }

    private func makeCaptureConfiguration() -> CaptureConfiguration {
        let capture = AppSettings.shared.capture
        return CaptureConfiguration(
            saveFolderPath: capture.saveFolderPath,
            hasValidSaveFolder: capture.hasValidSaveFolder,
            playSoundOnCapture: capture.playSoundOnCapture
        )
    }

    private func cleanupExistingWindow() {
        selectionWindow?.hide()
        selectionWindow = nil
    }

    private func cleanupSelectionWindow() {
        selectionWindow = nil
    }

    private func showCaptureError(_ error: Error) {
        DynamicIslandManager.shared.show(
            message: error.localizedDescription,
            duration: 3.0,
            style: .failure
        )
    }

    // MARK: Event bus listener

    private func startListeningToEvents() {
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.eventBus.events {
                self.handleEvent(event)
            }
        }
    }

    private func handleEvent(_ event: CaptureEvent) {
        switch event {
        case .savedToFile:
            DynamicIslandManager.shared.show(message: "已保存", duration: 3.0, style: .success)
        case .copiedToClipboard:
            DynamicIslandManager.shared.show(message: "已复制", duration: 1.5, style: .success)
        }
    }

    deinit {
        eventTask?.cancel()
    }
}

// MARK: - Dynamic island UI feedback

/// Manager for temporary "✓ Saved" indicator in the menu bar.
@MainActor
final class DynamicIslandManager {
    static let shared = DynamicIslandManager()
    private var pillStatusItem: NSStatusItem?
    private var dismissTask: Task<Void, Never>?

    enum Style: Sendable {
        case success
        case failure
    }

    func show(message: String, duration: TimeInterval = 3.0, style: Style = .success) {
        dismiss()

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }

        pillStatusItem = statusItem
        switch style {
        case .success:
            button.title = "✓ \(message)"
            button.contentTintColor = .systemGreen
        case .failure:
            button.title = "✕ \(message)"
            button.contentTintColor = .systemRed
        }
        button.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        button.isBordered = true
        button.bezelStyle = .rounded
        button.focusRingType = .none

        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil

        guard let item = pillStatusItem else { return }

        // Clear reference BEFORE starting animation to prevent race conditions
        pillStatusItem = nil

        // Remove immediately without animation to prevent statusItem accumulation
        NSStatusBar.system.removeStatusItem(item)
    }
}
