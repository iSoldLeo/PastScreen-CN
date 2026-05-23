//
//  CapturePipeline.swift
//  Mio
//
//  Actor that executes the capture → output flow.
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

public actor CapturePipeline {
    private let displayCapture: any ScreenCapturing
    private let fileOutput: any FileWriting
    private let clipboardOutput: any ClipboardWriting
    private let eventBus: any EventBusing

    public init(
        displayCapture: any ScreenCapturing,
        fileOutput: any FileWriting,
        clipboardOutput: any ClipboardWriting,
        eventBus: any EventBusing
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
