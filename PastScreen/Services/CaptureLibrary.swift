//
//  CaptureLibrary.swift
//  PastScreen
//
//  Lightweight local capture library: metadata in SQLite + assets on disk.
//

import AppKit
import CryptoKit
import Foundation
import NaturalLanguage
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

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

    var bytesTotal: Int { bytesThumb + bytesPreview + bytesOriginal }

    static var empty: Self {
        CaptureLibraryStats(itemCount: 0, pinnedCount: 0, bytesThumb: 0, bytesPreview: 0, bytesOriginal: 0)
    }
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

// MARK: - File Store

struct CaptureLibraryFileStore {
    static let folderName = "CaptureLibrary"

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

// MARK: - Database

actor CaptureLibraryDatabase {
    private let dbURL: URL
    private var db: OpaquePointer?

    init(databaseURL: URL) throws {
        self.dbURL = databaseURL
        let handle = try Self.openDatabase(at: databaseURL)
        self.db = handle
        sqlite3_busy_timeout(handle, 2_000)
        try Self.configureDatabase(handle)
        try Self.migrateDatabase(handle)
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    func fetchRecent(limit: Int) throws -> [CaptureItem] {
        try fetchItems(
            sql: """
            SELECT
              id, created_at, updated_at,
              capture_type, capture_mode, trigger,
              app_bundle_id, app_name, app_pid,
              selection_w, selection_h,
              external_file_path,
              internal_thumb_path, internal_preview_path, internal_original_path,
              thumb_w, thumb_h, preview_w, preview_h,
              sha256,
              is_pinned, pinned_at,
              note, tags_cache,
              ocr_text, ocr_langs, ocr_updated_at,
              embedding_model, embedding_dim, embedding, embedding_source_hash, embedding_updated_at,
              bytes_thumb, bytes_preview, bytes_original
            FROM capture_items
            ORDER BY created_at DESC
            LIMIT ?
            """,
            bind: { stmt in
                sqlite3_bind_int(stmt, 1, Int32(limit))
            }
        )
    }

    func fetchPage(limit: Int, offset: Int) throws -> [CaptureItem] {
        try fetchItems(
            sql: """
            SELECT
              id, created_at, updated_at,
              capture_type, capture_mode, trigger,
              app_bundle_id, app_name, app_pid,
              selection_w, selection_h,
              external_file_path,
              internal_thumb_path, internal_preview_path, internal_original_path,
              thumb_w, thumb_h, preview_w, preview_h,
              sha256,
              is_pinned, pinned_at,
              note, tags_cache,
              ocr_text, ocr_langs, ocr_updated_at,
              embedding_model, embedding_dim, embedding, embedding_source_hash, embedding_updated_at,
              bytes_thumb, bytes_preview, bytes_original
            FROM capture_items
            ORDER BY created_at DESC
            LIMIT ? OFFSET ?
            """,
            bind: { stmt in
                sqlite3_bind_int(stmt, 1, Int32(limit))
                sqlite3_bind_int(stmt, 2, Int32(offset))
            }
        )
    }

    func fetchPage(limit: Int, offset: Int, query: CaptureLibraryQuery) throws -> [CaptureItem] {
        let trimmedSearch = query.searchText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedSearch.isEmpty {
            let matchQuery = Self.makeFTSMatchQuery(from: trimmedSearch)
            if !matchQuery.isEmpty {
                var whereClauses: [String] = ["capture_items_fts MATCH ?"]
                if query.pinnedOnly {
                    whereClauses.append("c.is_pinned = 1")
                }
                if query.captureType != nil {
                    whereClauses.append("c.capture_type = ?")
                }
                if query.appBundleID != nil {
                    whereClauses.append("c.app_bundle_id = ?")
                }
                if query.createdAfter != nil {
                    whereClauses.append("c.created_at >= ?")
                }
                if query.createdBefore != nil {
                    whereClauses.append("c.created_at <= ?")
                }
                if query.tag != nil {
                    whereClauses.append("""
                    EXISTS (
                      SELECT 1
                      FROM tags t
                      JOIN capture_item_tags cit ON t.id = cit.tag_id
                      WHERE cit.item_id = c.id AND t.name = ?
                    )
                    """)
                }

                let whereSQL = "WHERE " + whereClauses.joined(separator: " AND ")

                let orderSQL: String
                switch query.sort {
                case .relevance:
                    if query.pinnedOnly {
                        orderSQL = "ORDER BY bm25(capture_items_fts) ASC, c.pinned_at DESC, c.created_at DESC"
                    } else {
                        orderSQL = "ORDER BY bm25(capture_items_fts) ASC, c.created_at DESC"
                    }
                case .timeDesc:
                    if query.pinnedOnly {
                        orderSQL = "ORDER BY c.pinned_at DESC, c.created_at DESC"
                    } else {
                        orderSQL = "ORDER BY c.created_at DESC"
                    }
                }

                return try fetchItems(
                    sql: """
                    SELECT
                      c.id, c.created_at, c.updated_at,
                      c.capture_type, c.capture_mode, c.trigger,
                      c.app_bundle_id, c.app_name, c.app_pid,
                      c.selection_w, c.selection_h,
                      c.external_file_path,
                      c.internal_thumb_path, c.internal_preview_path, c.internal_original_path,
                      c.thumb_w, c.thumb_h, c.preview_w, c.preview_h,
                      c.sha256,
                      c.is_pinned, c.pinned_at,
                      c.note, c.tags_cache,
                      c.ocr_text, c.ocr_langs, c.ocr_updated_at,
                      c.embedding_model, c.embedding_dim, c.embedding, c.embedding_source_hash, c.embedding_updated_at,
                      c.bytes_thumb, c.bytes_preview, c.bytes_original
                    FROM capture_items c
                    JOIN capture_items_fts ON capture_items_fts.item_id = c.id
                    \(whereSQL)
                    \(orderSQL)
                    LIMIT ? OFFSET ?
                    """,
                    bind: { stmt in
                        var idx: Int32 = 1
                        bindText(stmt, index: idx, value: matchQuery)
                        idx += 1
                        if let captureType = query.captureType {
                            bindInt(stmt, index: idx, value: captureType.rawValue)
                            idx += 1
                        }
                        if let appBundleID = query.appBundleID {
                            bindText(stmt, index: idx, value: appBundleID)
                            idx += 1
                        }
                        if let createdAfter = query.createdAfter {
                            bindInt64(stmt, index: idx, value: Self.epochMillis(createdAfter))
                            idx += 1
                        }
                        if let createdBefore = query.createdBefore {
                            bindInt64(stmt, index: idx, value: Self.epochMillis(createdBefore))
                            idx += 1
                        }
                        if let tag = query.tag {
                            bindText(stmt, index: idx, value: tag)
                            idx += 1
                        }
                        sqlite3_bind_int(stmt, idx, Int32(limit))
                        sqlite3_bind_int(stmt, idx + 1, Int32(offset))
                    }
                )
            }
        }

        var whereClauses: [String] = []
        if query.pinnedOnly {
            whereClauses.append("is_pinned = 1")
        }
        if query.captureType != nil {
            whereClauses.append("capture_type = ?")
        }
        if query.appBundleID != nil {
            whereClauses.append("app_bundle_id = ?")
        }
        if query.createdAfter != nil {
            whereClauses.append("created_at >= ?")
        }
        if query.createdBefore != nil {
            whereClauses.append("created_at <= ?")
        }
        if query.tag != nil {
            whereClauses.append("""
            EXISTS (
              SELECT 1
              FROM tags t
              JOIN capture_item_tags cit ON t.id = cit.tag_id
              WHERE cit.item_id = capture_items.id AND t.name = ?
            )
            """)
        }

        let whereSQL: String
        if whereClauses.isEmpty {
            whereSQL = ""
        } else {
            whereSQL = "WHERE " + whereClauses.joined(separator: " AND ")
        }

        let orderSQL = query.pinnedOnly
            ? "ORDER BY pinned_at DESC, created_at DESC"
            : "ORDER BY created_at DESC"

        return try fetchItems(
            sql: """
            SELECT
              id, created_at, updated_at,
              capture_type, capture_mode, trigger,
              app_bundle_id, app_name, app_pid,
              selection_w, selection_h,
              external_file_path,
              internal_thumb_path, internal_preview_path, internal_original_path,
              thumb_w, thumb_h, preview_w, preview_h,
              sha256,
              is_pinned, pinned_at,
              note, tags_cache,
              ocr_text, ocr_langs, ocr_updated_at,
              embedding_model, embedding_dim, embedding, embedding_source_hash, embedding_updated_at,
              bytes_thumb, bytes_preview, bytes_original
            FROM capture_items
            \(whereSQL)
            \(orderSQL)
            LIMIT ? OFFSET ?
            """,
            bind: { stmt in
                var idx: Int32 = 1
                if let captureType = query.captureType {
                    bindInt(stmt, index: idx, value: captureType.rawValue)
                    idx += 1
                }
                if let appBundleID = query.appBundleID {
                    bindText(stmt, index: idx, value: appBundleID)
                    idx += 1
                }
                if let createdAfter = query.createdAfter {
                    bindInt64(stmt, index: idx, value: Self.epochMillis(createdAfter))
                    idx += 1
                }
                if let createdBefore = query.createdBefore {
                    bindInt64(stmt, index: idx, value: Self.epochMillis(createdBefore))
                    idx += 1
                }
                if let tag = query.tag {
                    bindText(stmt, index: idx, value: tag)
                    idx += 1
                }
                sqlite3_bind_int(stmt, idx, Int32(limit))
                sqlite3_bind_int(stmt, idx + 1, Int32(offset))
            }
        )
    }

    func fetchAppGroups() throws -> [CaptureLibraryAppGroup] {
        let sql = """
        SELECT
          app_bundle_id,
          COALESCE(MAX(app_name), '') AS app_name,
          COUNT(*) AS item_count
        FROM capture_items
        GROUP BY app_bundle_id
        ORDER BY item_count DESC
        """

        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        var groups: [CaptureLibraryAppGroup] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let bundleID = columnString(stmt, index: 0)
            let name = columnString(stmt, index: 1) ?? ""
            let count = Int(sqlite3_column_int(stmt, 2))
            groups.append(
                CaptureLibraryAppGroup(
                    bundleID: bundleID,
                    appName: name.isEmpty ? (bundleID ?? NSLocalizedString("library.app.unknown", value: "未知应用", comment: "")) : name,
                    itemCount: count
                )
            )
        }
        return groups
    }

    func fetchTagGroups() throws -> [CaptureLibraryTagGroup] {
        let sql = """
        SELECT
          t.name,
          COUNT(*) AS item_count
        FROM tags t
        JOIN capture_item_tags cit ON t.id = cit.tag_id
        JOIN capture_items c ON c.id = cit.item_id
        GROUP BY t.id
        ORDER BY item_count DESC, t.name ASC
        """

        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        var groups: [CaptureLibraryTagGroup] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = columnString(stmt, index: 0) ?? ""
            let count = Int(sqlite3_column_int(stmt, 1))
            if !name.isEmpty {
                groups.append(CaptureLibraryTagGroup(name: name, itemCount: count))
            }
        }
        return groups
    }

    func fetchOCRReindexCandidates(
        targetLangs: String,
        limit: Int,
        cursorCreatedAtMillis: Int64?,
        cursorID: String?
    ) throws -> [CaptureLibraryOCRReindexCandidate] {
        guard limit > 0 else { return [] }

        var whereClauses: [String] = [
            "ocr_text IS NOT NULL",
            "COALESCE(ocr_langs, '') != ?"
        ]

        let useCursor = cursorCreatedAtMillis != nil && cursorID != nil
        if useCursor {
            whereClauses.append("(created_at < ? OR (created_at = ? AND id < ?))")
        }

        let sql = """
        SELECT
          id,
          created_at,
          internal_thumb_path,
          internal_preview_path,
          internal_original_path,
          external_file_path,
          ocr_langs
        FROM capture_items
        WHERE \(whereClauses.joined(separator: " AND "))
        ORDER BY created_at DESC, id DESC
        LIMIT ?
        """

        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        var idx: Int32 = 1
        bindText(stmt, index: idx, value: targetLangs); idx += 1
        if useCursor, let cursorCreatedAtMillis, let cursorID {
            bindInt64(stmt, index: idx, value: cursorCreatedAtMillis); idx += 1
            bindInt64(stmt, index: idx, value: cursorCreatedAtMillis); idx += 1
            bindText(stmt, index: idx, value: cursorID); idx += 1
        }
        sqlite3_bind_int(stmt, idx, Int32(limit))

        var out: [CaptureLibraryOCRReindexCandidate] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard
                let idText = columnString(stmt, index: 0),
                let id = UUID(uuidString: idText)
            else {
                continue
            }
            let createdAtMillis = sqlite3_column_int64(stmt, 1)
            let thumbPath = columnString(stmt, index: 2) ?? ""
            let previewPath = columnString(stmt, index: 3)
            let originalPath = columnString(stmt, index: 4)
            let externalPath = columnString(stmt, index: 5)
            let ocrLangs = columnString(stmt, index: 6)

            out.append(
                CaptureLibraryOCRReindexCandidate(
                    id: id,
                    createdAtMillis: createdAtMillis,
                    internalThumbPath: thumbPath,
                    internalPreviewPath: previewPath,
                    internalOriginalPath: originalPath,
                    externalFilePath: externalPath,
                    ocrLangs: ocrLangs
                )
            )
        }

        return out
    }

    func fetchStats() throws -> CaptureLibraryStats {
        let sql = """
        SELECT
          COUNT(*) AS item_count,
          COALESCE(SUM(CASE WHEN is_pinned = 1 THEN 1 ELSE 0 END), 0) AS pinned_count,
          COALESCE(SUM(bytes_thumb), 0) AS bytes_thumb,
          COALESCE(SUM(bytes_preview), 0) AS bytes_preview,
          COALESCE(SUM(bytes_original), 0) AS bytes_original
        FROM capture_items
        """

        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return .empty }

        return CaptureLibraryStats(
            itemCount: Int(sqlite3_column_int(stmt, 0)),
            pinnedCount: Int(sqlite3_column_int(stmt, 1)),
            bytesThumb: Int(sqlite3_column_int(stmt, 2)),
            bytesPreview: Int(sqlite3_column_int(stmt, 3)),
            bytesOriginal: Int(sqlite3_column_int(stmt, 4))
        )
    }

    func fetchUnpinnedIDsCreatedBefore(_ createdAtMillis: Int64) throws -> [UUID] {
        let sql = """
        SELECT id
        FROM capture_items
        WHERE is_pinned = 0 AND created_at < ?
        ORDER BY created_at ASC
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, createdAtMillis)

        var ids: [UUID] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let idText = columnString(stmt, index: 0), let id = UUID(uuidString: idText) {
                ids.append(id)
            }
        }
        return ids
    }

    func fetchUnpinnedOldestIDs(limit: Int) throws -> [UUID] {
        guard limit > 0 else { return [] }
        let sql = """
        SELECT id
        FROM capture_items
        WHERE is_pinned = 0
        ORDER BY created_at ASC
        LIMIT ?
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))

        var ids: [UUID] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let idText = columnString(stmt, index: 0), let id = UUID(uuidString: idText) {
                ids.append(id)
            }
        }
        return ids
    }

    func fetchUnpinnedPreviewCandidates() throws -> [CaptureLibraryPreviewCandidate] {
        let sql = """
        SELECT id, internal_preview_path, bytes_preview
        FROM capture_items
        WHERE is_pinned = 0
          AND internal_preview_path IS NOT NULL
          AND bytes_preview > 0
        ORDER BY created_at ASC
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        var out: [CaptureLibraryPreviewCandidate] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard
                let idText = columnString(stmt, index: 0),
                let id = UUID(uuidString: idText),
                let path = columnString(stmt, index: 1)
            else {
                continue
            }
            let bytes = Int(sqlite3_column_int(stmt, 2))
            out.append(CaptureLibraryPreviewCandidate(id: id, previewPath: path, bytesPreview: bytes))
        }
        return out
    }

    func clearPreview(for id: UUID, now: Date) throws -> (previewPath: String?, freedBytes: Int) {
        let select = """
        SELECT internal_preview_path, bytes_preview
        FROM capture_items
        WHERE id = ?
        LIMIT 1
        """
        let selectStmt = try prepare(select)
        defer { sqlite3_finalize(selectStmt) }
        bindText(selectStmt, index: 1, value: id.uuidString)
        guard sqlite3_step(selectStmt) == SQLITE_ROW else {
            return (previewPath: nil, freedBytes: 0)
        }

        let previewPath = columnString(selectStmt, index: 0)
        let freedBytes = Int(sqlite3_column_int(selectStmt, 1))
        guard let previewPath, !previewPath.isEmpty, freedBytes > 0 else {
            return (previewPath: nil, freedBytes: 0)
        }

        let update = """
        UPDATE capture_items
        SET
          internal_preview_path = NULL,
          preview_w = NULL,
          preview_h = NULL,
          bytes_preview = 0,
          updated_at = ?
        WHERE id = ?
        """
        let updateStmt = try prepare(update)
        defer { sqlite3_finalize(updateStmt) }
        bindInt64(updateStmt, index: 1, value: Self.epochMillis(now))
        bindText(updateStmt, index: 2, value: id.uuidString)
        guard sqlite3_step(updateStmt) == SQLITE_DONE else {
            throw lastError("清理预览失败")
        }

        return (previewPath: previewPath, freedBytes: freedBytes)
    }

    func insertCapture(_ item: CaptureItem, ftsText: String) throws {
        let sql = """
        INSERT INTO capture_items (
          id, created_at, updated_at,
          capture_type, capture_mode, trigger,
          app_bundle_id, app_name, app_pid,
          selection_w, selection_h,
          external_file_path,
          internal_thumb_path, internal_preview_path, internal_original_path,
          thumb_w, thumb_h, preview_w, preview_h,
          sha256,
          is_pinned, pinned_at,
          note, tags_cache,
          ocr_text, ocr_langs, ocr_updated_at,
          embedding_model, embedding_dim, embedding, embedding_source_hash, embedding_updated_at,
          bytes_thumb, bytes_preview, bytes_original
        ) VALUES (
          ?, ?, ?,
          ?, ?, ?,
          ?, ?, ?,
          ?, ?,
          ?,
          ?, ?, ?,
          ?, ?, ?, ?,
          ?,
          ?, ?,
          ?, ?,
          ?, ?, ?,
          ?, ?, ?, ?, ?,
          ?, ?, ?
        )
        """

        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        var index: Int32 = 1
        bindText(stmt, index: index, value: item.id.uuidString); index += 1
        bindInt64(stmt, index: index, value: Self.epochMillis(item.createdAt)); index += 1
        bindInt64(stmt, index: index, value: Self.epochMillis(item.updatedAt)); index += 1

        bindInt(stmt, index: index, value: item.captureType.rawValue); index += 1
        bindInt(stmt, index: index, value: item.captureMode.rawValue); index += 1
        bindInt(stmt, index: index, value: item.trigger.rawValue); index += 1

        bindText(stmt, index: index, value: item.appBundleID); index += 1
        bindText(stmt, index: index, value: item.appName); index += 1
        bindInt(stmt, index: index, value: item.appPID); index += 1

        bindDouble(stmt, index: index, value: item.selectionSize.map { Double($0.width) }); index += 1
        bindDouble(stmt, index: index, value: item.selectionSize.map { Double($0.height) }); index += 1

        bindText(stmt, index: index, value: item.externalFilePath); index += 1

        bindText(stmt, index: index, value: item.internalThumbPath); index += 1
        bindText(stmt, index: index, value: item.internalPreviewPath); index += 1
        bindText(stmt, index: index, value: item.internalOriginalPath); index += 1

        bindInt(stmt, index: index, value: item.thumbSize.map { Int($0.width) }); index += 1
        bindInt(stmt, index: index, value: item.thumbSize.map { Int($0.height) }); index += 1
        bindInt(stmt, index: index, value: item.previewSize.map { Int($0.width) }); index += 1
        bindInt(stmt, index: index, value: item.previewSize.map { Int($0.height) }); index += 1

        bindText(stmt, index: index, value: item.sha256); index += 1

        bindInt(stmt, index: index, value: item.isPinned ? 1 : 0); index += 1
        bindInt64(stmt, index: index, value: item.pinnedAt.map(Self.epochMillis)); index += 1

        bindText(stmt, index: index, value: item.note); index += 1
        bindText(stmt, index: index, value: item.tagsCache); index += 1

        bindText(stmt, index: index, value: item.ocrText); index += 1
        bindText(stmt, index: index, value: Self.normalizeOCRLangs(item.ocrLangs)); index += 1
        bindInt64(stmt, index: index, value: item.ocrUpdatedAt.map(Self.epochMillis)); index += 1

        bindText(stmt, index: index, value: item.embeddingModel); index += 1
        bindInt(stmt, index: index, value: item.embeddingDim); index += 1
        bindBlob(stmt, index: index, value: item.embedding); index += 1
        bindText(stmt, index: index, value: item.embeddingSourceHash); index += 1
        bindInt64(stmt, index: index, value: item.embeddingUpdatedAt.map(Self.epochMillis)); index += 1

        bindInt(stmt, index: index, value: item.bytesThumb); index += 1
        bindInt(stmt, index: index, value: item.bytesPreview); index += 1
        bindInt(stmt, index: index, value: item.bytesOriginal); index += 1

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw lastError("插入 capture_items 失败")
        }

        try upsertFTS(itemID: item.id.uuidString, text: ftsText)
    }

    private static func normalizeOCRLangs(_ langs: [String]) -> String? {
        let normalized = AppSettings.normalizeOCRRecognitionLanguages(langs)
        let sorted = normalized.sorted()
        return sorted.isEmpty ? nil : sorted.joined(separator: " ")
    }

    func setPinned(_ pinned: Bool, for id: UUID, now: Date) throws {
        let sql = """
        UPDATE capture_items
        SET
          is_pinned = ?,
          pinned_at = ?,
          updated_at = ?
        WHERE id = ?
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, pinned ? 1 : 0)
        if pinned {
            bindInt64(stmt, index: 2, value: Self.epochMillis(now))
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        bindInt64(stmt, index: 3, value: Self.epochMillis(now))
        bindText(stmt, index: 4, value: id.uuidString)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw lastError("更新置顶状态失败")
        }
    }

    func updateExternalFilePath(for id: UUID, path: String?, now: Date) throws {
        let sql = """
        UPDATE capture_items
        SET
          external_file_path = ?,
          updated_at = ?
        WHERE id = ?
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, index: 1, value: path)
        bindInt64(stmt, index: 2, value: Self.epochMillis(now))
        bindText(stmt, index: 3, value: id.uuidString)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw lastError("更新 external_file_path 失败")
        }

        try rebuildFTS(for: id)
    }

    func updateNote(for id: UUID, note: String?, now: Date) throws {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty ?? true) ? nil : trimmed

        let sql = """
        UPDATE capture_items
        SET
          note = ?,
          updated_at = ?
        WHERE id = ?
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, index: 1, value: value)
        bindInt64(stmt, index: 2, value: Self.epochMillis(now))
        bindText(stmt, index: 3, value: id.uuidString)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw lastError("更新备注失败")
        }

        try rebuildFTS(for: id)
    }

    func updateOCR(for id: UUID, text: String, langs: [String], now: Date) throws {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        let normalizedLangs = Self.normalizeOCRLangs(langs)

        let sql = """
        UPDATE capture_items
        SET
          ocr_text = ?,
          ocr_langs = ?,
          ocr_updated_at = ?,
          updated_at = ?
        WHERE id = ?
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, index: 1, value: trimmedText)
        bindText(stmt, index: 2, value: normalizedLangs)
        bindInt64(stmt, index: 3, value: Self.epochMillis(now))
        bindInt64(stmt, index: 4, value: Self.epochMillis(now))
        bindText(stmt, index: 5, value: id.uuidString)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw lastError("更新 OCR 失败")
        }

        try rebuildFTS(for: id)
    }

    func updateOCRLangsOnly(for id: UUID, langs: [String], now: Date) throws {
        let normalizedLangs = Self.normalizeOCRLangs(langs)

        let sql = """
        UPDATE capture_items
        SET
          ocr_langs = ?,
          ocr_updated_at = ?,
          updated_at = ?
        WHERE id = ?
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, index: 1, value: normalizedLangs)
        bindInt64(stmt, index: 2, value: Self.epochMillis(now))
        bindInt64(stmt, index: 3, value: Self.epochMillis(now))
        bindText(stmt, index: 4, value: id.uuidString)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw lastError("更新 OCR 语言失败")
        }
    }

    func updateEmbedding(
        for id: UUID,
        model: String,
        dim: Int,
        embedding: Data,
        sourceHash: String,
        now: Date
    ) throws {
        let sql = """
        UPDATE capture_items
        SET
          embedding_model = ?,
          embedding_dim = ?,
          embedding = ?,
          embedding_source_hash = ?,
          embedding_updated_at = ?,
          updated_at = ?
        WHERE id = ?
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, index: 1, value: model)
        bindInt(stmt, index: 2, value: dim)
        bindBlob(stmt, index: 3, value: embedding)
        bindText(stmt, index: 4, value: sourceHash)
        bindInt64(stmt, index: 5, value: Self.epochMillis(now))
        bindInt64(stmt, index: 6, value: Self.epochMillis(now))
        bindText(stmt, index: 7, value: id.uuidString)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw lastError("更新 embedding 失败")
        }
    }

    func setTags(_ tags: [String], for id: UUID, now: Date) throws {
        let normalized = Self.normalizeTags(tags)
        let tagsCache = normalized.joined(separator: " ")

        do {
            try exec("BEGIN IMMEDIATE;")

            let updateItem = """
            UPDATE capture_items
            SET
              tags_cache = ?,
              updated_at = ?
            WHERE id = ?
            """
            let updateStmt = try prepare(updateItem)
            defer { sqlite3_finalize(updateStmt) }
            bindText(updateStmt, index: 1, value: tagsCache)
            bindInt64(updateStmt, index: 2, value: Self.epochMillis(now))
            bindText(updateStmt, index: 3, value: id.uuidString)
            guard sqlite3_step(updateStmt) == SQLITE_DONE else {
                throw lastError("更新标签失败")
            }

            let deleteSQL = "DELETE FROM capture_item_tags WHERE item_id = ?"
            let deleteStmt = try prepare(deleteSQL)
            defer { sqlite3_finalize(deleteStmt) }
            bindText(deleteStmt, index: 1, value: id.uuidString)
            guard sqlite3_step(deleteStmt) == SQLITE_DONE else {
                throw lastError("清理旧标签关联失败")
            }

            let insertTagSQL = "INSERT OR IGNORE INTO tags (name, created_at) VALUES (?, ?)"
            let insertTagStmt = try prepare(insertTagSQL)
            defer { sqlite3_finalize(insertTagStmt) }

            let selectTagIDSQL = "SELECT id FROM tags WHERE name = ? LIMIT 1"
            let selectTagIDStmt = try prepare(selectTagIDSQL)
            defer { sqlite3_finalize(selectTagIDStmt) }

            let insertMapSQL = "INSERT OR IGNORE INTO capture_item_tags (item_id, tag_id) VALUES (?, ?)"
            let insertMapStmt = try prepare(insertMapSQL)
            defer { sqlite3_finalize(insertMapStmt) }

            let nowMillis = Self.epochMillis(now)
            for tag in normalized {
                sqlite3_reset(insertTagStmt)
                sqlite3_clear_bindings(insertTagStmt)
                bindText(insertTagStmt, index: 1, value: tag)
                bindInt64(insertTagStmt, index: 2, value: nowMillis)
                guard sqlite3_step(insertTagStmt) == SQLITE_DONE else {
                    throw lastError("写入 tags 失败")
                }

                sqlite3_reset(selectTagIDStmt)
                sqlite3_clear_bindings(selectTagIDStmt)
                bindText(selectTagIDStmt, index: 1, value: tag)
                guard sqlite3_step(selectTagIDStmt) == SQLITE_ROW else {
                    continue
                }

                let tagID = sqlite3_column_int64(selectTagIDStmt, 0)
                guard tagID > 0 else { continue }

                sqlite3_reset(insertMapStmt)
                sqlite3_clear_bindings(insertMapStmt)
                bindText(insertMapStmt, index: 1, value: id.uuidString)
                sqlite3_bind_int64(insertMapStmt, 2, tagID)
                guard sqlite3_step(insertMapStmt) == SQLITE_DONE else {
                    throw lastError("写入标签关联失败")
                }
            }

            try rebuildFTS(for: id)

            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    private static func normalizeTags(_ tags: [String]) -> [String] {
        let trimmed = tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var unique: [String] = []
        var seen = Set<String>()
        for tag in trimmed where seen.insert(tag).inserted {
            unique.append(tag)
        }
        return Array(unique.prefix(20))
    }

    private func rebuildFTS(for id: UUID) throws {
        let sql = """
        SELECT app_name, external_file_path, tags_cache, note, ocr_text
        FROM capture_items
        WHERE id = ?
        LIMIT 1
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: id.uuidString)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return }

        let appName = columnString(stmt, index: 0)
        let externalFilePath = columnString(stmt, index: 1)
        let tagsCache = columnString(stmt, index: 2) ?? ""
        let note = columnString(stmt, index: 3)
        let ocrText = columnString(stmt, index: 4)

        let ftsText = Self.makeFTSText(
            appName: appName,
            externalFilePath: externalFilePath,
            tagsCache: tagsCache,
            note: note,
            ocrText: ocrText
        )

        try upsertFTS(itemID: id.uuidString, text: ftsText)
    }

private static func makeFTSText(
        appName: String?,
        externalFilePath: String?,
        tagsCache: String,
        note: String?,
        ocrText: String?
    ) -> String {
        var parts: [String] = []
        if let appName, !appName.isEmpty { parts.append(appName) }
        if !tagsCache.isEmpty { parts.append(tagsCache) }
        if let note, !note.isEmpty { parts.append(note) }
        if let ocrText, !ocrText.isEmpty { parts.append(ocrText) }
        if let externalFilePath, !externalFilePath.isEmpty {
            parts.append(URL(fileURLWithPath: externalFilePath).lastPathComponent)
        }
        return parts.joined(separator: "\n")
    }

    func deleteItems(ids: [UUID]) throws -> [(thumb: String, preview: String?, original: String?)] {
        guard !ids.isEmpty else { return [] }

        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let selectSQL = """
        SELECT internal_thumb_path, internal_preview_path, internal_original_path
        FROM capture_items
        WHERE id IN (\(placeholders))
        """

        let selectStmt = try prepare(selectSQL)
        defer { sqlite3_finalize(selectStmt) }
        for (i, id) in ids.enumerated() {
            bindText(selectStmt, index: Int32(i + 1), value: id.uuidString)
        }

        var paths: [(thumb: String, preview: String?, original: String?)] = []
        while sqlite3_step(selectStmt) == SQLITE_ROW {
            let thumb = columnString(selectStmt, index: 0) ?? ""
            let preview = columnString(selectStmt, index: 1)
            let original = columnString(selectStmt, index: 2)
            if !thumb.isEmpty {
                paths.append((thumb: thumb, preview: preview, original: original))
            }
        }

        try exec("BEGIN IMMEDIATE TRANSACTION")
        do {
            let deleteFTS = "DELETE FROM capture_items_fts WHERE item_id IN (\(placeholders))"
            let deleteFTSStmt = try prepare(deleteFTS)
            defer { sqlite3_finalize(deleteFTSStmt) }
            for (i, id) in ids.enumerated() {
                bindText(deleteFTSStmt, index: Int32(i + 1), value: id.uuidString)
            }
            guard sqlite3_step(deleteFTSStmt) == SQLITE_DONE else {
                throw lastError("删除 FTS 失败")
            }

            let deleteItems = "DELETE FROM capture_items WHERE id IN (\(placeholders))"
            let deleteStmt = try prepare(deleteItems)
            defer { sqlite3_finalize(deleteStmt) }
            for (i, id) in ids.enumerated() {
                bindText(deleteStmt, index: Int32(i + 1), value: id.uuidString)
            }
            guard sqlite3_step(deleteStmt) == SQLITE_DONE else {
                throw lastError("删除条目失败")
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }

        return paths
    }

    // MARK: - Private

    private static func openDatabase(at url: URL) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard result == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw NSError(domain: "CaptureLibraryDatabase", code: -10, userInfo: [NSLocalizedDescriptionKey: "无法打开数据库"])
        }
        return handle
    }

    private static func configureDatabase(_ db: OpaquePointer) throws {
        try exec("PRAGMA foreign_keys = ON;", db: db)
        _ = try? scalarString("PRAGMA journal_mode = WAL;", db: db)
        try exec("PRAGMA synchronous = NORMAL;", db: db)
    }

    private static func migrateDatabase(_ db: OpaquePointer) throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS schema_migrations (
          version      INTEGER PRIMARY KEY,
          applied_at   INTEGER NOT NULL
        );
        """, db: db)

        let applied = try fetchAppliedVersions(db: db)
        if !applied.contains(1) {
            try applyMigrationV1(db: db)
            try recordMigration(version: 1, db: db)
        }
    }

    private static func fetchAppliedVersions(db: OpaquePointer) throws -> Set<Int> {
        let stmt = try prepare("SELECT version FROM schema_migrations ORDER BY version ASC;", db: db)
        defer { sqlite3_finalize(stmt) }
        var out = Set<Int>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.insert(Int(sqlite3_column_int(stmt, 0)))
        }
        return out
    }

    private static func recordMigration(version: Int, db: OpaquePointer) throws {
        let sql = "INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?);"
        let stmt = try prepare(sql, db: db)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(version))
        sqlite3_bind_int64(stmt, 2, epochMillis(Date()))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw lastError("记录迁移失败", db: db)
        }
    }

    private static func applyMigrationV1(db: OpaquePointer) throws {
        try exec("""
        -- 0: area  1: window  2: fullscreen
        -- mode: 0 quick  1 advanced  2 ocr
        -- trigger: 0 menubar 1 hotkey 2 appIntent 3 automation
        CREATE TABLE IF NOT EXISTS capture_items (
          id                    TEXT PRIMARY KEY,
          created_at            INTEGER NOT NULL,
          updated_at            INTEGER NOT NULL,

          capture_type          INTEGER NOT NULL,
          capture_mode          INTEGER NOT NULL,
          trigger               INTEGER NOT NULL,

          app_bundle_id         TEXT,
          app_name              TEXT,
          app_pid               INTEGER,

          selection_w           REAL,
          selection_h           REAL,

          external_file_path    TEXT,

          internal_thumb_path   TEXT NOT NULL,
          internal_preview_path TEXT,
          internal_original_path TEXT,

          thumb_w               INTEGER,
          thumb_h               INTEGER,
          preview_w             INTEGER,
          preview_h             INTEGER,

          sha256                TEXT,

          is_pinned             INTEGER NOT NULL DEFAULT 0,
          pinned_at             INTEGER,

          note                  TEXT,
          tags_cache            TEXT NOT NULL DEFAULT '',

          ocr_text              TEXT,
          ocr_langs             TEXT,
          ocr_updated_at         INTEGER,

          embedding_model       TEXT,
          embedding_dim         INTEGER,
          embedding             BLOB,
          embedding_source_hash TEXT,
          embedding_updated_at  INTEGER,

          bytes_thumb           INTEGER NOT NULL DEFAULT 0,
          bytes_preview         INTEGER NOT NULL DEFAULT 0,
          bytes_original        INTEGER NOT NULL DEFAULT 0
        );

        CREATE INDEX IF NOT EXISTS idx_capture_items_created_at
          ON capture_items(created_at DESC);

        CREATE INDEX IF NOT EXISTS idx_capture_items_pinned
          ON capture_items(is_pinned DESC, pinned_at DESC, created_at DESC);

        CREATE INDEX IF NOT EXISTS idx_capture_items_app_created
          ON capture_items(app_bundle_id, created_at DESC);

        CREATE TABLE IF NOT EXISTS tags (
          id         INTEGER PRIMARY KEY AUTOINCREMENT,
          name       TEXT NOT NULL UNIQUE,
          created_at INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS capture_item_tags (
          item_id TEXT NOT NULL REFERENCES capture_items(id) ON DELETE CASCADE,
          tag_id  INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
          PRIMARY KEY (item_id, tag_id)
        );

        CREATE INDEX IF NOT EXISTS idx_capture_item_tags_tag
          ON capture_item_tags(tag_id);

        CREATE VIRTUAL TABLE IF NOT EXISTS capture_items_fts USING fts5(
          item_id UNINDEXED,
          text,
          tokenize='unicode61 remove_diacritics 2'
        );
        """, db: db)
    }

    private static func exec(_ sql: String, db: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<Int8>?
        defer { sqlite3_free(errorMessage) }
        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let msg = errorMessage.flatMap { String(cString: $0) } ?? "unknown"
            throw NSError(domain: "CaptureLibraryDatabase", code: -20, userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    private static func scalarString(_ sql: String, db: OpaquePointer) throws -> String? {
        let stmt = try prepare(sql, db: db)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return columnString(stmt, index: 0)
    }

    private static func prepare(_ sql: String, db: OpaquePointer) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw lastError("prepare 失败", db: db)
        }
        return stmt
    }

    private static func lastError(_ prefix: String, db: OpaquePointer) -> Error {
        let message = sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "unknown"
        return NSError(domain: "CaptureLibraryDatabase", code: -21, userInfo: [NSLocalizedDescriptionKey: "\(prefix)：\(message)"])
    }

    private static func columnString(_ stmt: OpaquePointer?, index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }

    private func upsertFTS(itemID: String, text: String) throws {
        try exec("DELETE FROM capture_items_fts WHERE item_id = \(sqlStringLiteral(itemID));")
        let stmt = try prepare("INSERT INTO capture_items_fts (item_id, text) VALUES (?, ?);")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: itemID)
        bindText(stmt, index: 2, value: text)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw lastError("写入 FTS 失败")
        }
    }

    private static func makeFTSMatchQuery(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let tokens = trimmed
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)

        let terms: [String] = tokens.compactMap { raw in
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { return nil }

            if term.range(of: #"^[A-Za-z0-9_]+$"#, options: .regularExpression) != nil {
                return term + "*"
            }

            if term.range(of: #"^[\p{L}\p{Nd}]+$"#, options: .regularExpression) != nil {
                // For CJK/other scripts: use prefix match so "微信" can match "微信支付".
                return term + "*"
            }

            let escaped = term.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }

        return terms.joined(separator: " AND ")
    }

    private func fetchItems(sql: String, bind: (OpaquePointer?) -> Void) throws -> [CaptureItem] {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bind(stmt)

        var items: [CaptureItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = UUID(uuidString: columnString(stmt, index: 0) ?? "") ?? UUID()
            let createdAt = Self.dateFromEpochMillis(columnInt64(stmt, index: 1) ?? 0) ?? Date()
            let updatedAt = Self.dateFromEpochMillis(columnInt64(stmt, index: 2) ?? 0) ?? createdAt

            let captureType = CaptureItemCaptureType(rawValue: Int(sqlite3_column_int(stmt, 3))) ?? .area
            let captureMode = CaptureItemCaptureMode(rawValue: Int(sqlite3_column_int(stmt, 4))) ?? .quick
            let trigger = CaptureItemTrigger(rawValue: Int(sqlite3_column_int(stmt, 5))) ?? .menuBar

            let appBundleID = columnString(stmt, index: 6)
            let appName = columnString(stmt, index: 7)
            let appPID = columnInt(stmt, index: 8)

            let selectionW = columnDouble(stmt, index: 9)
            let selectionH = columnDouble(stmt, index: 10)
            let selectionSize: CGSize? = {
                guard let selectionW, let selectionH, selectionW > 0, selectionH > 0 else { return nil }
                return CGSize(width: selectionW, height: selectionH)
            }()

            let externalFilePath = columnString(stmt, index: 11)

            let internalThumbPath = columnString(stmt, index: 12) ?? ""
            let internalPreviewPath = columnString(stmt, index: 13)
            let internalOriginalPath = columnString(stmt, index: 14)

            let thumbW = columnInt(stmt, index: 15).map(Double.init)
            let thumbH = columnInt(stmt, index: 16).map(Double.init)
            let previewW = columnInt(stmt, index: 17).map(Double.init)
            let previewH = columnInt(stmt, index: 18).map(Double.init)

            let thumbSize: CGSize? = {
                guard let thumbW, let thumbH, thumbW > 0, thumbH > 0 else { return nil }
                return CGSize(width: thumbW, height: thumbH)
            }()
            let previewSize: CGSize? = {
                guard let previewW, let previewH, previewW > 0, previewH > 0 else { return nil }
                return CGSize(width: previewW, height: previewH)
            }()

            let sha256 = columnString(stmt, index: 19)

            let isPinned = sqlite3_column_int(stmt, 20) != 0
            let pinnedAt = Self.dateFromEpochMillis(columnInt64(stmt, index: 21))

            let note = columnString(stmt, index: 22)
            let tagsCache = columnString(stmt, index: 23) ?? ""

            let ocrText = columnString(stmt, index: 24)
            let ocrLangsText = columnString(stmt, index: 25) ?? ""
            let ocrLangs = ocrLangsText.split(separator: " ").map(String.init)
            let ocrUpdatedAt = Self.dateFromEpochMillis(columnInt64(stmt, index: 26))

            let embeddingModel = columnString(stmt, index: 27)
            let embeddingDim = columnInt(stmt, index: 28)
            let embedding = columnBlob(stmt, index: 29)
            let embeddingSourceHash = columnString(stmt, index: 30)
            let embeddingUpdatedAt = Self.dateFromEpochMillis(columnInt64(stmt, index: 31))

            let bytesThumb = Int(sqlite3_column_int(stmt, 32))
            let bytesPreview = Int(sqlite3_column_int(stmt, 33))
            let bytesOriginal = Int(sqlite3_column_int(stmt, 34))

            items.append(
                CaptureItem(
                    id: id,
                    createdAt: createdAt,
                    updatedAt: updatedAt,
                    captureType: captureType,
                    captureMode: captureMode,
                    trigger: trigger,
                    appBundleID: appBundleID,
                    appName: appName,
                    appPID: appPID,
                    selectionSize: selectionSize,
                    externalFilePath: externalFilePath,
                    internalThumbPath: internalThumbPath,
                    internalPreviewPath: internalPreviewPath,
                    internalOriginalPath: internalOriginalPath,
                    thumbSize: thumbSize,
                    previewSize: previewSize,
                    sha256: sha256,
                    isPinned: isPinned,
                    pinnedAt: pinnedAt,
                    note: note,
                    tagsCache: tagsCache,
                    ocrText: ocrText,
                    ocrLangs: ocrLangs,
                    ocrUpdatedAt: ocrUpdatedAt,
                    embeddingModel: embeddingModel,
                    embeddingDim: embeddingDim,
                    embedding: embedding,
                    embeddingSourceHash: embeddingSourceHash,
                    embeddingUpdatedAt: embeddingUpdatedAt,
                    bytesThumb: bytesThumb,
                    bytesPreview: bytesPreview,
                    bytesOriginal: bytesOriginal
                )
            )
        }
        return items
    }

    private func exec(_ sql: String) throws {
        guard let db else {
            throw NSError(domain: "CaptureLibraryDatabase", code: -22, userInfo: [NSLocalizedDescriptionKey: "数据库未打开"])
        }
        var errorMessage: UnsafeMutablePointer<Int8>?
        defer { sqlite3_free(errorMessage) }
        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let msg = errorMessage.flatMap { String(cString: $0) } ?? "unknown"
            throw NSError(domain: "CaptureLibraryDatabase", code: -20, userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    private func scalarString(_ sql: String) throws -> String? {
        guard db != nil else { return nil }
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return columnString(stmt, index: 0)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        guard db != nil else {
            throw NSError(domain: "CaptureLibraryDatabase", code: -22, userInfo: [NSLocalizedDescriptionKey: "数据库未打开"])
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw lastError("prepare 失败")
        }
        return stmt
    }

    private func lastError(_ prefix: String) -> Error {
        let message = sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "unknown"
        return NSError(domain: "CaptureLibraryDatabase", code: -21, userInfo: [NSLocalizedDescriptionKey: "\(prefix)：\(message)"])
    }

    private static func epochMillis(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }

    private static func dateFromEpochMillis(_ value: Int64?) -> Date? {
        guard let value, value > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(value) / 1000.0)
    }

    private func sqlStringLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private func bindText(_ stmt: OpaquePointer?, index: Int32, value: String?) {
        guard let value else {
            sqlite3_bind_null(stmt, index)
            return
        }
        sqlite3_bind_text(stmt, index, value, -1, sqliteTransient)
    }

    private func bindInt64(_ stmt: OpaquePointer?, index: Int32, value: Int64?) {
        guard let value else {
            sqlite3_bind_null(stmt, index)
            return
        }
        sqlite3_bind_int64(stmt, index, value)
    }

    private func bindInt(_ stmt: OpaquePointer?, index: Int32, value: Int?) {
        guard let value else {
            sqlite3_bind_null(stmt, index)
            return
        }
        sqlite3_bind_int(stmt, index, Int32(value))
    }

    private func bindDouble(_ stmt: OpaquePointer?, index: Int32, value: Double?) {
        guard let value else {
            sqlite3_bind_null(stmt, index)
            return
        }
        sqlite3_bind_double(stmt, index, value)
    }

    private func bindBlob(_ stmt: OpaquePointer?, index: Int32, value: Data?) {
        guard let value else {
            sqlite3_bind_null(stmt, index)
            return
        }
        value.withUnsafeBytes { rawBuffer in
            sqlite3_bind_blob(stmt, index, rawBuffer.baseAddress, Int32(value.count), sqliteTransient)
        }
    }

    private func columnString(_ stmt: OpaquePointer?, index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }

    private func columnInt(_ stmt: OpaquePointer?, index: Int32) -> Int? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int(stmt, index))
    }

    private func columnInt64(_ stmt: OpaquePointer?, index: Int32) -> Int64? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(stmt, index)
    }

    private func columnDouble(_ stmt: OpaquePointer?, index: Int32) -> Double? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(stmt, index)
    }

    private func columnBlob(_ stmt: OpaquePointer?, index: Int32) -> Data? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        guard let bytes = sqlite3_column_blob(stmt, index) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, index))
        return Data(bytes: bytes, count: count)
    }
}

// MARK: - Library Service (async + non-blocking)

final class CaptureLibrary {
    static let shared = CaptureLibrary()

    private let worker = CaptureLibraryWorker()
    private let pendingLock = NSLock()
    private var pendingJobs: Int = 0
    private let maxPendingJobs: Int = 8
    private let indexingLock = NSLock()
    private var pendingIndexJobs: Int = 0
    private let maxPendingIndexJobs: Int = 2

    private init() {}

    func bootstrapIfNeeded() {
        guard AppSettings.shared.captureLibraryEnabled else { return }
        let legacyPaths = AppSettings.shared.captureHistory
        _ = enqueue(priority: .utility) { worker in
            try await worker.prepareIfNeeded()
            await worker.migrateLegacyHistoryIfNeeded(legacyPaths: legacyPaths)
        }
    }

    @discardableResult
    func addCapture(
        id: UUID = UUID(),
        cgImage: CGImage,
        pointSize: CGSize,
        captureType: CaptureItemCaptureType,
        captureMode: CaptureItemCaptureMode,
        trigger: CaptureItemTrigger,
        appBundleID: String?,
        appName: String?,
        appPID: Int?,
        externalFilePath: String?,
        ocrText: String? = nil,
        ocrLangs: [String] = []
    ) -> UUID? {
        guard AppSettings.shared.captureLibraryEnabled else { return nil }

        let storePreviews = AppSettings.shared.captureLibraryStorePreviews
        let autoOCR = AppSettings.shared.captureLibraryAutoOCR
        let autoOCRPreferredLanguages = AppSettings.shared.ocrRecognitionLanguages
        let createdAt = Date()

        let job = CaptureLibraryAddJob(
            id: id,
            createdAt: createdAt,
            captureType: captureType,
            captureMode: captureMode,
            trigger: trigger,
            appBundleID: appBundleID,
            appName: appName,
            appPID: appPID,
            selectionSize: pointSize,
            externalFilePath: externalFilePath,
            cgImage: cgImage,
            storePreview: storePreviews,
            ocrText: ocrText,
            ocrLangs: ocrLangs,
            autoOCR: autoOCR,
            autoOCRPreferredLanguages: autoOCRPreferredLanguages
        )

        let enqueued = enqueue(priority: .utility) { worker in
            try await worker.addCapture(job: job)
        }

        return enqueued ? id : nil
    }

    func updateExternalFilePath(for id: UUID, path: String?) {
        guard AppSettings.shared.captureLibraryEnabled else { return }
        _ = enqueue(priority: .utility) { worker in
            try await worker.updateExternalFilePath(for: id, path: path, now: Date())
        }
    }

    func fetchItems(query: CaptureLibraryQuery, limit: Int = 200, offset: Int = 0) async -> [CaptureItem] {
        guard AppSettings.shared.captureLibraryEnabled else { return [] }
        do {
            return try await worker.fetchItems(query: query, limit: limit, offset: offset)
        } catch {
            logError("CaptureLibrary fetchItems failed: \(error.localizedDescription)", category: "LIB")
            return []
        }
    }

    func fetchAppGroups() async -> [CaptureLibraryAppGroup] {
        guard AppSettings.shared.captureLibraryEnabled else { return [] }
        do {
            return try await worker.fetchAppGroups()
        } catch {
            logError("CaptureLibrary fetchAppGroups failed: \(error.localizedDescription)", category: "LIB")
            return []
        }
    }

    func fetchTagGroups() async -> [CaptureLibraryTagGroup] {
        guard AppSettings.shared.captureLibraryEnabled else { return [] }
        do {
            return try await worker.fetchTagGroups()
        } catch {
            logError("CaptureLibrary fetchTagGroups failed: \(error.localizedDescription)", category: "LIB")
            return []
        }
    }

    func setTags(_ tags: [String], for id: UUID) async {
        guard AppSettings.shared.captureLibraryEnabled else { return }
        do {
            try await worker.setTags(tags, for: id, now: Date())
        } catch {
            logError("CaptureLibrary setTags failed: \(error.localizedDescription)", category: "LIB")
        }
    }

    func updateNote(_ note: String?, for id: UUID) async {
        guard AppSettings.shared.captureLibraryEnabled else { return }
        do {
            try await worker.updateNote(for: id, note: note, now: Date())
        } catch {
            logError("CaptureLibrary updateNote failed: \(error.localizedDescription)", category: "LIB")
        }
    }

    func updateEmbedding(
        for id: UUID,
        model: String,
        dim: Int,
        embedding: Data,
        sourceHash: String
    ) async {
        guard AppSettings.shared.captureLibraryEnabled else { return }
        do {
            try await worker.updateEmbedding(for: id, model: model, dim: dim, embedding: embedding, sourceHash: sourceHash, now: Date())
        } catch {
            logError("CaptureLibrary updateEmbedding failed: \(error.localizedDescription)", category: "LIB")
        }
    }

    @discardableResult
    func requestOCR(for id: UUID, imageURL: URL, preferredLanguages: [String]) -> Bool {
        guard AppSettings.shared.captureLibraryEnabled else { return false }
        let path = imageURL.path
        let languages = preferredLanguages

        return enqueueIndexing(priority: .utility) { worker in
            guard FileManager.default.fileExists(atPath: path) else { return }
            let cgImage = OCRService.loadCGImage(from: imageURL)
                ?? NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            guard let cgImage else { return }

            let text = try await OCRService.recognizeText(
                in: cgImage,
                imageSize: CGSize(width: cgImage.width, height: cgImage.height),
                region: nil,
                preferredLanguages: languages.isEmpty ? nil : languages,
                qos: .utility
            )
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            try await worker.updateOCR(for: id, text: trimmed, langs: languages, now: Date(), notify: true)
        }
    }

    func fetchOCRReindexCandidates(
        targetLangs: String,
        limit: Int,
        cursorCreatedAtMillis: Int64?,
        cursorID: String?
    ) async -> [CaptureLibraryOCRReindexCandidate] {
        do {
            return try await worker.fetchOCRReindexCandidates(
                targetLangs: targetLangs,
                limit: limit,
                cursorCreatedAtMillis: cursorCreatedAtMillis,
                cursorID: cursorID
            )
        } catch {
            logError("CaptureLibrary fetchOCRReindexCandidates failed: \(error.localizedDescription)", category: "LIB")
            return []
        }
    }

    func updateOCRForReindex(for id: UUID, text: String, langs: [String], notify: Bool) async {
        do {
            try await worker.updateOCR(for: id, text: text, langs: langs, now: Date(), notify: notify)
        } catch {
            logError("CaptureLibrary updateOCRForReindex failed: \(error.localizedDescription)", category: "LIB")
        }
    }

    func updateOCRLangsForReindex(for id: UUID, langs: [String], notify: Bool) async {
        do {
            try await worker.updateOCRLangsOnly(for: id, langs: langs, now: Date(), notify: notify)
        } catch {
            logError("CaptureLibrary updateOCRLangsForReindex failed: \(error.localizedDescription)", category: "LIB")
        }
    }

    func setPinned(_ pinned: Bool, for id: UUID) async {
        guard AppSettings.shared.captureLibraryEnabled else { return }
        do {
            try await worker.setPinned(pinned, for: id, now: Date())
        } catch {
            logError("CaptureLibrary setPinned failed: \(error.localizedDescription)", category: "LIB")
        }
    }

    func deleteItems(ids: [UUID]) async {
        guard AppSettings.shared.captureLibraryEnabled else { return }
        do {
            try await worker.deleteItems(ids: ids)
        } catch {
            logError("CaptureLibrary deleteItems failed: \(error.localizedDescription)", category: "LIB")
        }
    }

    func fetchStats() async -> CaptureLibraryStats {
        guard AppSettings.shared.captureLibraryEnabled else { return .empty }
        do {
            return try await worker.fetchStats()
        } catch {
            logError("CaptureLibrary fetchStats failed: \(error.localizedDescription)", category: "LIB")
            return .empty
        }
    }

    func clearAll() async {
        guard AppSettings.shared.captureLibraryEnabled else { return }
        do {
            try await worker.clearAll()
        } catch {
            logError("CaptureLibrary clearAll failed: \(error.localizedDescription)", category: "LIB")
        }
    }

    func runCleanup(policy: CaptureLibraryCleanupPolicy) async -> CaptureLibraryStats {
        guard AppSettings.shared.captureLibraryEnabled else { return .empty }
        do {
            return try await worker.runCleanup(policy: policy, now: Date())
        } catch {
            logError("CaptureLibrary cleanup failed: \(error.localizedDescription)", category: "LIB")
            return .empty
        }
    }

    @MainActor
    func copyImageToClipboard(item: CaptureItem) {
        guard let result = bestImageURL(for: item, allowThumbnailFallback: true) else {
            DynamicIslandManager.shared.show(message: "无可复制图片", duration: 2.0, style: .failure)
            return
        }

        let url = result.url
        guard let image = NSImage(contentsOfFile: url.path) else {
            DynamicIslandManager.shared.show(message: "读取图片失败", duration: 2.0, style: .failure)
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        pasteboard.setString(url.path, forType: .string)

        if AppSettings.shared.playSoundOnCapture {
            NSSound(named: "Pop")?.play()
        }

        if result.isThumbnail {
            DynamicIslandManager.shared.show(message: "已复制（缩略图）", duration: 1.6)
        } else {
            DynamicIslandManager.shared.show(message: "已复制", duration: 1.5)
        }
    }

    @MainActor
    func copyPathToClipboard(item: CaptureItem) {
        guard let url = bestAnyURL(for: item) else {
            DynamicIslandManager.shared.show(message: "无可复制路径", duration: 2.0, style: .failure)
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.path, forType: .string)
        DynamicIslandManager.shared.show(message: "路径已复制", duration: 1.5)
    }

    @MainActor
    func revealInFinder(item: CaptureItem) {
        guard let url = bestAnyURL(for: item) else {
            DynamicIslandManager.shared.show(message: "找不到文件", duration: 2.0, style: .failure)
            return
        }
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
    }

    private func bestImageURL(for item: CaptureItem, allowThumbnailFallback: Bool) -> (url: URL, isThumbnail: Bool)? {
        if let url = bestAnyURL(for: item, requireCopyableImage: true) {
            return (url: url, isThumbnail: false)
        }
        guard allowThumbnailFallback else { return nil }
        guard let url = resolveInternalURL(item.internalThumbPath) else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return (url: url, isThumbnail: true)
    }

    private func bestAnyURL(for item: CaptureItem, requireCopyableImage: Bool = false) -> URL? {
        let candidates: [URL] = [
            resolveInternalURL(item.internalOriginalPath),
            resolveInternalURL(item.internalPreviewPath),
            item.externalFileURL,
            requireCopyableImage ? nil : resolveInternalURL(item.internalThumbPath)
        ].compactMap { $0 }

        let fileManager = FileManager.default
        for url in candidates where fileManager.fileExists(atPath: url.path) {
            return url
        }
        return nil
    }

    private func resolveInternalURL(_ relativePath: String?) -> URL? {
        guard let relativePath, !relativePath.isEmpty else { return nil }
        guard let root = try? CaptureLibraryFileStore.defaultRootURL() else { return nil }
        return root.appendingPathComponent(relativePath, isDirectory: false)
    }

    @discardableResult
    private func enqueue(
        priority: TaskPriority,
        operation: @escaping (CaptureLibraryWorker) async throws -> Void
    ) -> Bool {
        guard acquireJobSlot() else {
            logWarning("CaptureLibrary backlog full; drop job.", category: "LIB")
            return false
        }

        Task.detached(priority: priority) { [weak self] in
            defer { self?.releaseJobSlot() }
            do {
                try await operation(CaptureLibrary.shared.worker)
            } catch {
                logError("CaptureLibrary job failed: \(error.localizedDescription)", category: "LIB")
            }
        }

        return true
    }

    @discardableResult
    private func enqueueIndexing(
        priority: TaskPriority,
        operation: @escaping (CaptureLibraryWorker) async throws -> Void
    ) -> Bool {
        guard acquireIndexSlot() else {
            logWarning("CaptureLibrary indexing backlog full; drop job.", category: "LIB")
            return false
        }

        Task.detached(priority: priority) { [weak self] in
            defer { self?.releaseIndexSlot() }
            do {
                try await operation(CaptureLibrary.shared.worker)
            } catch {
                logError("CaptureLibrary indexing job failed: \(error.localizedDescription)", category: "LIB")
            }
        }

        return true
    }

    private func acquireJobSlot() -> Bool {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        if pendingJobs >= maxPendingJobs { return false }
        pendingJobs += 1
        return true
    }

    private func releaseJobSlot() {
        pendingLock.lock()
        pendingJobs = max(0, pendingJobs - 1)
        pendingLock.unlock()
    }

    private func acquireIndexSlot() -> Bool {
        indexingLock.lock()
        defer { indexingLock.unlock() }
        if pendingIndexJobs >= maxPendingIndexJobs { return false }
        pendingIndexJobs += 1
        return true
    }

    private func releaseIndexSlot() {
        indexingLock.lock()
        pendingIndexJobs = max(0, pendingIndexJobs - 1)
        indexingLock.unlock()
    }
}

fileprivate struct CaptureLibraryAddJob {
    let id: UUID
    let createdAt: Date

    let captureType: CaptureItemCaptureType
    let captureMode: CaptureItemCaptureMode
    let trigger: CaptureItemTrigger

    let appBundleID: String?
    let appName: String?
    let appPID: Int?
    let selectionSize: CGSize

    let externalFilePath: String?

    let cgImage: CGImage
    let storePreview: Bool

    let ocrText: String?
    let ocrLangs: [String]

    let autoOCR: Bool
    let autoOCRPreferredLanguages: [String]
}

actor CaptureLibraryWorker {
    private static let legacyMigrationKey = "captureLibrary.didMigrateLegacyHistory.v1"

    private var fileStore: CaptureLibraryFileStore?
    private var database: CaptureLibraryDatabase?

    private func notifyChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .captureLibraryChanged, object: nil)
        }
    }

    func prepareIfNeeded() throws {
        if fileStore == nil {
            let rootURL = try CaptureLibraryFileStore.defaultRootURL()
            fileStore = try CaptureLibraryFileStore(rootURL: rootURL)
        }
        if database == nil {
            guard let fileStore else {
                throw NSError(domain: "CaptureLibraryWorker", code: -1, userInfo: [NSLocalizedDescriptionKey: "FileStore 未初始化"])
            }
            database = try CaptureLibraryDatabase(databaseURL: fileStore.databaseURL)
        }
    }

    fileprivate func addCapture(job: CaptureLibraryAddJob) async throws {
        try prepareIfNeeded()
        guard let fileStore, let database else { return }

        let now = Date()

        let thumb = try fileStore.writeThumbnail(id: job.id, from: job.cgImage)
        let preview: (relativePath: String, pixelSize: CGSize, byteCount: Int)?
        if job.storePreview {
            preview = try fileStore.writePreview(id: job.id, from: job.cgImage)
        } else {
            preview = nil
        }

        let item = CaptureItem(
            id: job.id,
            createdAt: job.createdAt,
            updatedAt: now,
            captureType: job.captureType,
            captureMode: job.captureMode,
            trigger: job.trigger,
            appBundleID: job.appBundleID,
            appName: job.appName,
            appPID: job.appPID,
            selectionSize: job.selectionSize,
            externalFilePath: job.externalFilePath,
            internalThumbPath: thumb.relativePath,
            internalPreviewPath: preview?.relativePath,
            internalOriginalPath: nil,
            thumbSize: thumb.pixelSize,
            previewSize: preview?.pixelSize,
            sha256: nil,
            isPinned: false,
            pinnedAt: nil,
            note: nil,
            tagsCache: "",
            ocrText: job.ocrText,
            ocrLangs: job.ocrLangs,
            ocrUpdatedAt: job.ocrText == nil ? nil : now,
            embeddingModel: nil,
            embeddingDim: nil,
            embedding: nil,
            embeddingSourceHash: nil,
            embeddingUpdatedAt: nil,
            bytesThumb: thumb.byteCount,
            bytesPreview: preview?.byteCount ?? 0,
            bytesOriginal: 0
        )

        let ftsText = Self.makeFTSText(
            appName: item.appName,
            externalFilePath: item.externalFilePath,
            tagsCache: item.tagsCache,
            note: item.note,
            ocrText: item.ocrText
        )

        try await database.insertCapture(item, ftsText: ftsText)
        notifyChanged()

        if job.autoOCR {
            let existingOCR = job.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if existingOCR.isEmpty {
                do {
                    let text = try await OCRService.recognizeText(
                        in: job.cgImage,
                        imageSize: job.selectionSize,
                        region: nil,
                        preferredLanguages: job.autoOCRPreferredLanguages.isEmpty ? nil : job.autoOCRPreferredLanguages,
                        qos: .utility
                    )
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        try await database.updateOCR(for: job.id, text: trimmed, langs: job.autoOCRPreferredLanguages, now: Date())
                        notifyChanged()
                    }
                } catch {
                    logWarning("CaptureLibrary auto OCR failed: \(error.localizedDescription)", category: "LIB")
                }
            }
        }
    }

    func updateExternalFilePath(for id: UUID, path: String?, now: Date) async throws {
        try prepareIfNeeded()
        guard let database else { return }
        try await database.updateExternalFilePath(for: id, path: path, now: now)
        notifyChanged()
    }

    func fetchItems(query: CaptureLibraryQuery, limit: Int, offset: Int) async throws -> [CaptureItem] {
        try prepareIfNeeded()
        guard let database else { return [] }
        return try await database.fetchPage(limit: limit, offset: offset, query: query)
    }

    func fetchAppGroups() async throws -> [CaptureLibraryAppGroup] {
        try prepareIfNeeded()
        guard let database else { return [] }
        return try await database.fetchAppGroups()
    }

    func fetchTagGroups() async throws -> [CaptureLibraryTagGroup] {
        try prepareIfNeeded()
        guard let database else { return [] }
        return try await database.fetchTagGroups()
    }

    func fetchOCRReindexCandidates(
        targetLangs: String,
        limit: Int,
        cursorCreatedAtMillis: Int64?,
        cursorID: String?
    ) async throws -> [CaptureLibraryOCRReindexCandidate] {
        try prepareIfNeeded()
        guard let database else { return [] }
        return try await database.fetchOCRReindexCandidates(
            targetLangs: targetLangs,
            limit: limit,
            cursorCreatedAtMillis: cursorCreatedAtMillis,
            cursorID: cursorID
        )
    }

    func setTags(_ tags: [String], for id: UUID, now: Date) async throws {
        try prepareIfNeeded()
        guard let database else { return }
        try await database.setTags(tags, for: id, now: now)
        notifyChanged()
    }

    func updateNote(for id: UUID, note: String?, now: Date) async throws {
        try prepareIfNeeded()
        guard let database else { return }
        try await database.updateNote(for: id, note: note, now: now)
        notifyChanged()
    }

    func updateOCR(for id: UUID, text: String, langs: [String], now: Date, notify: Bool) async throws {
        try prepareIfNeeded()
        guard let database else { return }
        try await database.updateOCR(for: id, text: text, langs: langs, now: now)
        if notify { notifyChanged() }
    }

    func updateOCRLangsOnly(for id: UUID, langs: [String], now: Date, notify: Bool) async throws {
        try prepareIfNeeded()
        guard let database else { return }
        try await database.updateOCRLangsOnly(for: id, langs: langs, now: now)
        if notify { notifyChanged() }
    }

    func updateEmbedding(
        for id: UUID,
        model: String,
        dim: Int,
        embedding: Data,
        sourceHash: String,
        now: Date
    ) async throws {
        try prepareIfNeeded()
        guard let database else { return }
        try await database.updateEmbedding(for: id, model: model, dim: dim, embedding: embedding, sourceHash: sourceHash, now: now)
    }

    func setPinned(_ pinned: Bool, for id: UUID, now: Date) async throws {
        try prepareIfNeeded()
        guard let database else { return }
        try await database.setPinned(pinned, for: id, now: now)
        notifyChanged()
    }

    func deleteItems(ids: [UUID]) async throws {
        try await deleteItemsInternal(ids: ids, notify: true)
    }

    func fetchStats() async throws -> CaptureLibraryStats {
        try prepareIfNeeded()
        guard let database else { return .empty }
        return try await database.fetchStats()
    }

    func clearAll() async throws {
        try prepareIfNeeded()
        guard let fileStore else { return }

        database = nil
        self.fileStore = nil

        if FileManager.default.fileExists(atPath: fileStore.rootURL.path) {
            try FileManager.default.removeItem(at: fileStore.rootURL)
        }

        self.fileStore = try CaptureLibraryFileStore(rootURL: fileStore.rootURL)
        self.database = try CaptureLibraryDatabase(databaseURL: fileStore.databaseURL)
        notifyChanged()
    }

    func runCleanup(policy: CaptureLibraryCleanupPolicy, now: Date) async throws -> CaptureLibraryStats {
        try prepareIfNeeded()
        guard let database, let fileStore else { return .empty }

        var didChange = false
        var stats = try await database.fetchStats()

        let retentionDays = max(0, policy.retentionDays)
        if retentionDays > 0 {
            let cutoff = now.addingTimeInterval(TimeInterval(-retentionDays * 24 * 60 * 60))
            let cutoffMillis = Int64(cutoff.timeIntervalSince1970 * 1000)
            let oldIDs = try await database.fetchUnpinnedIDsCreatedBefore(cutoffMillis)
            if !oldIDs.isEmpty {
                try await deleteItemsInternal(ids: oldIDs, notify: false)
                didChange = true
                stats = try await database.fetchStats()
            }
        }

        let maxItems = max(0, policy.maxItems)
        if maxItems > 0, stats.itemCount > maxItems {
            let excess = stats.itemCount - maxItems
            let ids = try await database.fetchUnpinnedOldestIDs(limit: excess)
            if !ids.isEmpty {
                try await deleteItemsInternal(ids: ids, notify: false)
                didChange = true
                stats = try await database.fetchStats()
            }
        }

        let maxBytes = max(0, policy.maxBytes)
        if maxBytes > 0, stats.bytesTotal > maxBytes {
            let previewCandidates = try await database.fetchUnpinnedPreviewCandidates()
            for candidate in previewCandidates where stats.bytesTotal > maxBytes {
                let result = try await database.clearPreview(for: candidate.id, now: now)
                if let path = result.previewPath {
                    fileStore.deleteIfExists(relativePath: path)
                    stats.bytesPreview = max(0, stats.bytesPreview - result.freedBytes)
                    didChange = true
                }
            }

            if stats.bytesTotal > maxBytes {
                while stats.bytesTotal > maxBytes {
                    let ids = try await database.fetchUnpinnedOldestIDs(limit: 50)
                    if ids.isEmpty { break }
                    try await deleteItemsInternal(ids: ids, notify: false)
                    didChange = true
                    stats = try await database.fetchStats()
                }
            }
        }

        if didChange {
            notifyChanged()
        }

        return stats
    }

    private func deleteItemsInternal(ids: [UUID], notify: Bool) async throws {
        guard !ids.isEmpty else { return }
        try prepareIfNeeded()
        guard let database, let fileStore else { return }

        let paths = try await database.deleteItems(ids: ids)
        for path in paths {
            fileStore.deleteIfExists(relativePath: path.thumb)
            fileStore.deleteIfExists(relativePath: path.preview)
            fileStore.deleteIfExists(relativePath: path.original)
        }
        if notify {
            notifyChanged()
        }
    }

    func migrateLegacyHistoryIfNeeded(legacyPaths: [String]) async {
        guard !UserDefaults.standard.bool(forKey: Self.legacyMigrationKey) else { return }

        let paths = legacyPaths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !paths.isEmpty else {
            UserDefaults.standard.set(true, forKey: Self.legacyMigrationKey)
            return
        }

        do {
            try prepareIfNeeded()
        } catch {
            logError("Legacy history migration skipped: \(error.localizedDescription)", category: "LIB")
            return
        }

        guard let fileStore, let database else { return }

        for (index, path) in paths.enumerated() {
            do {
                let id = UUID()

                let fileURL = URL(fileURLWithPath: path)
                let createdAt = (try? FileManager.default.attributesOfItem(atPath: path)[.creationDate] as? Date)
                    ?? Date().addingTimeInterval(TimeInterval(-index * 5))

                let thumbResult: (relativePath: String, pixelSize: CGSize, byteCount: Int)
                if FileManager.default.fileExists(atPath: path),
                   let image = NSImage(contentsOfFile: path),
                   let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    thumbResult = try fileStore.writeThumbnail(id: id, from: cg)
                } else {
                    let data = try CaptureLibraryFileStore.makePlaceholderThumbnailData()
                    let relativePath = "thumbs/\(id.uuidString).jpg"
                    try data.write(to: fileStore.fileURL(forRelativePath: relativePath), options: .atomic)
                    thumbResult = (relativePath: relativePath, pixelSize: CGSize(width: 64, height: 64), byteCount: data.count)
                }

                let item = CaptureItem(
                    id: id,
                    createdAt: createdAt,
                    updatedAt: createdAt,
                    captureType: .area,
                    captureMode: .quick,
                    trigger: .menuBar,
                    appBundleID: nil,
                    appName: nil,
                    appPID: nil,
                    selectionSize: nil,
                    externalFilePath: path,
                    internalThumbPath: thumbResult.relativePath,
                    internalPreviewPath: nil,
                    internalOriginalPath: nil,
                    thumbSize: thumbResult.pixelSize,
                    previewSize: nil,
                    sha256: nil,
                    isPinned: false,
                    pinnedAt: nil,
                    note: nil,
                    tagsCache: "",
                    ocrText: nil,
                    ocrLangs: [],
                    ocrUpdatedAt: nil,
                    embeddingModel: nil,
                    embeddingDim: nil,
                    embedding: nil,
                    embeddingSourceHash: nil,
                    embeddingUpdatedAt: nil,
                    bytesThumb: thumbResult.byteCount,
                    bytesPreview: 0,
                    bytesOriginal: 0
                )

                let ftsText = Self.makeFTSText(
                    appName: nil,
                    externalFilePath: path,
                    tagsCache: "",
                    note: nil,
                    ocrText: nil
                )

                do {
                    try await database.insertCapture(item, ftsText: ftsText)
                } catch {
                    logWarning("Legacy history item insert failed: \(fileURL.lastPathComponent)", category: "LIB")
                }
            } catch {
                logWarning("Legacy history item skipped: \(path)", category: "LIB")
            }
        }

        UserDefaults.standard.set(true, forKey: Self.legacyMigrationKey)
        notifyChanged()
    }

    private static func makeFTSText(
        appName: String?,
        externalFilePath: String?,
        tagsCache: String,
        note: String?,
        ocrText: String?
    ) -> String {
        var parts: [String] = []
        if let appName, !appName.isEmpty { parts.append(appName) }
        if !tagsCache.isEmpty { parts.append(tagsCache) }
        if let note, !note.isEmpty { parts.append(note) }
        if let ocrText, !ocrText.isEmpty { parts.append(ocrText) }
        if let externalFilePath, !externalFilePath.isEmpty {
            parts.append(URL(fileURLWithPath: externalFilePath).lastPathComponent)
        }
        return parts.joined(separator: "\n")
    }
}

// MARK: - Semantic Search (M3, Experimental)

actor CaptureLibrarySemanticSearchService {
    static let shared = CaptureLibrarySemanticSearchService()

    private struct Config {
        var embedding: NLEmbedding
        var modelName: String
        var dim: Int
        var isSentence: Bool
        var language: NLLanguage
    }

    private var cachedConfigs: [String: Config] = [:]

    func rerank(items: [CaptureItem], queryText: String) async -> [CaptureItem] {
        let trimmedQuery = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty, items.count > 1 else { return items }

        guard let config = resolveConfig(for: trimmedQuery) else { return items }
        guard let queryVector = embed(text: trimmedQuery, config: config) else { return items }

        var scored: [(item: CaptureItem, index: Int, finalScore: Double)] = []
        scored.reserveCapacity(items.count)

        var updates: [(id: UUID, embedding: Data, sourceHash: String)] = []

        let n = max(1, items.count - 1)
        for (index, item) in items.enumerated() {
            let ftsScore = 1.0 - (Double(index) / Double(n))
            let semanticText = Self.semanticText(for: item)
            let sourceHash = Self.sha256Hex(semanticText)

            let itemVector: [Float]?
            if let existing = item.embedding,
               item.embeddingModel == config.modelName,
               item.embeddingDim == config.dim,
               item.embeddingSourceHash == sourceHash,
               let decoded = Self.decodeEmbedding(existing, dim: config.dim) {
                itemVector = decoded
            } else {
                itemVector = embed(text: semanticText, config: config)
                if let itemVector {
                    updates.append((id: item.id, embedding: Self.encodeEmbedding(itemVector), sourceHash: sourceHash))
                }
            }

            let semanticScore: Double
            if let itemVector {
                let cosine = Double(Self.dot(queryVector, itemVector))
                let normalized = min(1.0, max(0.0, (cosine + 1.0) / 2.0))
                semanticScore = normalized
            } else {
                semanticScore = 0
            }

            let finalScore = 0.6 * ftsScore + 0.4 * semanticScore
            scored.append((item: item, index: index, finalScore: finalScore))
        }

        let reranked = scored.sorted { lhs, rhs in
            if lhs.finalScore != rhs.finalScore { return lhs.finalScore > rhs.finalScore }
            if lhs.item.createdAt != rhs.item.createdAt { return lhs.item.createdAt > rhs.item.createdAt }
            return lhs.index < rhs.index
        }.map { $0.item }

        scheduleEmbeddingWrites(updates: updates, config: config)
        return reranked
    }

    private func resolveConfig(for query: String) -> Config? {
        let candidates = Self.preferredLanguages(for: query)

        for lang in candidates {
            let cacheKey = "sentence:\(lang.rawValue)"
            if let cached = cachedConfigs[cacheKey] {
                return cached
            }
            if let embedding = NLEmbedding.sentenceEmbedding(for: lang) {
                let config = Config(
                    embedding: embedding,
                    modelName: "nl_sentence_\(lang.rawValue)",
                    dim: embedding.dimension,
                    isSentence: true,
                    language: lang
                )
                cachedConfigs[cacheKey] = config
                return config
            }
        }

        for lang in candidates {
            let cacheKey = "word:\(lang.rawValue)"
            if let cached = cachedConfigs[cacheKey] {
                return cached
            }
            if let embedding = NLEmbedding.wordEmbedding(for: lang) {
                let config = Config(
                    embedding: embedding,
                    modelName: "nl_word_\(lang.rawValue)",
                    dim: embedding.dimension,
                    isSentence: false,
                    language: lang
                )
                cachedConfigs[cacheKey] = config
                return config
            }
        }

        return nil
    }

    private func embed(text: String, config: Config) -> [Float]? {
        if config.isSentence {
            guard let vec = config.embedding.vector(for: text) else { return nil }
            guard vec.count == config.dim else { return nil }
            let floats = vec.map { Float($0) }
            return Self.normalized(floats)
        }

        let tokens = Self.tokenize(text: text, maxTokens: 256)
        guard !tokens.isEmpty else { return nil }

        var sum = [Double](repeating: 0, count: config.dim)
        var count = 0

        for token in tokens {
            guard let vec = config.embedding.vector(for: token), vec.count == config.dim else { continue }
            for i in 0..<config.dim {
                sum[i] += vec[i]
            }
            count += 1
        }

        guard count > 0 else { return nil }

        var out = [Float](repeating: 0, count: config.dim)
        let inv = 1.0 / Double(count)
        for i in 0..<config.dim {
            out[i] = Float(sum[i] * inv)
        }

        return Self.normalized(out)
    }

    private func scheduleEmbeddingWrites(updates: [(id: UUID, embedding: Data, sourceHash: String)], config: Config) {
        guard !updates.isEmpty else { return }
        let limited = Array(updates.prefix(40))
        Task.detached(priority: .background) {
            for update in limited {
                await CaptureLibrary.shared.updateEmbedding(
                    for: update.id,
                    model: config.modelName,
                    dim: config.dim,
                    embedding: update.embedding,
                    sourceHash: update.sourceHash
                )
            }
        }
    }

    private static func preferredLanguages(for text: String) -> [NLLanguage] {
        var candidates: [NLLanguage] = []

        if let dominant = NLLanguageRecognizer.dominantLanguage(for: text) {
            candidates.append(dominant)
        }

        for identifier in Locale.preferredLanguages {
            let base = identifier.split(separator: "-").first.map(String.init) ?? identifier
            candidates.append(NLLanguage(rawValue: base))
        }

        candidates.append(.simplifiedChinese)
        candidates.append(.traditionalChinese)
        candidates.append(.english)

        var unique: [NLLanguage] = []
        var seen = Set<NLLanguage>()
        for language in candidates where seen.insert(language).inserted {
            unique.append(language)
        }
        return unique
    }

    private static func tokenize(text: String, maxTokens: Int) -> [String] {
        let lowered = text.lowercased()
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = lowered

        var out: [String] = []
        out.reserveCapacity(min(64, maxTokens))

        tokenizer.enumerateTokens(in: lowered.startIndex..<lowered.endIndex) { range, _ in
            if out.count >= maxTokens { return false }
            let token = String(lowered[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { return true }
            guard token.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }) else {
                return true
            }
            out.append(token)
            return true
        }

        return out
    }

    private static func semanticText(for item: CaptureItem) -> String {
        var parts: [String] = []
        if let appName = item.appName, !appName.isEmpty { parts.append(appName) }
        if !item.tagsCache.isEmpty { parts.append(item.tagsCache) }
        if let note = item.note, !note.isEmpty { parts.append(note) }
        if let ocr = item.ocrText, !ocr.isEmpty {
            parts.append(String(ocr.prefix(2_000)))
        }
        return parts.joined(separator: " ")
    }

    private static func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func encodeEmbedding(_ vector: [Float]) -> Data {
        var copy = vector
        return Data(bytes: &copy, count: copy.count * MemoryLayout<Float>.size)
    }

    private static func decodeEmbedding(_ data: Data, dim: Int) -> [Float]? {
        let expected = dim * MemoryLayout<Float>.size
        guard data.count == expected else { return nil }
        return data.withUnsafeBytes { rawBuffer in
            Array(rawBuffer.bindMemory(to: Float.self))
        }
    }

    private static func dot(_ a: [Float], _ b: [Float]) -> Float {
        let count = min(a.count, b.count)
        var sum: Float = 0
        for i in 0..<count {
            sum += a[i] * b[i]
        }
        return sum
    }

    private static func normalized(_ v: [Float]) -> [Float]? {
        var sum: Double = 0
        for x in v {
            sum += Double(x * x)
        }
        let norm = sqrt(sum)
        guard norm > 0 else { return nil }
        let inv = Float(1.0 / norm)
        return v.map { $0 * inv }
    }
}
