//
//  CaptureConfiguration.swift
//  Mio
//
//  Pure-value snapshot of capture settings.
//  Passed by value across actor boundaries — no MainActor hop required.
//

import Foundation

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
