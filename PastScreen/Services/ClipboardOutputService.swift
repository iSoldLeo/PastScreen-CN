//
//  ClipboardOutputService.swift
//  PastScreen
//
//  @MainActor service for NSPasteboard operations.
//

import Foundation
// TODO: Remove @preconcurrency once Apple marks AppKit types as Sendable.
@preconcurrency import AppKit

@MainActor
public final class ClipboardOutputService: ClipboardWriting, Sendable {
    public init() {}

    /// Copy capture to clipboard based on configuration format.
    /// For path/markdown formats, filePath must be provided (file must already be saved).
    /// Falls back to image paste when filePath is nil for path-dependent formats.
    public func copy(image: CaptureImage, config: CaptureConfiguration, filePath: String?) async throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let format = CaptureClipboardFormat(rawValue: config.captureClipboardFormat) ?? .image

        switch format {
        case .image:
            copyImageToPasteboard(image: image, pasteboard: pasteboard)

        case .path:
            if let filePath, !filePath.isEmpty {
                pasteboard.setString(filePath, forType: .string)
            } else {
                copyImageToPasteboard(image: image, pasteboard: pasteboard)
            }

        case .markdownImage:
            if let filePath, let markdown = makeMarkdownImageReference(filePath: filePath) {
                pasteboard.setString(markdown, forType: .string)
            } else {
                copyImageToPasteboard(image: image, pasteboard: pasteboard)
            }
        }
    }

    // MARK: - Private helpers

    private func copyImageToPasteboard(image: CaptureImage, pasteboard: NSPasteboard) {
        if let pngData = makePNGClipboardData(from: image) {
            let item = NSPasteboardItem()
            item.setData(pngData, forType: .png)

            let nsImage = nsImage(from: image)
            if let tiffData = nsImage.tiffRepresentation {
                item.setData(tiffData, forType: .tiff)
            }

            pasteboard.writeObjects([item])
        } else {
            pasteboard.writeObjects([nsImage(from: image)])
        }
    }

    private func makePNGClipboardData(from image: CaptureImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image.cgImage)
        rep.size = image.size
        return rep.representation(using: .png, properties: [:])
    }

    private func nsImage(from image: CaptureImage) -> NSImage {
        let nsImage = NSImage(size: image.size)
        let rep = NSBitmapImageRep(cgImage: image.cgImage)
        rep.size = image.size
        nsImage.addRepresentation(rep)
        return nsImage
    }

    private func makeMarkdownImageReference(filePath: String) -> String? {
        let url = URL(fileURLWithPath: filePath)
        let alt = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "]", with: "")
            .replacingOccurrences(of: "[", with: "")
        let ref = url.absoluteString
        guard !ref.isEmpty else { return nil }
        return "![\(alt)](\(ref))"
    }
}
