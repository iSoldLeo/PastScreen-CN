//
//  CaptureConfiguration.swift
//  Mio
//
//  Pure-value snapshot of capture settings.
//  Passed by value across actor boundaries — no MainActor hop required.
//

import Foundation

nonisolated public struct CaptureConfiguration: Sendable {
    public let imageFormat: ImageFormat
    public let saveToFile: Bool
    public let saveFolderPath: String
    public let hasValidSaveFolder: Bool

    public let windowBorderEnabled: Bool
    public let windowBorderWidth: Double
    public let windowBorderCornerRadius: Double
    public let windowBorderColor: RGBAColor

    public let captureClipboardFormat: CaptureClipboardFormat
    public let playSoundOnCapture: Bool

    public init(
        imageFormat: ImageFormat,
        saveToFile: Bool,
        saveFolderPath: String,
        hasValidSaveFolder: Bool,
        windowBorderEnabled: Bool,
        windowBorderWidth: Double,
        windowBorderCornerRadius: Double,
        windowBorderColor: RGBAColor,
        captureClipboardFormat: CaptureClipboardFormat,
        playSoundOnCapture: Bool
    ) {
        self.imageFormat = imageFormat
        self.saveToFile = saveToFile
        self.saveFolderPath = saveFolderPath
        self.hasValidSaveFolder = hasValidSaveFolder
        self.windowBorderEnabled = windowBorderEnabled
        self.windowBorderWidth = windowBorderWidth
        self.windowBorderCornerRadius = windowBorderCornerRadius
        self.windowBorderColor = windowBorderColor
        self.captureClipboardFormat = captureClipboardFormat
        self.playSoundOnCapture = playSoundOnCapture
    }
}
