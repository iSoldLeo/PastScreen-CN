//
//  CapturePipeline.swift
//  Mio
//
//  Sole owner of module-04 ScreenCaptureKit and WindowServer acquisition.
//

import AppKit
import CoreGraphics
import CoreVideo
import Foundation
import OSLog
import ScreenCaptureKit
import Synchronization

private typealias ScreenTopology = (
    displayID: CGDirectDisplayID,
    frameInAppKitPoints: CGRect,
    backingScale: CGFloat
)

// Intentionally non-Sendable: SCK references stay in this actor invocation.
nonisolated private struct CaptureJob {
    let id: UInt64
    let filter: SCContentFilter
    let configuration: SCStreamConfiguration
    let scale: CGFloat
    let pixelWidth: Int
    let pixelHeight: Int
    let windowID: CGWindowID?
    let isStrict: Bool
}

nonisolated private struct CaptureCompletion: Sendable {
    let jobID: UInt64
    let image: CGImage?
    let errorDomain: String?
    let errorCode: Int?
}

// A cancelled consumer still drains every committed SCK callback. The Mutex
// linearizes cancellation with submission and handles callback-before-waiter.
nonisolated private final class CallbackMailbox: Sendable {
    private struct State {
        var registered: Set<UInt64> = []
        var delivered: Set<UInt64> = []
        var buffered: [CaptureCompletion] = []
        var waiter: CheckedContinuation<CaptureCompletion, Never>?
        var cancellationRequested = false
        var closed = false
        var anomalyCount = 0
    }

    private let state = Mutex(State())

    func beginSubmission(_ id: UInt64) -> Bool {
        state.withLock {
            guard !$0.closed, !$0.cancellationRequested else { return false }
            return $0.registered.insert(id).inserted
        }
    }

    func requestCancellation() {
        state.withLock { $0.cancellationRequested = true }
    }

    func push(_ completion: CaptureCompletion) {
        var waiter: CheckedContinuation<CaptureCompletion, Never>?
        state.withLock {
            guard
                !$0.closed,
                $0.registered.contains(completion.jobID),
                $0.delivered.insert(completion.jobID).inserted
            else {
                $0.anomalyCount += 1
                return
            }
            if let pending = $0.waiter {
                $0.waiter = nil
                waiter = pending
            } else {
                $0.buffered.append(completion)
            }
        }
        waiter?.resume(returning: completion)
    }

    func next() async -> CaptureCompletion {
        await withCheckedContinuation { continuation in
            var immediate: CaptureCompletion?
            state.withLock {
                if !$0.buffered.isEmpty {
                    immediate = $0.buffered.removeFirst()
                } else {
                    precondition($0.waiter == nil && !$0.closed)
                    $0.waiter = continuation
                }
            }
            if let immediate { continuation.resume(returning: immediate) }
        }
    }

    func close() -> (registered: Int, delivered: Int, anomalies: Int, clean: Bool) {
        state.withLock {
            $0.closed = true
            return (
                $0.registered.count,
                $0.delivered.count,
                $0.anomalyCount,
                $0.waiter == nil && $0.buffered.isEmpty
            )
        }
    }
}

actor CapturePipeline {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.iSoldLeo.Mio",
        category: "capture.acquisition"
    )

    private var activeUserCorrelationID: UUID?
    private var prewarmCorrelationID: UUID?

    func captureFrozenScreens(correlationID: UUID) async throws -> FrozenScreens {
        try await performUser(route: "frozen_screens", id: correlationID) { pipeline, cap in
            let topology = try await pipeline.snapshotTopology()
            let content = try await pipeline.currentContent()
            try Task.checkCancellation()
            let displays = Dictionary(uniqueKeysWithValues: content.displays.map { ($0.displayID, $0) })
            let jobs = try topology.screens.enumerated().map {
                try pipeline.displayJob(id: UInt64($0.offset + 1), topology: $0.element, displays: displays)
            }
            let pump = try await pipeline.run(jobs, cap: cap, correlationID: correlationID)
            let screens = try pipeline.frozenScreens(topology.screens, jobs, pump.completions)
            return (screens, screens.ordered.count, 0, pump.highWater, pump.anomalies)
        }
    }

    func prewarm(correlationID: UUID) async throws -> PrewarmOutcome {
        let start = ContinuousClock().now
        logStart("prewarm", correlationID)
        do {
            try Task.checkCancellation()
            guard activeUserCorrelationID == nil, prewarmCorrelationID == nil else {
                logEnd("prewarm", correlationID, "skipped_active_capture", start)
                return .skippedForActiveCapture
            }
            prewarmCorrelationID = correlationID
            defer { if prewarmCorrelationID == correlationID { prewarmCorrelationID = nil } }

            let content = try await currentContent()
            try Task.checkCancellation()
            guard let display = content.displays.first else { throw CaptureAcquisitionError.noDisplays }
            let pump = try await run(
                [prewarmJob(id: 1, display: display)],
                cap: 1,
                correlationID: correlationID
            )
            try Task.checkCancellation()
            logEnd("prewarm", correlationID, "completed", start, highWater: pump.highWater, anomalies: pump.anomalies)
            return .completed
        } catch is CancellationError {
            logEnd("prewarm", correlationID, "cancelled", start)
            throw CancellationError()
        } catch let error as CaptureAcquisitionError {
            logEnd("prewarm", correlationID, "failed_\(error.stableLogCode)", start)
            throw error
        } catch {
            try Task.checkCancellation()
            let mapped = CaptureAcquisitionError.platformFailure(code: (error as NSError).code)
            logEnd("prewarm", correlationID, "failed_\(mapped.stableLogCode)", start)
            throw mapped
        }
    }

    func captureWindowOnDemand(
        expected: CaptureWindowDescriptor,
        correlationID: UUID
    ) async throws -> CaptureImage {
        try await performUser(route: "window_on_demand", id: correlationID) { pipeline, _ in
            let content = try await pipeline.currentContent()
            try Task.checkCancellation()
            guard
                expected.isSelectable,
                let window = content.windows.first(where: { $0.windowID == expected.windowID }),
                let app = window.owningApplication,
                app.processID == expected.ownerPID
            else {
                throw CaptureAcquisitionError.windowUnavailable(expected.windowID)
            }
            let job = try pipeline.windowJob(
                id: 1,
                window: window,
                windowID: expected.windowID,
                strict: true
            )
            let pump = try await pipeline.run([job], cap: 1, correlationID: correlationID)
            guard let completion = pump.completions[job.id] else {
                throw CaptureAcquisitionError.windowUnavailable(expected.windowID)
            }
            let image = try pipeline.validated(
                completion,
                width: job.pixelWidth,
                height: job.pixelHeight,
                scale: job.scale
            )
            return (image, 0, 1, pump.highWater, pump.anomalies)
        }
    }

    private func performUser<T: Sendable>(
        route: String,
        id: UUID,
        operation: @Sendable (isolated CapturePipeline, Int) async throws -> (
            value: T,
            screens: Int,
            windows: Int,
            highWater: Int,
            anomalies: Int
        )
    ) async throws -> T {
        let start = ContinuousClock().now
        logStart(route, id)
        do {
            try Task.checkCancellation()
            guard activeUserCorrelationID == nil else {
                Self.logger.notice(
                    "event=capture.acquisition.pipeline_busy old_correlation_id=\(self.activeUserCorrelationID?.uuidString ?? "unknown", privacy: .public) new_correlation_id=\(id.uuidString, privacy: .public) reason=late_operation_active result=rejected"
                )
                throw CaptureAcquisitionError.pipelineBusy
            }
            activeUserCorrelationID = id
            defer { if activeUserCorrelationID == id { activeUserCorrelationID = nil } }
            let result = try await operation(self, prewarmCorrelationID == nil ? 3 : 2)
            try Task.checkCancellation()
            logEnd(
                route, id, "completed", start,
                screens: result.screens,
                windows: result.windows,
                highWater: result.highWater,
                anomalies: result.anomalies
            )
            return result.value
        } catch is CancellationError {
            logEnd(route, id, "cancelled", start)
            throw CancellationError()
        } catch let error as CaptureAcquisitionError {
            logEnd(route, id, "failed_\(error.stableLogCode)", start)
            throw error
        } catch {
            try Task.checkCancellation()
            let mapped = CaptureAcquisitionError.platformFailure(code: (error as NSError).code)
            logEnd(route, id, "failed_\(mapped.stableLogCode)", start)
            throw mapped
        }
    }

    private func snapshotTopology() async throws -> (screens: [ScreenTopology], mainHeight: CGFloat) {
        let snapshot = await MainActor.run {
            let mainID = CGMainDisplayID()
            let screens: [ScreenTopology] = NSScreen.screens.compactMap {
                guard let id = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                        as? CGDirectDisplayID else { return nil }
                return (id, $0.frame, $0.backingScaleFactor)
            }
            return (screens, mainID, CGDisplayBounds(mainID).height)
        }
        guard !snapshot.0.isEmpty else { throw CaptureAcquisitionError.noDisplays }
        guard snapshot.2.isFinite, snapshot.2 > 0 else { throw CaptureAcquisitionError.invalidGeometry }
        var ids: Set<CGDirectDisplayID> = []
        for screen in snapshot.0 {
            guard
                ids.insert(screen.displayID).inserted,
                valid(screen.frameInAppKitPoints),
                screen.backingScale.isFinite,
                screen.backingScale > 0
            else { throw CaptureAcquisitionError.invalidGeometry }
        }
        return (
            snapshot.0.sorted {
                if $0.displayID == snapshot.1 { return $1.displayID != snapshot.1 }
                if $1.displayID == snapshot.1 { return false }
                return $0.displayID < $1.displayID
            },
            snapshot.2
        )
    }

    private func currentContent() async throws -> SCShareableContent {
        try Task.checkCancellation()
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            let value = error as NSError
            if value.domain == SCStreamErrorDomain,
               value.code == SCStreamError.Code.userDeclined.rawValue {
                throw CaptureAcquisitionError.permissionDenied
            }
            throw CaptureAcquisitionError.contentEnumerationFailed
        }
    }

    private func displayJob(
        id: UInt64,
        topology: ScreenTopology,
        displays: [CGDirectDisplayID: SCDisplay]
    ) throws -> CaptureJob {
        guard let display = displays[topology.displayID] else {
            throw CaptureAcquisitionError.displayUnavailable(topology.displayID)
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let scale = CGFloat(filter.pointPixelScale)
        guard scale.isFinite, scale > 0 else { throw CaptureAcquisitionError.invalidGeometry }
        guard
            abs(filter.contentRect.width - topology.frameInAppKitPoints.width) < 0.5,
            abs(filter.contentRect.height - topology.frameInAppKitPoints.height) < 0.5
        else { throw CaptureAcquisitionError.topologyChanged }
        guard abs(scale - topology.backingScale) < 0.01 else {
            throw CaptureAcquisitionError.topologyChanged
        }
        let pixels = try pixelSize(topology.frameInAppKitPoints.size, scale)
        let configuration = SCStreamConfiguration()
        configuration.width = pixels.width
        configuration.height = pixels.height
        configuration.captureResolution = .best
        configuration.showsCursor = false
        configuration.scalesToFit = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.shouldBeOpaque = true
        return CaptureJob(
            id: id, filter: filter, configuration: configuration, scale: scale,
            pixelWidth: pixels.width, pixelHeight: pixels.height,
            windowID: nil, isStrict: true
        )
    }

    private func windowJob(
        id: UInt64,
        window: SCWindow,
        windowID: CGWindowID,
        strict: Bool
    ) throws -> CaptureJob {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let pixels = try pixelSize(filter.contentRect.size, scale)
        let configuration = SCStreamConfiguration()
        configuration.width = pixels.width
        configuration.height = pixels.height
        configuration.captureResolution = .best
        configuration.showsCursor = false
        configuration.scalesToFit = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.backgroundColor = .clear
        configuration.ignoreShadowsSingleWindow = true
        configuration.shouldBeOpaque = false
        return CaptureJob(
            id: id, filter: filter, configuration: configuration, scale: scale,
            pixelWidth: pixels.width, pixelHeight: pixels.height,
            windowID: windowID, isStrict: strict
        )
    }

    private func prewarmJob(id: UInt64, display: SCDisplay) -> CaptureJob {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.showsCursor = false
        configuration.scalesToFit = true
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        return CaptureJob(
            id: id, filter: filter, configuration: configuration, scale: 1,
            pixelWidth: 2, pixelHeight: 2, windowID: nil, isStrict: true
        )
    }

    private func pixelSize(_ points: CGSize, _ scale: CGFloat) throws -> (width: Int, height: Int) {
        guard
            points.width.isFinite, points.height.isFinite, scale.isFinite,
            points.width > 0, points.height > 0, scale > 0
        else { throw CaptureAcquisitionError.invalidGeometry }
        let width = (points.width * scale).rounded()
        let height = (points.height * scale).rounded()
        guard width.isFinite, height.isFinite, width >= 2, height >= 2,
              width <= CGFloat(Int.max), height <= CGFloat(Int.max)
        else { throw CaptureAcquisitionError.invalidPixelDimensions }
        return (Int(width), Int(height))
    }

    private func run(
        _ jobs: [CaptureJob],
        cap: Int,
        correlationID: UUID
    ) async throws -> (completions: [UInt64: CaptureCompletion], highWater: Int, anomalies: Int) {
        let mailbox = CallbackMailbox()
        let metadata = Dictionary(uniqueKeysWithValues: jobs.map {
            ($0.id, (strict: $0.isStrict, width: $0.pixelWidth, height: $0.pixelHeight))
        })
        return try await withTaskCancellationHandler {
            var next = 0
            var inFlight: Set<UInt64> = []
            var output: [UInt64: CaptureCompletion] = [:]
            var highWater = 0
            var stop = false
            var strictFailure: CaptureAcquisitionError?

            while (!stop && next < jobs.count) || !inFlight.isEmpty {
                while !stop, next < jobs.count, inFlight.count < cap {
                    let job = jobs[next]
                    guard mailbox.beginSubmission(job.id) else { stop = true; break }
                    next += 1
                    inFlight.insert(job.id)
                    highWater = max(highWater, inFlight.count)
                    let jobID = job.id
                    Self.submit(job, jobID: jobID, mailbox: mailbox)
                }
                guard !inFlight.isEmpty else { break }
                let completion = await mailbox.next()
                guard inFlight.remove(completion.jobID) != nil else { continue }
                output[completion.jobID] = completion
                if let value = metadata[completion.jobID], value.strict,
                   let failure = failure(completion, value.width, value.height) {
                    if strictFailure == nil { strictFailure = failure }
                    stop = true
                }
                if Task.isCancelled { stop = true }
            }

            let closed = mailbox.close()
            Self.logger.debug(
                "event=capture.acquisition.callbacks_closed correlation_id=\(correlationID.uuidString, privacy: .public) registered_count=\(closed.registered, privacy: .public) delivered_count=\(closed.delivered, privacy: .public) callback_anomaly_count=\(closed.anomalies, privacy: .public)"
            )
            guard closed.registered == closed.delivered, closed.clean else {
                throw CaptureAcquisitionError.platformFailure(code: nil)
            }
            if Task.isCancelled { throw CancellationError() }
            if let strictFailure { throw strictFailure }
            return (output, highWater, closed.anomalies)
        } onCancel: {
            mailbox.requestCancellation()
        }
    }

    private func failure(
        _ completion: CaptureCompletion,
        _ width: Int,
        _ height: Int
    ) -> CaptureAcquisitionError? {
        if completion.errorDomain == nil, let image = completion.image {
            return image.width == width && image.height == height ? nil : .invalidPixelDimensions
        }
        if completion.errorDomain == SCStreamErrorDomain {
            if completion.errorCode == SCStreamError.Code.userDeclined.rawValue { return .permissionDenied }
            if completion.errorCode == SCStreamError.Code.systemStoppedStream.rawValue { return .captureInterrupted }
        }
        return .platformFailure(code: completion.errorCode)
    }

    nonisolated private static func submit(
        _ job: CaptureJob,
        jobID: UInt64,
        mailbox: CallbackMailbox
    ) {
        SCScreenshotManager.captureImage(
            contentFilter: job.filter,
            configuration: job.configuration
        ) { image, error in
            let value = error as NSError?
            mailbox.push(CaptureCompletion(
                jobID: jobID,
                image: image,
                errorDomain: value?.domain,
                errorCode: value?.code
            ))
        }
    }

    private func validated(
        _ completion: CaptureCompletion,
        width: Int,
        height: Int,
        scale: CGFloat
    ) throws -> CaptureImage {
        if let failure = failure(completion, width, height) { throw failure }
        guard let image = completion.image else { throw CaptureAcquisitionError.platformFailure(code: nil) }
        do { return try CaptureImage(validating: image, scale: scale) }
        catch { throw CaptureAcquisitionError.invalidGeometry }
    }

    private func frozenScreens(
        _ topology: [ScreenTopology],
        _ jobs: [CaptureJob],
        _ completions: [UInt64: CaptureCompletion]
    ) throws -> FrozenScreens {
        guard topology.count == jobs.count else { throw CaptureAcquisitionError.topologyChanged }
        let screens = try zip(topology, jobs).map { screen, job in
            guard let completion = completions[job.id] else {
                throw CaptureAcquisitionError.invalidPixelDimensions
            }
            let image = try validated(
                completion,
                width: job.pixelWidth,
                height: job.pixelHeight,
                scale: job.scale
            )
            return FrozenScreen(
                displayID: screen.displayID,
                frameInAppKitPoints: screen.frameInAppKitPoints,
                image: image
            )
        }
        return FrozenScreens(ordered: screens)
    }

    private func valid(_ rect: CGRect) -> Bool {
        rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0
    }

    private func logStart(_ route: String, _ id: UUID) {
        Self.logger.info(
            "event=capture.acquisition.started correlation_id=\(id.uuidString, privacy: .public) route=\(route, privacy: .public) result=started"
        )
    }

    private func logEnd(
        _ route: String,
        _ id: UUID,
        _ result: String,
        _ start: ContinuousClock.Instant,
        screens: Int = 0,
        windows: Int = 0,
        highWater: Int = 0,
        anomalies: Int = 0
    ) {
        Self.logger.info(
            "event=capture.acquisition.terminal correlation_id=\(id.uuidString, privacy: .public) route=\(route, privacy: .public) result=\(result, privacy: .public) duration_ms=\(self.milliseconds(start), privacy: .public) screen_count=\(screens, privacy: .public) window_count=\(windows, privacy: .public) high_water=\(highWater, privacy: .public) callback_anomaly_count=\(anomalies, privacy: .public)"
        )
    }

    private func milliseconds(_ start: ContinuousClock.Instant) -> Int64 {
        let value = start.duration(to: ContinuousClock().now).components
        let seconds = value.seconds > Int64.max / 1_000 ? Int64.max : value.seconds * 1_000
        let millis = Int64(value.attoseconds / 1_000_000_000_000_000)
        let (sum, overflow) = seconds.addingReportingOverflow(millis)
        return overflow ? Int64.max : max(sum, 0)
    }
}
