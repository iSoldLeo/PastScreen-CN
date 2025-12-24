//
//  CaptureLibrary.swift
//  PastScreen
//
//  Lightweight local capture library: metadata in SQLite + assets on disk.
//

import AppKit
import Foundation
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

// MARK: - File Store

struct CaptureLibraryFileStore {
    static let folderName = "CaptureLibrary"

    let rootURL: URL
    let databaseURL: URL
    let thumbsURL: URL
    let previewsURL: URL
    let originalsURL: URL

    init(rootURL: URL) throws {
        self.rootURL = rootURL
        self.databaseURL = rootURL.appendingPathComponent("library.sqlite3", isDirectory: false)
        self.thumbsURL = rootURL.appendingPathComponent("thumbs", isDirectory: true)
        self.previewsURL = rootURL.appendingPathComponent("previews", isDirectory: true)
        self.originalsURL = rootURL.appendingPathComponent("originals", isDirectory: true)

        try ensureDirectoriesExist()
    }

    static func defaultRootURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent(folderName, isDirectory: true)
    }

    func ensureDirectoriesExist() throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: thumbsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: previewsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: originalsURL, withIntermediateDirectories: true)
    }

    func fileURL(forRelativePath relativePath: String) -> URL {
        rootURL.appendingPathComponent(relativePath, isDirectory: false)
    }

    func deleteIfExists(relativePath: String?) {
        guard let relativePath, !relativePath.isEmpty else { return }
        let url = fileURL(forRelativePath: relativePath)
        try? FileManager.default.removeItem(at: url)
    }

    func writeThumbnail(
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

    func writePreview(
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

    static func makePlaceholderThumbnailData(size: CGSize = CGSize(width: 64, height: 64)) throws -> Data {
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

    private static func makeJPEGData(from image: CGImage, maxDimension: Int, quality: CGFloat) throws -> (Data, CGSize) {
        let scaled = try scaledImage(from: image, maxDimension: maxDimension)
        let rep = NSBitmapImageRep(cgImage: scaled)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) else {
            throw NSError(domain: "CaptureLibraryFileStore", code: -4, userInfo: [NSLocalizedDescriptionKey: "无法编码 JPEG"])
        }
        return (data, CGSize(width: scaled.width, height: scaled.height))
    }

    private static func scaledImage(from image: CGImage, maxDimension: Int) throws -> CGImage {
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
        bindText(stmt, index: index, value: item.ocrLangs.isEmpty ? nil : item.ocrLangs.joined(separator: " ")); index += 1
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
