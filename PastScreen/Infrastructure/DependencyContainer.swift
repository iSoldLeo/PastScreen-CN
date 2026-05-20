//
//  DependencyContainer.swift
//  PastScreen
//
//  Explicit dependency graph. Replaces .shared singletons.
//

import Foundation

@MainActor
public final class DependencyContainer {
    public let eventBus = CaptureEventBus()
    public let fileOutput: any FileWriting = FileOutputService()
    public let clipboardOutput: any ClipboardWriting = ClipboardOutputService()
    public let displayCapture: any ScreenCapturing = DisplayCaptureService()
    public let imageRender: any ImageRendering = ImageRenderService()
    public let pipeline: CapturePipeline
    public let captureCoordinator: CaptureCoordinator

    let settingsStore = AppSettings.shared

    public init() {
        self.pipeline = CapturePipeline(
            displayCapture: displayCapture,
            imageRender: imageRender,
            fileOutput: fileOutput,
            clipboardOutput: clipboardOutput,
            eventBus: eventBus
        )
        self.captureCoordinator = CaptureCoordinator(
            pipeline: pipeline,
            eventBus: eventBus
        )
    }
}
