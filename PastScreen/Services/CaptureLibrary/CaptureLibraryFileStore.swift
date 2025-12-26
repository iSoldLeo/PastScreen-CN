//
//  CaptureLibraryFileStore.swift
//  PastScreen
//

import AppKit
import Foundation

// MARK: - File Store

struct CaptureLibraryFileStore {
    nonisolated static let folderName = "CaptureLibrary"

    let rootURL: URL
    let databaseURL: URL
    let thumbsURL: URL
    let previewsURL: URL
    let originalsURL: URL

    nonisolated init(rootURL: URL) throws {
        self.rootURL = rootURL
        self.databaseURL = rootURL.appendingPathComponent("library.sqlite3", isDirectory: false)
        self.thumbsURL = rootURL.appendingPathComponent("thumbs", isDirectory: true)
        self.previewsURL = rootURL.appendingPathComponent("previews", isDirectory: true)
        self.originalsURL = rootURL.appendingPathComponent("originals", isDirectory: true)

        try ensureDirectoriesExist()
    }

    nonisolated static func defaultRootURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent(folderName, isDirectory: true)
    }

    nonisolated func ensureDirectoriesExist() throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: thumbsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: previewsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: originalsURL, withIntermediateDirectories: true)
    }

    nonisolated func fileURL(forRelativePath relativePath: String) -> URL {
        rootURL.appendingPathComponent(relativePath, isDirectory: false)
    }

    nonisolated func deleteIfExists(relativePath: String?) {
        guard let relativePath, !relativePath.isEmpty else { return }
        let url = fileURL(forRelativePath: relativePath)
        try? FileManager.default.removeItem(at: url)
    }

    nonisolated func writeThumbnail(
        id: UUID,
        from image: CGImage,
        maxDimension: Int = 320,
        quality: CGFloat = 0.82
    ) throws -> (relativePath: String, pixelSize: CGSize, byteCount: Int) {
        let relativePath = "thumbs/\(id.uuidString).jpg"
        let url = fileURL(forRelativePath: relativePath)
        let (data, size) = try Self.makeJPEGData(from: image, maxDimension: maxDimension, quality: quality)
        try data.write(to: url, options: .atomic)
        return (relativePath, size, data.count)
    }

    nonisolated func writePreview(
        id: UUID,
        from image: CGImage,
        maxDimension: Int = 1600,
        quality: CGFloat = 0.86
    ) throws -> (relativePath: String, pixelSize: CGSize, byteCount: Int) {
        let relativePath = "previews/\(id.uuidString).jpg"
        let url = fileURL(forRelativePath: relativePath)
        let (data, size) = try Self.makeJPEGData(from: image, maxDimension: maxDimension, quality: quality)
        try data.write(to: url, options: .atomic)
        return (relativePath, size, data.count)
    }

    nonisolated static func makePlaceholderThumbnailData(size: CGSize = CGSize(width: 64, height: 64)) throws -> Data {
        let width = max(Int(size.width), 16)
        let height = max(Int(size.height), 16)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw NSError(domain: "CaptureLibraryFileStore", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法创建位图上下文"])
        }

        context.setFillColor(NSColor.windowBackgroundColor.withAlphaComponent(0.95).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.setLineWidth(2)
        context.stroke(CGRect(x: 2, y: 2, width: width - 4, height: height - 4))

        guard let cgImage = context.makeImage() else {
            throw NSError(domain: "CaptureLibraryFileStore", code: -2, userInfo: [NSLocalizedDescriptionKey: "无法生成占位图"])
        }

        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else {
            throw NSError(domain: "CaptureLibraryFileStore", code: -3, userInfo: [NSLocalizedDescriptionKey: "无法编码占位图"])
        }
        return data
    }

    nonisolated private static func makeJPEGData(from image: CGImage, maxDimension: Int, quality: CGFloat) throws -> (Data, CGSize) {
        let scaled = try scaledImage(from: image, maxDimension: maxDimension)
        let rep = NSBitmapImageRep(cgImage: scaled)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) else {
            throw NSError(domain: "CaptureLibraryFileStore", code: -4, userInfo: [NSLocalizedDescriptionKey: "无法编码 JPEG"])
        }
        return (data, CGSize(width: scaled.width, height: scaled.height))
    }

    nonisolated private static func scaledImage(from image: CGImage, maxDimension: Int) throws -> CGImage {
        let srcW = image.width
        let srcH = image.height
        let maxSide = max(srcW, srcH)
        guard maxSide > 0 else {
            throw NSError(domain: "CaptureLibraryFileStore", code: -5, userInfo: [NSLocalizedDescriptionKey: "无效图片尺寸"])
        }

        let targetW: Int
        let targetH: Int
        if maxSide <= maxDimension {
            targetW = srcW
            targetH = srcH
        } else {
            let scale = Double(maxDimension) / Double(maxSide)
            targetW = max(1, Int(Double(srcW) * scale))
            targetH = max(1, Int(Double(srcH) * scale))
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: targetW,
            height: targetH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw NSError(domain: "CaptureLibraryFileStore", code: -6, userInfo: [NSLocalizedDescriptionKey: "无法创建缩略图上下文"])
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))

        guard let scaled = context.makeImage() else {
            throw NSError(domain: "CaptureLibraryFileStore", code: -7, userInfo: [NSLocalizedDescriptionKey: "无法生成缩略图"])
        }
        return scaled
    }
}
