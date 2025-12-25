import Foundation
import XCTest

@testable import PastScreen_CN

final class CaptureLibrarySearchSyntaxParserTests: XCTestCase {
    func testPinnedAppTagTypeAndRemainingText() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let now = Date(timeIntervalSince1970: 1_736_944_096) // 2025-01-15T12:34:56Z
        let context = CaptureLibrarySearchSyntaxParser.Context(
            appGroups: [
                CaptureLibraryAppGroup(bundleID: "com.apple.Safari", appName: "Safari", itemCount: 1)
            ],
            tagGroups: [
                CaptureLibraryTagGroup(name: "Work", itemCount: 1)
            ],
            now: now,
            calendar: calendar
        )

        var query = CaptureLibraryQuery.all
        let remaining = CaptureLibrarySearchSyntaxParser.apply(
            "pinned app:Safari tag:Work type:window hello world",
            to: &query,
            context: context
        )

        XCTAssertEqual(query.pinnedOnly, true)
        XCTAssertEqual(query.appBundleID, "com.apple.Safari")
        XCTAssertEqual(query.tag, "Work")
        XCTAssertEqual(query.captureType, .window)
        XCTAssertNil(query.createdAfter)
        XCTAssertNil(query.createdBefore)
        XCTAssertEqual(remaining, "hello world")
    }

    func testTodaySetsDayRange() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let now = Date(timeIntervalSince1970: 1_736_944_096) // 2025-01-15T12:34:56Z
        let context = CaptureLibrarySearchSyntaxParser.Context(
            appGroups: [],
            tagGroups: [],
            now: now,
            calendar: calendar
        )

        var query = CaptureLibraryQuery.all
        let remaining = CaptureLibrarySearchSyntaxParser.apply("today", to: &query, context: context)
        XCTAssertNil(remaining)

        let expectedStart = calendar.startOfDay(for: now)
        let expectedEnd = calendar.date(byAdding: .day, value: 1, to: expectedStart)!.addingTimeInterval(-0.001)

        XCTAssertEqual(query.createdAfter, expectedStart)
        XCTAssertNotNil(query.createdBefore)
        XCTAssertLessThan(abs(query.createdBefore!.timeIntervalSince(expectedEnd)), 0.01)
    }

    func testRelativeLast7Days() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let now = Date(timeIntervalSince1970: 1_736_944_096) // 2025-01-15T12:34:56Z
        let context = CaptureLibrarySearchSyntaxParser.Context(
            appGroups: [],
            tagGroups: [],
            now: now,
            calendar: calendar
        )

        var query = CaptureLibraryQuery.all
        let remaining = CaptureLibrarySearchSyntaxParser.apply("最近7天", to: &query, context: context)
        XCTAssertNil(remaining)

        let expected = now.addingTimeInterval(-7 * 24 * 60 * 60)
        XCTAssertNotNil(query.createdAfter)
        XCTAssertLessThan(abs(query.createdAfter!.timeIntervalSince(expected)), 0.5)
        XCTAssertNil(query.createdBefore)
    }
}

