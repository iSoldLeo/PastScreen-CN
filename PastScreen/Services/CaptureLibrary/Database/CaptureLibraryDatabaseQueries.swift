//
//  CaptureLibraryDatabaseQueries.swift
//  PastScreen
//

import CoreGraphics
import Foundation
import SQLite3

extension CaptureLibraryDatabase {
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
            let matchQuery = CaptureLibraryFTS.makeMatchQuery(from: trimmedSearch)
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
}

