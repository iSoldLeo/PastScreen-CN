//
//  CaptureLibraryDatabaseMutations.swift
//  PastScreen
//

import Foundation
import SQLite3

extension CaptureLibraryDatabase {
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
        let normalized = CaptureLibraryTagNormalizer.normalize(tags)
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

    private static func normalizeOCRLangs(_ langs: [String]) -> String? {
        let normalized = AppSettings.normalizeOCRRecognitionLanguages(langs)
        let sorted = normalized.sorted()
        return sorted.isEmpty ? nil : sorted.joined(separator: " ")
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

        let ftsText = CaptureLibraryFTS.makeText(
            appName: appName,
            externalFilePath: externalFilePath,
            tagsCache: tagsCache,
            note: note,
            ocrText: ocrText
        )

        try upsertFTS(itemID: id.uuidString, text: ftsText)
    }
}

