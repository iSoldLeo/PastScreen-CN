//
//  DependencyContainer.swift
//  Mio
//
//  Composition root for the capture pipeline. Wires service
//  implementations into `CapturePipeline` and `CaptureCoordinator`.
//
//  D3 decision (Phase 1):
//  This container manages capture-pipeline services only. Application
//  preferences remain accessible through `AppSettings.shared`, which is
//  also the SwiftUI environment object backing the Settings scene;
//  injecting it through the container would break that integration.
//
//  Phase 6B note (injection):
//  All service dependencies are accepted as `any XxxYy` protocol-typed
//  parameters with production defaults, so production callers continue
//  to write `DependencyContainer()` while tests can substitute fakes
//  without touching call sites elsewhere.
//

import Foundation

@MainActor
public final class DependencyContainer {
    public let eventBus: any EventBusing
    public let fileOutput: any FileWriting
    public let clipboardOutput: any ClipboardWriting
    public let displayCapture: any ScreenCapturing
    public let imageRender: any ImageRendering
    public let pipeline: CapturePipeline
    public let captureCoordinator: CaptureCoordinator

    /// Production callers use the no-argument default; tests can pass
    /// alternative service implementations via the named parameters.
    public init(
        eventBus: any EventBusing = CaptureEventBus(),
        fileOutput: any FileWriting = FileOutputService(),
        clipboardOutput: any ClipboardWriting = ClipboardOutputService(),
        displayCapture: any ScreenCapturing = DisplayCaptureService(),
        imageRender: any ImageRendering = ImageRenderService()
    ) {
        self.eventBus = eventBus
        self.fileOutput = fileOutput
        self.clipboardOutput = clipboardOutput
        self.displayCapture = displayCapture
        self.imageRender = imageRender
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
