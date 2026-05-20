//
//  CapturePipeline.swift
//  PastScreen
//
//  Actor that executes the capture → render → output flow.
//  All work happens off the main thread.
//

import Foundation
import AppKit
import CoreGraphics

public enum CaptureRequest: Sendable {
    case area(CGRect, config: CaptureConfiguration)
    case window(windowID: CGWindowID, bounds: CGRect, config: CaptureConfiguration)
    case fullscreen(rect: CGRect, config: CaptureConfiguration)
}

public struct CapturePipelineOutput: Sendable {
    public let result: CaptureResult
    public let filePath: String?
    public let nextSequence: Int?
}

public actor CapturePipeline {
    private let displayCapture: any ScreenCapturing
    private let imageRender: any ImageRendering
    private let fileOutput: any FileWriting
    private let clipboardOutput: any ClipboardWriting
    private let eventBus: CaptureEventBus

    public init(
        displayCapture: any ScreenCapturing,
        imageRender: any ImageRendering,
        fileOutput: any FileWriting,
        clipboardOutput: any ClipboardWriting,
        eventBus: CaptureEventBus
    ) {
        self.displayCapture = displayCapture
        self.imageRender = imageRender
        self.fileOutput = fileOutput
        self.clipboardOutput = clipboardOutput
        self.eventBus = eventBus
    }

    public func execute(request: CaptureRequest, sequence: Int) async throws -> CapturePipelineOutput {
        let config: CaptureConfiguration = switch request {
        case .area(_, let cfg): cfg
        case .window(_, _, let cfg): cfg
        case .fullscreen(_, let cfg): cfg
        }

        eventBus.emit(.started(config))
        try Task.checkCancellation()

        let captureType: CaptureItemCaptureType
        let capturedImage: CaptureImage
        var appBundleID: String?
        var appName: String?

        switch request {
        case .area(let rect, _):
            captureType = .area
            capturedImage = try await displayCapture.captureDisplay(rect: rect, excludingWindowIDs: [])
            appBundleID = nil
            appName = nil

        case .window(let windowID, _, _):
            captureType = .window
            capturedImage = try await displayCapture.captureWindow(windowID: windowID)
            appBundleID = nil
            appName = nil

        case .fullscreen(let rect, _):
            captureType = .fullscreen
            capturedImage = try await displayCapture.captureDisplay(rect: rect, excludingWindowIDs: [])
            appBundleID = nil
            appName = nil
        }

        try Task.checkCancellation()

        // Render border for window captures when enabled
        var finalImage = capturedImage
        if captureType == .window && config.windowBorderEnabled {
            finalImage = try await imageRender.addBorder(to: capturedImage, config: config)
            try Task.checkCancellation()
        }

        // File output (must happen before clipboard for path/markdown formats)
        var filePath: String?
        var nextSequence: Int?
        if config.saveToFile && config.hasValidSaveFolder {
            let (path, seq) = try await fileOutput.write(
                image: finalImage,
                config: config,
                sequence: sequence
            )
            filePath = path
            nextSequence = seq
            try Task.checkCancellation()
        }

        // Clipboard output (async call automatically hops to @MainActor implementation)
        try await clipboardOutput.copy(image: finalImage, config: config, filePath: filePath)

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

        let result = CaptureResult(
            image: finalImage,
            captureType: captureType,
            appBundleID: appBundleID,
            appName: appName
        )

        eventBus.emit(.captured(result))
        if let filePath {
            eventBus.emit(.savedToFile(path: filePath))
        }
        eventBus.emit(.copiedToClipboard)

        return CapturePipelineOutput(result: result, filePath: filePath, nextSequence: nextSequence)
    }
}
