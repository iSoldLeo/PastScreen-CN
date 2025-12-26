//
//  CaptureLibraryDatabase.swift
//  PastScreen
//

import CoreGraphics
import Foundation
import SQLite3

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

    // MARK: - Core (static)

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

    static func exec(_ sql: String, db: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<Int8>?
        defer { sqlite3_free(errorMessage) }
        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let msg = errorMessage.flatMap { String(cString: $0) } ?? "unknown"
            throw NSError(domain: "CaptureLibraryDatabase", code: -20, userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    static func scalarString(_ sql: String, db: OpaquePointer) throws -> String? {
        let stmt = try prepare(sql, db: db)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return columnString(stmt, index: 0)
    }

    static func prepare(_ sql: String, db: OpaquePointer) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw lastError("prepare 失败", db: db)
        }
        return stmt
    }

    static func lastError(_ prefix: String, db: OpaquePointer) -> Error {
        let message = sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "unknown"
        return NSError(domain: "CaptureLibraryDatabase", code: -21, userInfo: [NSLocalizedDescriptionKey: "\(prefix)：\(message)"])
    }

    static func columnString(_ stmt: OpaquePointer?, index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }

    static func epochMillis(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }

    static func dateFromEpochMillis(_ value: Int64?) -> Date? {
        guard let value, value > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(value) / 1000.0)
    }

    // MARK: - Core (instance)

    func exec(_ sql: String) throws {
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

    func scalarString(_ sql: String) throws -> String? {
        guard db != nil else { return nil }
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return columnString(stmt, index: 0)
    }

    func prepare(_ sql: String) throws -> OpaquePointer? {
        guard db != nil else {
            throw NSError(domain: "CaptureLibraryDatabase", code: -22, userInfo: [NSLocalizedDescriptionKey: "数据库未打开"])
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw lastError("prepare 失败")
        }
        return stmt
    }

    func lastError(_ prefix: String) -> Error {
        let message = sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "unknown"
        return NSError(domain: "CaptureLibraryDatabase", code: -21, userInfo: [NSLocalizedDescriptionKey: "\(prefix)：\(message)"])
    }

    func sqlStringLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    func bindText(_ stmt: OpaquePointer?, index: Int32, value: String?) {
        guard let value else {
            sqlite3_bind_null(stmt, index)
            return
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, index, value, -1, transient)
    }

    func bindInt64(_ stmt: OpaquePointer?, index: Int32, value: Int64?) {
        guard let value else {
            sqlite3_bind_null(stmt, index)
            return
        }
        sqlite3_bind_int64(stmt, index, value)
    }

    func bindInt(_ stmt: OpaquePointer?, index: Int32, value: Int?) {
        guard let value else {
            sqlite3_bind_null(stmt, index)
            return
        }
        sqlite3_bind_int(stmt, index, Int32(value))
    }

    func bindDouble(_ stmt: OpaquePointer?, index: Int32, value: Double?) {
        guard let value else {
            sqlite3_bind_null(stmt, index)
            return
        }
        sqlite3_bind_double(stmt, index, value)
    }

    func bindBlob(_ stmt: OpaquePointer?, index: Int32, value: Data?) {
        guard let value else {
            sqlite3_bind_null(stmt, index)
            return
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = value.withUnsafeBytes { rawBuffer in
            sqlite3_bind_blob(stmt, index, rawBuffer.baseAddress, Int32(value.count), transient)
        }
    }

    func columnString(_ stmt: OpaquePointer?, index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }

    func columnInt(_ stmt: OpaquePointer?, index: Int32) -> Int? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int(stmt, index))
    }

    func columnInt64(_ stmt: OpaquePointer?, index: Int32) -> Int64? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(stmt, index)
    }

    func columnDouble(_ stmt: OpaquePointer?, index: Int32) -> Double? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(stmt, index)
    }

    func columnBlob(_ stmt: OpaquePointer?, index: Int32) -> Data? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        guard let bytes = sqlite3_column_blob(stmt, index) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, index))
        return Data(bytes: bytes, count: count)
    }
}
