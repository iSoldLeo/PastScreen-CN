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
    public let saveToFile: Bool

    public init(
        saveFolderPath: String,
        hasValidSaveFolder: Bool,
        playSoundOnCapture: Bool,
        saveToFile: Bool
    ) {
        self.saveFolderPath = saveFolderPath
        self.hasValidSaveFolder = hasValidSaveFolder
        self.playSoundOnCapture = playSoundOnCapture
        self.saveToFile = saveToFile
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
/// errors from `CapturePipeline.finishOutput` and are presented by
/// `CaptureCoordinator` directly — keeping the success-path event bus free
/// of error-handling forks.
nonisolated public enum CaptureEvent: Sendable {
    case savedToFile(path: String)
    case copiedToClipboard
}

/// 按键瞬间冻结的全部资产：屏幕级冻结底图 + 候选窗口圆角透明图。
///
/// PRODUCT v5 §2.3：`screens` 是 hover/拖框 UI 的稳定底图（必有），
/// `windows` 是窗口点选路径的高保真输出来源（按 z-order 前 N 个，
/// 受 150ms 时间预算约束，可能少于实际可见窗口数）。
nonisolated public struct FrozenAssets: Sendable {
    public let screens: [CGDirectDisplayID: CaptureImage]
    public let windows: [CGWindowID: CaptureImage]

    public init(
        screens: [CGDirectDisplayID: CaptureImage],
        windows: [CGWindowID: CaptureImage]
    ) {
        self.screens = screens
        self.windows = windows
    }
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

// MARK: - Window visibility helpers

/// 矩形减法 + 可见性判定。
///
/// SCShareableContent.windows 默认按 z-order 前→后给窗口；逐个累加 occluder
/// 后用矩形减法判断当前窗口是否仍剩余可见区域。与 probe 一致，便于回归对照。
nonisolated public enum WindowVisibility {
    /// rect 减去单个 occluder 后的不重叠子矩形列表。完全被覆盖时返回空数组。
    public static func subtract(_ rect: CGRect, by other: CGRect) -> [CGRect] {
        let inter = rect.intersection(other)
        if inter.isNull || inter.isEmpty { return [rect] }
        if inter == rect { return [] }
        var pieces: [CGRect] = []
        // top
        if inter.minY > rect.minY {
            pieces.append(CGRect(x: rect.minX, y: rect.minY,
                                 width: rect.width,
                                 height: inter.minY - rect.minY))
        }
        // bottom
        if inter.maxY < rect.maxY {
            pieces.append(CGRect(x: rect.minX, y: inter.maxY,
                                 width: rect.width,
                                 height: rect.maxY - inter.maxY))
        }
        // left
        if inter.minX > rect.minX {
            pieces.append(CGRect(x: rect.minX, y: inter.minY,
                                 width: inter.minX - rect.minX,
                                 height: inter.height))
        }
        // right
        if inter.maxX < rect.maxX {
            pieces.append(CGRect(x: inter.maxX, y: inter.minY,
                                 width: rect.maxX - inter.maxX,
                                 height: inter.height))
        }
        return pieces
    }

    /// rect 减去多个 occluder 后是否仍剩余可见区域。
    public static func hasVisibleArea(rect: CGRect, occluders: [CGRect]) -> Bool {
        var pieces: [CGRect] = [rect]
        for occ in occluders {
            var next: [CGRect] = []
            for p in pieces {
                next.append(contentsOf: subtract(p, by: occ))
            }
            pieces = next
            if pieces.isEmpty { return false }
        }
        return !pieces.isEmpty
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

    /// Capture the full content of a single display by displayID.
    ///
    /// Used as the screen-level freezing primitive for PRODUCT.md §2: at the
    /// trigger instant the caller takes one snapshot per screen, then drives
    /// path A / path B UI off the frozen images. Producing one CaptureImage
    /// per screen.
    ///
    /// - Precondition: caller guarantees that at the moment of this call Mio
    ///   itself has no visible windows. Overlay / chooser windows must be
    ///   created **after** `CapturePipeline.captureFrozenScreens()` returns,
    ///   otherwise Mio's own UI would be baked into the frozen background.
    /// - If no SCDisplay matches `displayID`, this method throws — it does
    ///   **not** silently fall back to another display (preserving product
    ///   contract: the user expects the exact screen they targeted).
    public func captureFullDisplay(displayID: CGDirectDisplayID) async throws -> CaptureImage {
        let content = try await SCShareableContent.current

        // NSScreen is not Sendable; flatten on MainActor into Sendable primitives.
        let screenInfo: (frame: CGRect, scaleFactor: CGFloat)? = await MainActor.run {
            NSScreen.screens.first { ns in
                let id = ns.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
                return id == displayID
            }.map { (frame: $0.frame, scaleFactor: $0.backingScaleFactor) }
        }
        guard let screenInfo else {
            throw CaptureError("No NSScreen matching displayID \(displayID)")
        }

        guard let targetDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError("No SCDisplay matching displayID \(displayID)")
        }

        let filter = SCContentFilter(display: targetDisplay, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.width = Int(screenInfo.frame.width * screenInfo.scaleFactor)
        config.height = Int(screenInfo.frame.height * screenInfo.scaleFactor)
        config.captureResolution = .best
        config.showsCursor = false
        config.scalesToFit = false
        // sourceRect intentionally left unset — capture the full display.

        do {
            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            return CaptureImage(
                cgImage: cgImage,
                scale: screenInfo.scaleFactor,
                size: screenInfo.frame.size
            )
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
            throw CaptureError("全屏截图失败:\(error.localizedDescription)")
        }
    }

    /// 单窗口截图（圆角透明）。
    ///
    /// PRODUCT v5 §2.3 例外：用 `SCContentFilter(desktopIndependentWindow:)` +
    /// `shouldBeOpaque = false` 让系统按窗口真实形状（含圆角 + 阴影 mask）输出
    /// 带 alpha 的 CGImage——圆角外为透明，与系统截屏（Cmd+Shift+4+Space）行为
    /// 一致。
    ///
    /// 使用 SCWindow 引用而非 windowID，是因为 SCWindow 实例携带了 SCK 已经做
    /// 过的窗口校验信息（owningApplication / frame / windowLayer），重新按 ID
    /// 查询会增加一次 SCShareableContent 调用。
    ///
    /// - Returns: CaptureImage，size 用 SCWindow.frame（point 坐标），
    ///   scale 取 NSScreen.main.backingScaleFactor 兜底（窗口跨屏时无完美值）。
    public func captureWindow(_ window: SCWindow) async throws -> CaptureImage {
        let backingScale: CGFloat = await MainActor.run {
            NSScreen.main?.backingScaleFactor ?? 2.0
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)

        let config = SCStreamConfiguration()
        config.width = max(2, Int(window.frame.width * backingScale))
        config.height = max(2, Int(window.frame.height * backingScale))
        config.captureResolution = .best
        config.showsCursor = false
        config.scalesToFit = true
        // 圆角透明的关键：要求带 alpha 的输出，且背景透明。
        config.pixelFormat = kCVPixelFormatType_32BGRA   // 显式 BGRA 保 alpha 通道
        config.backgroundColor = .clear
        if #available(macOS 14.0, *) {
            config.ignoreShadowsSingleWindow = false
        }

        let cgImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
        return CaptureImage(
            cgImage: cgImage,
            scale: backingScale,
            size: window.frame.size
        )
    }

    /// 启动预热：派一次 2×2 像素的 dummy 抓图，把 ScreenCaptureKit XPC 链路、
    /// IOSurface 资源池、权限校验缓存全部初始化到位，消除首次按键的进程级
    /// 冷启动延迟（实测裸冷启动 ~300ms，预热后稳态 ~50-150ms）。
    ///
    /// 失败静默忽略——预热失败仅意味着首次按键仍走冷路径，不应阻塞应用启动。
    public func prewarm() async {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            return
        }
        guard let display = content.displays.first else { return }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = 2
        config.height = 2
        config.showsCursor = false
        config.scalesToFit = true

        _ = try? await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
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
    nonisolated private static let sequenceDefaultsKey = SettingsKeys.screenshotSequence

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

    /// Capture every active screen concurrently, returning one CaptureImage
    /// per displayID.
    ///
    /// Implements the freezing instant of PRODUCT.md §2: the caller takes the
    /// snapshot first, then opens overlay / chooser UI on top of the frozen
    /// images. Performance contract:
    ///
    /// - Soft target: ≤ 200ms total wall time (PRODUCT.md §5).
    /// - Hard constraint: Mio process CPU peak ≤ 60% (PRODUCT.md §5). The
    ///   application enforces an explicit batch concurrency cap of 3 — SCK's
    ///   internal scheduling is opaque and cannot be relied on. Screens beyond
    ///   the third are queued into successive batches that run serially.
    /// - Failure semantics: any single-display failure throws and aborts the
    ///   whole capture; no partial dictionary is returned.
    public func captureFrozenScreens() async throws -> [CGDirectDisplayID: CaptureImage] {
        // 1. Flatten NSScreen into Sendable triples on MainActor.
        let screens: [(displayID: CGDirectDisplayID, frame: CGRect, scaleFactor: CGFloat)] =
            await MainActor.run {
                NSScreen.screens.compactMap { ns in
                    guard let id = ns.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                        return nil
                    }
                    return (displayID: id, frame: ns.frame, scaleFactor: ns.backingScaleFactor)
                }
            }
        guard !screens.isEmpty else {
            throw CaptureError("No screens detected")
        }

        // 2. Application-enforced concurrency cap. Each batch fans out via
        //    TaskGroup; batches run serially so we never have > batchSize
        //    SCStreamConfiguration captures in flight.
        let batchSize = 3
        var result: [CGDirectDisplayID: CaptureImage] = [:]
        for batchStart in stride(from: 0, to: screens.count, by: batchSize) {
            let batch = Array(screens[batchStart..<min(batchStart + batchSize, screens.count)])
            try await withThrowingTaskGroup(of: (CGDirectDisplayID, CaptureImage).self) { group in
                for entry in batch {
                    group.addTask {
                        let img = try await self.displayCapture.captureFullDisplay(displayID: entry.displayID)
                        return (entry.displayID, img)
                    }
                }
                for try await (id, img) in group {
                    result[id] = img
                }
            }
        }
        return result
    }

    /// PRODUCT v5 §2.3：按键瞬间并发抓取屏幕级冻结 + 候选窗口 burst（圆角透明）。
    ///
    /// 双路径并行：
    /// - 屏幕级冻结：与 `captureFrozenScreens()` 同语义，全屏 batchSize=3，
    ///   失败语义严（任一屏失败整批失败）。
    /// - 窗口级 burst：z-order 前→后的可见窗口，并发抓取前 8 个（不足则有几个
    ///   抓几个）。失败语义宽（单窗口失败丢弃，不阻断整体）。
    ///
    /// 8 个窗口实测线性 ~12-15ms/窗口，并发 wall-clock ≈ 最慢窗口 ~150ms，
    /// 与 PRODUCT.md §5.1 的 150ms 时间预算贴合。
    ///
    /// 注：曾尝试顶层只拉一次 SCShareableContent 注入两路，但 SCShareableContent
    /// 非 Sendable，跨 async let 边界传递触发 strict-concurrency 报错。当前
    /// 实现接受两条路径各自拉 content（XPC 30-50ms × 2，并行不阻塞），未来
    /// SCShareableContent 标 Sendable 后可优化。
    public func captureFrozenAssets() async throws -> FrozenAssets {
        async let screensTask: [CGDirectDisplayID: CaptureImage] = captureFrozenScreens()
        async let windowsTask: [CGWindowID: CaptureImage] = captureCandidateWindows(batchSize: 8)

        let screens = try await screensTask
        let windows = await windowsTask  // 不抛错，单窗口失败已在内部丢弃
        return FrozenAssets(screens: screens, windows: windows)
    }

    /// 窗口 burst：并发抓取 z-order 前→后的前 N 个可见窗口。
    ///
    /// 始终从 z-order 前→后取窗口（SCK 默认顺序）。可见性判定基于 z-order 累
    /// 加遮挡：被前面窗口完全覆盖的窗口直接跳过。
    ///
    /// 单窗口失败不抛错，仅在结果字典里缺失对应 windowID。
    private func captureCandidateWindows(batchSize: Int) async -> [CGWindowID: CaptureImage] {
        guard let visibleWindows = await loadVisibleWindowsOrderedByZ() else {
            return [:]
        }
        guard !visibleWindows.isEmpty else { return [:] }

        let batch = Array(visibleWindows.prefix(batchSize))
        let results = await burstCaptureWindows(batch)

        var dict: [CGWindowID: CaptureImage] = [:]
        for (id, img) in results {
            dict[id] = img
        }
        return dict
    }

    /// 并发抓取一组窗口，失败的窗口静默丢弃，返回成功结果。
    private func burstCaptureWindows(
        _ windows: [SCWindow]
    ) async -> [(CGWindowID, CaptureImage)] {
        await withTaskGroup(of: (CGWindowID, CaptureImage)?.self) { group in
            for window in windows {
                let id = window.windowID
                group.addTask {
                    guard let img = try? await self.displayCapture.captureWindow(window) else {
                        return nil
                    }
                    return (id, img)
                }
            }
            var collected: [(CGWindowID, CaptureImage)] = []
            for await item in group {
                if let item { collected.append(item) }
            }
            return collected
        }
    }

    /// 枚举当前所有屏上**可见**（至少有一个像素未被前面窗口覆盖）的窗口，
    /// 按 z-order 前→后返回。
    ///
    /// 实现思路与 `scripts/sck_burst_probe/main.swift` 一致：SCShareableContent
    /// 默认按 z-order front→back 给窗口；逐个累加 occluder rect 列表，对当前窗口
    /// 做 rect 减法判断是否仍有可见区域。
    private func loadVisibleWindowsOrderedByZ() async -> [SCWindow]? {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            return nil
        }

        let selfPID = ProcessInfo.processInfo.processIdentifier
        let bundleID = Bundle.main.bundleIdentifier

        // 与 probe 对齐的过滤规则：跳过自己、过小、非 normal layer。
        let candidates = content.windows.filter { w in
            if let app = w.owningApplication, Int32(app.processID) == selfPID { return false }
            if let app = w.owningApplication, app.bundleIdentifier == bundleID { return false }
            if w.frame.width * w.frame.height < 40_000 { return false }
            if w.windowLayer != 0 { return false }
            return true
        }

        // 可见性过滤：z-order 前→后逐个累加 occluder。
        var occluders: [CGRect] = []
        var visible: [SCWindow] = []
        for w in candidates {
            if WindowVisibility.hasVisibleArea(rect: w.frame, occluders: occluders) {
                visible.append(w)
            }
            occluders.append(w.frame)
        }
        return visible
    }

    /// Crop a sub-rect out of a frozen full-screen image.
    ///
    /// - `frozen` is the full-screen CaptureImage produced by
    ///   `captureFullDisplay(displayID:)`; its `size` equals the AppKit screen
    ///   frame in points and its `scale` equals the screen's backingScaleFactor.
    /// - `screenFrame` is the AppKit (bottom-left origin) frame of that screen
    ///   in the global coordinate space.
    /// - `rect` is the AppKit (bottom-left origin) rect to extract, in the
    ///   same global coordinate space; it is expected to lie inside
    ///   `screenFrame`. If it falls partially or fully outside, the method
    ///   intersects with the screen bounds and either returns the intersected
    ///   slice or throws if the intersection is empty.
    public func cropFrozenImage(
        from frozen: CaptureImage,
        screenFrame: CGRect,
        rect: CGRect
    ) async throws -> CaptureImage {
        guard rect.width > 0, rect.height > 0 else {
            throw CaptureError("Invalid crop rect: \(rect)")
        }

        let scale = frozen.scale

        // AppKit (bottom-left origin) → screen-local point coordinates.
        let offsetX = rect.origin.x - screenFrame.origin.x
        let offsetY = rect.origin.y - screenFrame.origin.y
        // Convert screen-local AppKit point to CGImage (top-left origin) point.
        let flippedY = screenFrame.height - offsetY - rect.height

        // Convert points → pixels using the screen's scale factor.
        let pixelRect = CGRect(
            x: offsetX * scale,
            y: flippedY * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )

        // Intersect with the cgImage pixel bounds as a safety net for cases
        // where rect drifted slightly outside the screen due to upstream
        // coordinate rounding.
        let imageBounds = CGRect(
            x: 0,
            y: 0,
            width: frozen.cgImage.width,
            height: frozen.cgImage.height
        )
        let clippedPixelRect = pixelRect.intersection(imageBounds)
        guard !clippedPixelRect.isNull,
              clippedPixelRect.width > 0,
              clippedPixelRect.height > 0
        else {
            throw CaptureError("Selection is completely outside screen bounds")
        }

        guard let cropped = frozen.cgImage.cropping(to: clippedPixelRect) else {
            throw CaptureError("CGImage cropping failed")
        }

        // Map the (possibly clipped) pixel rect back into points for the
        // CaptureImage size metadata.
        let pointSize = CGSize(
            width: clippedPixelRect.width / scale,
            height: clippedPixelRect.height / scale
        )
        return CaptureImage(cgImage: cropped, scale: scale, size: pointSize)
    }

    /// Output tail: file write (when enabled) → clipboard → optional sound →
    /// success events. Shared by every capture entry point — area / window /
    /// fullscreen all funnel into this single output stage.
    ///
    /// - Parameter playSound: 是否在 finishOutput 内播音效。默认 true（路径
    ///   A/B 直出场景：finishOutput 是采集瞬间）。路径 D（编辑器）传 false：
    ///   音效已经在采集瞬间（SelectionWindow 选定时）由 coordinator 播过；
    ///   编辑完点完成是「保存」语义，不该再响。
    public func finishOutput(
        image: CaptureImage,
        config: CaptureConfiguration,
        playSound: Bool = true
    ) async throws {
        // File output (must happen before clipboard for the saved-path event).
        // The file output service owns the on-disk sequence counter internally.
        // Skipped entirely when the user toggles `saveToFile` off — clipboard
        // remains the only sink in that case.
        var filePath: String?
        if config.saveToFile && config.hasValidSaveFolder {
            filePath = try await fileOutput.write(image: image, config: config)
            try Task.checkCancellation()
        }

        // Clipboard output (async call automatically hops to @MainActor implementation)
        try await clipboardOutput.copy(image: image)

        // Play screenshot sound. The player retains its NSSound reference
        // so playback isn't truncated when this Task returns.
        if playSound && config.playSoundOnCapture {
            await MainActor.run {
                CaptureSoundPlayer.shared.play()
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
public final class CaptureCoordinator: SelectionWindowDelegate, ScreenChooserWindowDelegate {
    private let pipeline: CapturePipeline
    private let eventBus: CaptureEventBus
    private var selectionWindow: SelectionWindow?
    private var screenChooserWindow: ScreenChooserWindow?
    private var frozenScreens: [CGDirectDisplayID: CaptureImage]?
    private var frozenWindows: [CGWindowID: CaptureImage] = [:]
    private var screenFrames: [CGDirectDisplayID: CGRect]?
    private var isStartingFlow: Bool = false
    /// Monotonic counter incremented at every flow start. Async output Tasks
    /// (`handleSelectedRect`'s crop+output Task) capture the value at spawn
    /// time and only call `cleanupFlow()` on completion if the generation is
    /// still current. This prevents a stale Task from clobbering the state
    /// of a flow that the user has cancelled and restarted in the meantime.
    private var flowGeneration: UInt64 = 0
    /// Distinguishes routing of a SelectionWindow result.
    /// `.directOutput` → finishOutput (paths A & current behaviour)
    /// `.intoEditor`   → open editor window (path D, advanced window capture)
    private var areaFlowKind: AreaFlowKind = .directOutput
    private var eventTask: Task<Void, Never>?

    /// Per-flow routing decision. Set when an entry method is called;
    /// read by handleSelectedRect / didSelectWindow to decide whether
    /// the cropped image is sent to finishOutput or to the editor.
    private enum AreaFlowKind {
        case directOutput
        case intoEditor
    }

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

    /// Start an area-selection capture flow. PRODUCT.md §2 product essence:
    /// at the trigger instant freeze every screen, then let the user pick a
    /// region (drag rect or click a window) from the frozen images.
    ///
    /// Re-entry is blocked: pressing the hotkey again while a capture is
    /// already starting (i.e. while `captureFrozenScreens()` is in flight)
    /// is a no-op, otherwise two concurrent freeze flows would compete for
    /// SCK resources and double the CPU spike (violating PRODUCT.md §5).
    public func startAreaCapture() {
        beginAreaCapture(kind: .directOutput)
    }

    /// Path D · 高级窗口截图 — 与 startAreaCapture 完全相同的冻结 + 覆盖层 +
    /// 区域提取流程，区别仅在区域确定后路由到编辑器窗口而非 finishOutput。
    public func startAdvancedAreaCapture() {
        beginAreaCapture(kind: .intoEditor)
    }

    private func beginAreaCapture(kind: AreaFlowKind) {
        guard !isStartingFlow else { return }
        // Hide any stale window then clear leftover state, *before* arming
        // the new flow generation. Otherwise the cleanup call would reset
        // isStartingFlow back to false right after we set it.
        cleanupExistingWindows()
        isStartingFlow = true
        flowGeneration &+= 1
        areaFlowKind = kind
        let myGeneration = flowGeneration

        Task { [weak self] in
            // Task inherits @MainActor isolation from CaptureCoordinator
            // (SE-0466 default-isolation MainActor). NSScreen.screens access
            // and self.frozenScreens writes below are MainActor-safe.
            guard let self else { return }
            do {
                let assets = try await pipeline.captureFrozenAssets()
                // If the user has already cancelled (or started a new flow)
                // while captureFrozenAssets was in flight, drop the result.
                guard self.flowGeneration == myGeneration else { return }
                let frames = NSScreen.screens.reduce(into: [CGDirectDisplayID: CGRect]()) {
                    if let id = $1.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                        $0[id] = $1.frame
                    }
                }
                self.frozenScreens = assets.screens
                self.frozenWindows = assets.windows
                self.screenFrames = frames

                let window = SelectionWindow(
                    frozenScreens: assets.screens,
                    overlayConfiguration: .screenshot
                )
                window.selectionDelegate = self
                window.show()
                self.selectionWindow = window
            } catch {
                guard self.flowGeneration == myGeneration else { return }
                self.showCaptureError(error)
                self.cleanupFlow()
            }
        }
    }

    /// Capture all screens. PRODUCT.md §2 product essence + 02-user-paths §3:
    /// freeze every screen at trigger time, then output. Single-screen path
    /// outputs the frozen image directly (no UI). Multi-screen path opens
    /// `ScreenChooserWindow` for the user to pick a screen.
    ///
    /// Uses the same isStartingFlow + flowGeneration discipline as path A
    /// (PRODUCT.md §5 CPU ≤ 60% hard limit; N9 generation isolation against
    /// stale-Task clobber).
    public func startFullScreenCapture() {
        guard !isStartingFlow else { return }
        cleanupExistingWindows()
        isStartingFlow = true
        flowGeneration &+= 1
        // 路径 B 全屏截图不走 SelectionWindow，因此 areaFlowKind 在此 flow
        // 中不会被读取——无需赋值。
        let myGeneration = flowGeneration

        Task { [weak self] in
            guard let self else { return }
            do {
                let frozen = try await pipeline.captureFrozenScreens()
                guard self.flowGeneration == myGeneration else { return }

                // Single-screen branch: output directly with no UI. Use
                // frozen.count as the single source of truth (avoids race
                // with NSScreen.screens between the two reads).
                if frozen.count == 1, let onlyImage = frozen.values.first {
                    let config = makeCaptureConfiguration()
                    do {
                        try await pipeline.finishOutput(image: onlyImage, config: config)
                    } catch {
                        if self.flowGeneration == myGeneration {
                            self.showCaptureError(error)
                        }
                    }
                    if self.flowGeneration == myGeneration {
                        self.cleanupFlow()
                    }
                    return
                }

                // Multi-screen branch: present ScreenChooserWindow.
                let frames = NSScreen.screens.reduce(into: [CGDirectDisplayID: CGRect]()) {
                    if let id = $1.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                        $0[id] = $1.frame
                    }
                }
                self.frozenScreens = frozen
                self.screenFrames = frames

                let chooser = ScreenChooserWindow(
                    frozenScreens: frozen,
                    screenFrames: frames
                )
                guard chooser.hasPanels else {
                    // Defensive: every screen failed the per-panel consistency
                    // check (frozen / frames / displayID lookup). Showing the
                    // chooser would present no UI and lock the flow.
                    self.showCaptureError(CaptureError("Screen chooser produced no panels"))
                    self.cleanupFlow()
                    return
                }
                chooser.chooserDelegate = self
                chooser.show()
                self.screenChooserWindow = chooser
            } catch {
                guard self.flowGeneration == myGeneration else { return }
                self.showCaptureError(error)
                self.cleanupFlow()
            }
        }
    }

    // MARK: SelectionWindowDelegate

    func selectionWindow(_ window: SelectionWindow, didSelectRect rect: CGRect) {
        handleSelectedRect(rect)
    }

    func selectionWindow(_ window: SelectionWindow, didSelectWindow windowResult: WindowHitTestResult) {
        handleSelectedWindow(windowResult)
    }

    func selectionWindowDidCancel(_ window: SelectionWindow) {
        window.hide()
        cleanupFlow()
    }

    // MARK: ScreenChooserWindowDelegate

    func screenChooser(_ window: ScreenChooserWindow, didSelectScreen displayID: CGDirectDisplayID) {
        window.hide()

        // Pick out the per-screen frozen image *before* spawning the Task,
        // so cancellation that clears self.frozenScreens cannot race the
        // in-flight finishOutput.
        guard let frozen = frozenScreens?[displayID] else {
            cleanupFlow()
            return
        }

        let config = makeCaptureConfiguration()
        // Re-capture the generation here: the one captured inside
        // startFullScreenCapture's Task has already escaped; this delegate
        // call is a fresh main-thread invocation tied to the current flow.
        let myGeneration = flowGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                try await pipeline.finishOutput(image: frozen, config: config)
            } catch {
                if self.flowGeneration == myGeneration {
                    self.showCaptureError(error)
                }
            }
            if self.flowGeneration == myGeneration {
                self.cleanupFlow()
            }
        }
    }

    func screenChooserDidCancel(_ window: ScreenChooserWindow) {
        window.hide()
        cleanupFlow()
    }

    // MARK: Private

    /// Shared synchronous entry for both `didSelectRect` and `didSelectWindow`.
    /// Reads frozen state into local values **before** spawning the Task so
    /// concurrent cancellation (`cleanupFlow` clearing `frozenScreens`) cannot
    /// race the in-flight crop. The Task captures `flowGeneration` at spawn
    /// time and only calls `cleanupFlow` if the generation is still current
    /// — preventing a stale Task from clobbering a flow the user has
    /// cancelled and restarted in the meantime.
    private func handleSelectedRect(_ rect: CGRect) {
        selectionWindow?.hide()

        guard let frozen = frozenScreens, let frames = screenFrames else {
            cleanupFlow()
            return
        }

        // Anchor the rect to the screen containing its center point
        // (PRODUCT.md §10: cross-screen windows are normalized by center).
        let center = CGPoint(x: rect.midX, y: rect.midY)
        guard let match = frames.first(where: { $0.value.contains(center) }),
              let frozenImage = frozen[match.key]
        else {
            showCaptureError(CaptureError("Selection outside any screen"))
            cleanupFlow()
            return
        }
        let screenFrame = match.value
        let displayID = match.key

        let config = makeCaptureConfiguration()
        let myGeneration = flowGeneration
        let kind = areaFlowKind
        Task { [weak self] in
            // Task inherits @MainActor; pipeline calls hop into the actor.
            guard let self else { return }
            do {
                let cropped = try await pipeline.cropFrozenImage(
                    from: frozenImage,
                    screenFrame: screenFrame,
                    rect: rect
                )
                switch kind {
                case .directOutput:
                    try await pipeline.finishOutput(image: cropped, config: config)
                case .intoEditor:
                    // 路径 D：跳过 finishOutput，把裁好的图交给编辑器窗口。
                    // 编辑器窗口生命周期独立于本 flow；当前 flow 在窗口
                    // 打开后即可清理。
                    if self.flowGeneration == myGeneration {
                        // 截图发生那一刻播音效（与路径 A/B 行为一致），
                        // 不等用户在编辑器里点完成。MainActor.run 因为
                        // CaptureSoundPlayer 是 @MainActor。
                        if config.playSoundOnCapture {
                            await MainActor.run {
                                CaptureSoundPlayer.shared.play()
                            }
                        }
                        EditorWindowRegistry.shared.open(
                            image: cropped,
                            displayID: displayID,
                            config: config,
                            pipeline: self.pipeline
                        )
                    }
                }
            } catch {
                if self.flowGeneration == myGeneration {
                    self.showCaptureError(error)
                }
            }
            // Only clean up if we still own the active flow. If the user
            // pressed ESC or restarted, a new generation has been armed and
            // owns the state — don't clobber it.
            if self.flowGeneration == myGeneration {
                self.cleanupFlow()
            }
        }
    }

    /// 窗口点选处理（PRODUCT v5 §2.3）：优先用按键瞬间 burst 抓的圆角透明窗口图。
    /// 命中时直接走该图；未命中（窗口在 z-order 较深或 burst 超时未抓到）时
    /// fallback 到 handleSelectedRect 的全屏矩形裁剪路径，保留矩形截图能力
    /// （仅圆角外为壁纸而非透明）。
    private func handleSelectedWindow(_ result: WindowHitTestResult) {
        guard let windowImage = frozenWindows[result.windowID] else {
            // Fallback：未抓到该窗口的 burst 图，用全屏矩形裁剪保留可用性。
            handleSelectedRect(result.bounds)
            return
        }
        selectionWindow?.hide()

        // 按窗口 bounds 中心点匹配窗口所在屏（与 handleSelectedRect 一致）。
        let center = CGPoint(x: result.bounds.midX, y: result.bounds.midY)
        let matchedDisplayID: CGDirectDisplayID
        if let frames = screenFrames,
           let match = frames.first(where: { $0.value.contains(center) }) {
            matchedDisplayID = match.key
        } else {
            // 极端情况兜底：拿主显示器的 displayID 给编辑器窗口算尺寸。
            matchedDisplayID = CGMainDisplayID()
        }

        let config = makeCaptureConfiguration()
        let myGeneration = flowGeneration
        let kind = areaFlowKind
        Task { [weak self] in
            guard let self else { return }
            do {
                switch kind {
                case .directOutput:
                    try await pipeline.finishOutput(image: windowImage, config: config)
                case .intoEditor:
                    if self.flowGeneration == myGeneration {
                        // 截图发生那一刻播音效（与路径 A/B 行为一致）。
                        if config.playSoundOnCapture {
                            await MainActor.run {
                                CaptureSoundPlayer.shared.play()
                            }
                        }
                        EditorWindowRegistry.shared.open(
                            image: windowImage,
                            displayID: matchedDisplayID,
                            config: config,
                            pipeline: self.pipeline
                        )
                    }
                }
            } catch {
                if self.flowGeneration == myGeneration {
                    self.showCaptureError(error)
                }
            }
            if self.flowGeneration == myGeneration {
                self.cleanupFlow()
            }
        }
    }

    private func makeCaptureConfiguration() -> CaptureConfiguration {
        let capture = AppSettings.shared.capture
        return CaptureConfiguration(
            saveFolderPath: capture.saveFolderPath,
            hasValidSaveFolder: capture.hasValidSaveFolder,
            playSoundOnCapture: capture.playSoundOnCapture,
            saveToFile: capture.saveToFile
        )
    }

    private func cleanupExistingWindows() {
        selectionWindow?.hide()
        screenChooserWindow?.hide()
        cleanupFlow()
    }

    private func cleanupFlow() {
        selectionWindow = nil
        screenChooserWindow = nil
        frozenScreens = nil
        frozenWindows = [:]
        screenFrames = nil
        isStartingFlow = false
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

// MARK: - Capture sound

/// Plays the screenshot sound effect on `finishOutput`. Holds the most
/// recently created `NSSound` instance as a stored property so the sound is
/// not deallocated mid-playback. Recreating the same `NSSound` (instead of
/// calling `play()` on a single instance) is the documented way to retrigger
/// the sound when captures happen in quick succession.
///
/// Earlier versions inlined `NSSound(...)` as a local in `MainActor.run`
/// closures inside `CapturePipeline.finishOutput`. On macOS 26 the local
/// could be released as the closure returned, risking truncated playback.
/// Hoisting the reference here keeps it alive across the async boundary.
@MainActor
final class CaptureSoundPlayer {
    static let shared = CaptureSoundPlayer()

    private static let systemSoundPath =
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"

    private var current: NSSound?

    private init() {}

    func play() {
        let sound = NSSound(contentsOfFile: Self.systemSoundPath, byReference: true)
            ?? NSSound(named: NSSound.Name("Glass"))
        guard let sound else { return }
        current = sound
        sound.play()
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
