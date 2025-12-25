import XCTest

@testable import PastScreen_CN

final class CaptureLibraryTagNormalizerTests: XCTestCase {
    func testNormalizeTrimsDedupesAndCapsAt20() {
        let normalized = CaptureLibraryTagNormalizer.normalize(["  A", "A", "B", "", " ", "\nC\n", "B", "D"])
        XCTAssertEqual(normalized, ["A", "B", "C", "D"])

        let many = (1...25).map { "t\($0)" }
        let capped = CaptureLibraryTagNormalizer.normalize(many)
        XCTAssertEqual(capped.count, 20)
        XCTAssertEqual(capped.first, "t1")
        XCTAssertEqual(capped.last, "t20")
    }
}

