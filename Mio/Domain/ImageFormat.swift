//
//  ImageFormat.swift
//  Mio
//
//  Image encoding format selected by the user. Domain-layer enum
//  because it is part of the cross-layer CaptureConfiguration
//  contract — both the producer (CaptureCoordinator/AppSettings)
//  and the consumer (FileOutputService) speak it directly, with
//  no String-typed detour.
//
//  Pure value type; no actor isolation required.
//

import Foundation
import AppKit

public enum ImageFormat: String, Codable, CaseIterable, Sendable {
    case png
    case jpeg

    /// File extension used when saving to disk. JPEG is canonically
    /// "jpg" on macOS to match Finder's default renderer behaviour.
    nonisolated public var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        }
    }

    /// `NSBitmapImageRep` filetype used by the file output writer.
    nonisolated public var nsBitmapFileType: NSBitmapImageRep.FileType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        }
    }

    /// Tolerant decoder for legacy UserDefaults strings. Accepts
    /// "png", "jpg", "jpeg" (case-insensitive). Returns nil otherwise.
    nonisolated public static func fromLegacyString(_ raw: String?) -> ImageFormat? {
        guard let raw else { return nil }
        switch raw.lowercased() {
        case "png": return .png
        case "jpg", "jpeg": return .jpeg
        default: return nil
        }
    }
}
