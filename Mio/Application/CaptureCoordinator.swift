//
//  CaptureCoordinator.swift
//  Mio
//
//  @MainActor coordinator that bridges UI entry points (hotkey, menu bar)
//  to the CapturePipeline. Manages SelectionWindow lifecycle and forwards
//  pipeline events to DynamicIsland.
//

import Foundation
import AppKit
import CoreGraphics

@MainActor
public final class CaptureCoordinator: SelectionWindowDelegate {
    private let pipeline: CapturePipeline
    private let eventBus: any EventBusing
    private var selectionWindow: SelectionWindow?
    private var eventTask: Task<Void, Never>?

    public init(pipeline: CapturePipeline, eventBus: any EventBusing) {
        self.pipeline = pipeline
        self.eventBus = eventBus
        startListeningToEvents()
    }

    // MARK: - Public API

    /// Start an area-selection capture flow. Creates a SelectionWindow
    /// and waits for the user to drag a rect or click a window.
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
