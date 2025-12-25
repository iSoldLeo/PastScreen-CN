//
//  CaptureLibraryDatabaseSchema.swift
//  PastScreen
//

import Foundation
import SQLite3

extension CaptureLibraryDatabase {
    static func migrateDatabase(_ db: OpaquePointer) throws {
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

    static func fetchAppliedVersions(db: OpaquePointer) throws -> Set<Int> {
        let stmt = try prepare("SELECT version FROM schema_migrations ORDER BY version ASC;", db: db)
        defer { sqlite3_finalize(stmt) }
        var out = Set<Int>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.insert(Int(sqlite3_column_int(stmt, 0)))
        }
        return out
    }

    static func recordMigration(version: Int, db: OpaquePointer) throws {
        let sql = "INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?);"
        let stmt = try prepare(sql, db: db)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(version))
        sqlite3_bind_int64(stmt, 2, epochMillis(Date()))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw lastError("记录迁移失败", db: db)
        }
    }

    static func applyMigrationV1(db: OpaquePointer) throws {
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
}

