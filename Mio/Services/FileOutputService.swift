//
//  FileOutputService.swift
//  Mio
//
//  Actor for disk I/O: saving captures to files. Owns the on-disk
//  filename sequence counter — it is a property of the file output
//  pipeline, not a user preference, so the state lives here rather
//  than in AppSettings.
//
//  No Task.detached — actor isolation provides the background context.
//

import Foundation
// TODO: Remove @preconcurrency once Apple marks NSBitmapImageRep as Sendable.
@preconcurrency import AppKit

public actor FileOutputService: FileWriting {

    /// UserDefaults key under which the next-to-write sequence number is
    /// persisted. The same key was used by AppSettings before Phase 5, so
    /// existing user installs are picked up transparently.
    nonisolated private static let sequenceDefaultsKey = "screenshotSequence"

    /// Cached sequence counter. Loaded lazily from UserDefaults on first
    /// `write`/`reset` call. Always holds the *next* sequence number to
    /// try when generating a filename.
    private var currentSequence: Int?

    public init() {}

    /// Save image to disk.
    /// Writes atomically via a temporary file to avoid partial writes on crash.
    public func write(
        image: CaptureImage,
        config: CaptureConfiguration
    ) async throws -> String? {
        let cgImage = image.cgImage
        let pointSize = image.size
        let imageFormat = config.imageFormat
        let folderPath = config.saveFolderPath

        let bitmapImage = NSBitmapImageRep(cgImage: cgImage)
        bitmapImage.size = pointSize

        let fileType = imageFormat.nsBitmapFileType
        let fileExtension = imageFormat.fileExtension

        guard let data = bitmapImage.representation(using: fileType, properties: [:]) else {
            throw CaptureError("Failed to encode image as \(fileExtension)")
        }

        var seq = loadSequenceIfNeeded()
        var filename = "Screen-\(seq).\(fileExtension)"

        let fileManager = FileManager.default
        let folderURL = URL(fileURLWithPath: folderPath, isDirectory: true)
        var saveURL = folderURL.appendingPathComponent(filename)

        while fileManager.fileExists(atPath: saveURL.path) {
            seq += 1
            filename = "Screen-\(seq).\(fileExtension)"
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

    /// Reset the on-disk sequence counter to 1. Called by AppSettings after
    /// `clearSaveFolder` so the next capture starts fresh.
    public func resetSequence() {
        persistSequence(1)
    }

    // MARK: - Private

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
