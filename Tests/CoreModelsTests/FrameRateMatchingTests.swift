import XCTest
@testable import CoreModels

final class FrameRateMatchingTests: XCTestCase {

    // MARK: - Common real-world frame rates request a match

    func testCommonCinematicRatesMatch() {
        // 23.976 / 24 / 25 / 29.97 / 30 / 50 / 59.94 / 60 — all plausible sources.
        for fps in [23.976, 24.0, 25.0, 29.97, 30.0, 50.0, 59.94, 60.0] {
            let rate = FrameRateMatching.refreshRate(forSourceFrameRate: fps)
            XCTAssertNotNil(rate, "\(fps) should request a match")
            XCTAssertEqual(rate ?? 0, Float(fps), accuracy: 0.001)
            XCTAssertTrue(FrameRateMatching.shouldMatch(sourceFrameRate: fps))
        }
    }

    // MARK: - Unknown / implausible rates are a silent no-op

    func testNilFrameRateDoesNotMatch() {
        XCTAssertNil(FrameRateMatching.refreshRate(forSourceFrameRate: nil))
        XCTAssertFalse(FrameRateMatching.shouldMatch(sourceFrameRate: nil))
    }

    func testZeroAndNegativeDoNotMatch() {
        XCTAssertNil(FrameRateMatching.refreshRate(forSourceFrameRate: 0))
        XCTAssertNil(FrameRateMatching.refreshRate(forSourceFrameRate: -24))
        XCTAssertFalse(FrameRateMatching.shouldMatch(sourceFrameRate: 0))
    }

    func testBelowMinimumDoesNotMatch() {
        XCTAssertNil(FrameRateMatching.refreshRate(forSourceFrameRate: 0.5))
    }

    func testAboveMaximumDoesNotMatch() {
        XCTAssertNil(FrameRateMatching.refreshRate(forSourceFrameRate: 481))
        XCTAssertNil(FrameRateMatching.refreshRate(forSourceFrameRate: 100_000))
    }

    // MARK: - Window boundaries are inclusive

    func testBoundaryRatesMatch() {
        XCTAssertEqual(
            FrameRateMatching.refreshRate(forSourceFrameRate: FrameRateMatching.minFrameRate) ?? 0,
            Float(FrameRateMatching.minFrameRate), accuracy: 0.001)
        XCTAssertEqual(
            FrameRateMatching.refreshRate(forSourceFrameRate: FrameRateMatching.maxFrameRate) ?? 0,
            Float(FrameRateMatching.maxFrameRate), accuracy: 0.001)
    }
}
