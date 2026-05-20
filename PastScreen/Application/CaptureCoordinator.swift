//
//  CaptureCoordinator.swift
//  PastScreen
//
//  @MainActor coordinator that bridges UI entry points (hotkey, menu bar)
//  to the CapturePipeline. Manages SelectionWindow lifecycle and forwards
//  pipeline events to DynamicIsland / NotificationCenter.
//

import Foundation
import AppKit
import CoreGraphics

@MainActor
public final class CaptureCoordinator: SelectionWindowDelegate {
    private let pipeline: CapturePipeline
    private let eventBus: CaptureEventBus
    private var selectionWindow: SelectionWindow?
    private var eventTask: Task<Void, Never>?

    public init(pipeline: CapturePipeline, eventBus: CaptureEventBus) {
        self.pipeline = pipeline
        self.eventBus = eventBus
        startListeningToEvents()
    }

    // MARK: - Public API

    /// Start an area-selection capture flow. Creates a SelectionWindow
    /// and waits for the user to drag a rect or click a window.
    public func startAreaCapture() {
        cleanupExistingWindow()

        let window = SelectionWindow(
            frozenScreenshots: [:],
            overlayConfiguration: .screenshot
        )
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

    // MARK: - SelectionWindowDelegate

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

    // MARK: - Private

    private func executeCapture(request: CaptureRequest) async {
        let sequence = AppSettings.shared.screenshotSequence
        do {
            let output = try await pipeline.execute(request: request, sequence: sequence)
            if let nextSeq = output.nextSequence {
                AppSettings.shared.screenshotSequence = nextSeq
            }
        } catch {
            showCaptureError(error)
        }
    }

    private func makeCaptureConfiguration() -> CaptureConfiguration {
        let settings = AppSettings.shared
        return CaptureConfiguration(
            imageFormat: settings.imageFormat,
            saveToFile: settings.saveToFile,
            saveFolderPath: settings.saveFolderPath,
            hasValidSaveFolder: settings.hasValidSaveFolder,
            windowBorderEnabled: settings.windowBorderEnabled,
            windowBorderWidth: settings.windowBorderWidth,
            windowBorderCornerRadius: settings.windowBorderCornerRadius,
            windowBorderColor: settings.windowBorderColor,
            captureClipboardFormat: settings.captureClipboardFormat.rawValue,
            playSoundOnCapture: settings.playSoundOnCapture
        )
    }

    private func cleanupExistingWindow() {
        selectionWindow?.hide()
        selectionWindow = nil
    }

    private func cleanupSelectionWindow() {
        selectionWindow = nil
        NotificationCenter.default.post(name: .captureFlowEnded, object: nil)
    }

    private func showCaptureError(_ error: Error) {
        DynamicIslandManager.shared.show(
            message: error.localizedDescription,
            duration: 3.0,
            style: .failure
        )
    }

    // MARK: - Event bus listener

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
        case .savedToFile(let path):
            DynamicIslandManager.shared.show(message: "已保存", duration: 3.0, style: .success)
            // Backward-compatible notification for AppDelegate.lastScreenshotPath
            NotificationCenter.default.post(
                name: .screenshotCaptured,
                object: nil,
                userInfo: ["filePath": path]
            )
        case .failed(let error):
            DynamicIslandManager.shared.show(
                message: error.localizedDescription,
                duration: 3.0,
                style: .failure
            )
        case .copiedToClipboard:
            DynamicIslandManager.shared.show(message: "已复制", duration: 1.5, style: .success)
        default:
            break
        }
    }

    deinit {
        eventTask?.cancel()
    }
}
