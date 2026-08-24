//
//  ClipboardOutputService.swift
//  Mio
//
//  The sole NSPasteboard mutation boundary. Full-resolution encoding belongs
//  to OutputDeliveryService; this MainActor type only consumes immutable Data.
//

import AppKit
import Foundation

@MainActor
final class ClipboardOutputService: Sendable {
    func copy(png: Data?, tiff: Data?) -> ClipboardDeliveryOutcome {
        guard !Task.isCancelled else { return .cancelledBeforeAttempt }
        guard png != nil || tiff != nil else {
            return .failed(.noEncodableRepresentation)
        }

        let item = NSPasteboardItem()
        var acceptedRepresentationCount = 0
        if let png, item.setData(png, forType: .png) {
            acceptedRepresentationCount += 1
        }
        if let tiff, item.setData(tiff, forType: .tiff) {
            acceptedRepresentationCount += 1
        }
        guard acceptedRepresentationCount > 0 else {
            return .failed(.representationRejected)
        }
        guard !Task.isCancelled else { return .cancelledBeforeAttempt }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            return .failed(.writeRejected)
        }
        return .copied
    }
}
