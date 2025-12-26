//
//  CaptureLibraryModels.swift
//  PastScreen
//

import CoreGraphics
import Foundation

// MARK: - Public Models

enum CaptureItemCaptureType: Int, Codable, CaseIterable {
    case area = 0
    case window = 1
    case fullscreen = 2
}

enum CaptureItemCaptureMode: Int, Codable, CaseIterable {
    case quick = 0
    case advanced = 1
    case ocr = 2
}

enum CaptureItemTrigger: Int, Codable, CaseIterable {
    case menuBar = 0
    case hotkey = 1
    case appIntent = 2
    case automation = 3
}

struct CaptureItem: Identifiable, Hashable {
    var id: UUID
    var createdAt: Date
    var updatedAt: Date

    var captureType: CaptureItemCaptureType
    var captureMode: CaptureItemCaptureMode
    var trigger: CaptureItemTrigger

    var appBundleID: String?
    var appName: String?
    var appPID: Int?

    var selectionSize: CGSize?

    var externalFilePath: String?
    var internalThumbPath: String
    var internalPreviewPath: String?
    var internalOriginalPath: String?

    var thumbSize: CGSize?
    var previewSize: CGSize?

    var sha256: String?

    var isPinned: Bool
    var pinnedAt: Date?

    var note: String?
    var tagsCache: String

    var ocrText: String?
    var ocrLangs: [String]
    var ocrUpdatedAt: Date?

    var embeddingModel: String?
    var embeddingDim: Int?
    var embedding: Data?
    var embeddingSourceHash: String?
    var embeddingUpdatedAt: Date?

    var bytesThumb: Int
    var bytesPreview: Int
    var bytesOriginal: Int
}

extension CaptureItem {
    var bytesTotal: Int { bytesThumb + bytesPreview + bytesOriginal }

    var externalFileURL: URL? {
        guard let externalFilePath, !externalFilePath.isEmpty else { return nil }
        return URL(fileURLWithPath: externalFilePath)
    }
}

struct CaptureLibraryAppGroup: Identifiable, Hashable {
    var id: String { bundleID ?? "__unknown__" }
    var bundleID: String?
    var appName: String
    var itemCount: Int
}

struct CaptureLibraryTagGroup: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var itemCount: Int
}

enum CaptureLibrarySort: Int, CaseIterable, Hashable {
    case timeDesc = 0
    case relevance = 1
}

struct CaptureLibraryQuery: Hashable {
    var appBundleID: String?
    var pinnedOnly: Bool
    var captureType: CaptureItemCaptureType?
    var createdAfter: Date?
    var createdBefore: Date?
    var tag: String?
    var searchText: String?
    var sort: CaptureLibrarySort

    static var all: Self {
        CaptureLibraryQuery(
            appBundleID: nil,
            pinnedOnly: false,
            captureType: nil,
            createdAfter: nil,
            createdBefore: nil,
            tag: nil,
            searchText: nil,
            sort: .timeDesc
        )
    }

    static var pinned: Self {
        CaptureLibraryQuery(
            appBundleID: nil,
            pinnedOnly: true,
            captureType: nil,
            createdAfter: nil,
            createdBefore: nil,
            tag: nil,
            searchText: nil,
            sort: .timeDesc
        )
    }
}

struct CaptureLibraryStats: Hashable {
    var itemCount: Int
    var pinnedCount: Int
    var bytesThumb: Int
    var bytesPreview: Int
    var bytesOriginal: Int

    nonisolated var bytesTotal: Int { bytesThumb + bytesPreview + bytesOriginal }

    nonisolated static let empty = CaptureLibraryStats(itemCount: 0, pinnedCount: 0, bytesThumb: 0, bytesPreview: 0, bytesOriginal: 0)
}

struct CaptureLibraryCleanupPolicy: Hashable {
    var retentionDays: Int
    var maxItems: Int
    var maxBytes: Int
}

struct CaptureLibraryPreviewCandidate: Hashable {
    var id: UUID
    var previewPath: String
    var bytesPreview: Int
}

struct CaptureLibraryOCRReindexCandidate: Hashable {
    var id: UUID
    var createdAtMillis: Int64
    var internalThumbPath: String
    var internalPreviewPath: String?
    var internalOriginalPath: String?
    var externalFilePath: String?
    var ocrLangs: String?
}
