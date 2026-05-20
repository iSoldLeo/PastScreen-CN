//
//  FileOutputService.swift
//  PastScreen
//
//  Actor for disk I/O: saving captures to files.
//  No Task.detached — actor isolation provides the background context.
//

import Foundation
// TODO: Remove @preconcurrency once Apple marks NSBitmapImageRep as Sendable.
@preconcurrency import AppKit

public actor FileOutputService: FileWriting {
    public init() {}

    /// Save image to disk. Returns the saved path and the next sequence number.
    public func write(
        image: CaptureImage,
        config: CaptureConfiguration,
        sequence: Int
    ) async throws -> (path: String?, nextSequence: Int) {
        let cgImage = image.cgImage
        let pointSize = image.size
        let imageFormat = config.imageFormat
        let folderPath = config.saveFolderPath

        let bitmapImage = NSBitmapImageRep(cgImage: cgImage)
        bitmapImage.size = pointSize

        let fileType: NSBitmapImageRep.FileType
        let fileExtension: String

        switch imageFormat.lowercased() {
        case "jpeg", "jpg":
            fileType = .jpeg
            fileExtension = "jpg"
        default:
            fileType = .png
            fileExtension = "png"
        }

        guard let data = bitmapImage.representation(using: fileType, properties: [:]) else {
            return (nil, sequence)
        }

        var seq = sequence
        var filename = "Screen-\(seq).\(fileExtension)"

        let fileManager = FileManager.default
        var savePath = folderPath + filename

        while fileManager.fileExists(atPath: savePath) {
            seq += 1
            filename = "Screen-\(seq).\(fileExtension)"
            savePath = folderPath + filename
        }

        let nextSeq = seq + 1

        do {
            try data.write(to: URL(fileURLWithPath: savePath))
            return (savePath, nextSeq)
        } catch {
            let tempFolder = NSTemporaryDirectory()
            let tempPath = (tempFolder as NSString).appendingPathComponent(filename)

            do {
                try data.write(to: URL(fileURLWithPath: tempPath))
                return (tempPath, nextSeq)
            } catch {
                return (nil, nextSeq)
            }
        }
    }
}
