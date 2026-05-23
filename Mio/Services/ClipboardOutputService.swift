//
//  ClipboardOutputService.swift
//  Mio
//
//  @MainActor service for NSPasteboard operations.
//

import Foundation
// TODO: Remove @preconcurrency once Apple marks AppKit types as Sendable.
@preconcurrency import AppKit

@MainActor
public final class ClipboardOutputService: ClipboardWriting, Sendable {
    public init() {}

    /// Copy capture image to clipboard.
    public func copy(image: CaptureImage) async throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

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

    // MARK: - Private helpers

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
}
