//
//  CaptureClipboardFormat.swift
//  Mio
//
//  Clipboard payload format. Domain-layer enum because it is part of
//  the cross-layer CaptureConfiguration contract — both the producer
//  (CaptureCoordinator/AppSettings) and the consumer
//  (ClipboardOutputService) speak it directly, with no String detour.
//
//  Pure value type; no actor isolation required.
//

import Foundation

public enum CaptureClipboardFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case image = "image"
    case path = "path"
    case markdownImage = "markdownImage"

    public var id: String { rawValue }
}
