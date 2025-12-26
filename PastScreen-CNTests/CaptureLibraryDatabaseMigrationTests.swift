import Foundation
import XCTest

@testable import PastScreen_CN

final class CaptureLibraryDatabaseMigrationTests: XCTestCase {
    func testMigrationCreatesTablesAndRecordsSchemaVersion() async throws {
        let fm = FileManager.default
        let url = fm.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")

        do {
            let db = try CaptureLibraryDatabase(databaseURL: url)
            let version = try await db.scalarString("SELECT MAX(version) FROM schema_migrations;")
            XCTAssertEqual(version, "1")

            let captureItems = try await db.scalarString("SELECT name FROM sqlite_master WHERE type='table' AND name='capture_items';")
            XCTAssertEqual(captureItems, "capture_items")

            let tags = try await db.scalarString("SELECT name FROM sqlite_master WHERE type='table' AND name='tags';")
            XCTAssertEqual(tags, "tags")

            let mapping = try await db.scalarString("SELECT name FROM sqlite_master WHERE type='table' AND name='capture_item_tags';")
            XCTAssertEqual(mapping, "capture_item_tags")

            let fts = try await db.scalarString("SELECT name FROM sqlite_master WHERE type='table' AND name='capture_items_fts';")
            XCTAssertEqual(fts, "capture_items_fts")
        }

        try? fm.removeItem(at: url)
    }
}

