import XCTest
@testable import FeatureHome

/// Locks down the pure bounded ±2 wraparound window the hero foreground
/// rasterizer prepares: paging-priority order, de-duplication, wraparound at the
/// ends, and the degenerate 0/1/2-slide carousels.
final class HeroRasterWindowTests: XCTestCase {
    private func window(count: Int, index: Int, radius: Int = 2) -> [Int] {
        HeroRasterWindow.indices(count: count, centeredAt: index, radius: radius)
    }

    // MARK: - Degenerate carousels

    func testZeroItemsIsEmpty() {
        XCTAssertEqual(window(count: 0, index: 0), [])
    }

    func testSingleItemIsJustZero() {
        XCTAssertEqual(window(count: 1, index: 0), [0])
    }

    func testTwoItemsYieldBothDistinctOnce() {
        // ±2 around a 2-slide carousel must not repeat slides.
        XCTAssertEqual(Set(window(count: 2, index: 0)), [0, 1])
        XCTAssertEqual(window(count: 2, index: 0).count, 2, "no duplicate slides")
        XCTAssertEqual(Set(window(count: 2, index: 1)), [0, 1])
        XCTAssertEqual(window(count: 2, index: 1).count, 2)
    }

    // MARK: - Interior order + priority

    func testInteriorPagingPriorityOrder() {
        // Center first, then next/previous, then the ±2 ring — so the very next
        // press in either direction is prepared first.
        XCTAssertEqual(window(count: 20, index: 10), [10, 11, 9, 12, 8])
    }

    func testFivePlusItemsAlwaysFillFiveSlots() {
        for count in [5, 6, 10, 20] {
            XCTAssertEqual(window(count: count, index: 0).count, 5, "count \(count) fills the ±2 window")
        }
    }

    // MARK: - Wraparound at the ends

    func testWrapsAtStart() {
        // On slide 0 of 20, -1 wraps to 19 and -2 to 18.
        XCTAssertEqual(window(count: 20, index: 0), [0, 1, 19, 2, 18])
    }

    func testWrapsAtEnd() {
        // On the last slide, +1 wraps to 0 and +2 to 1.
        XCTAssertEqual(window(count: 20, index: 19), [19, 0, 18, 1, 17])
    }

    func testThreeAndFourItemsDedupWraparound() {
        // count 3: center 0 → 0,1,2 (+2 and -1 collide; -2 and +1 collide).
        XCTAssertEqual(Set(window(count: 3, index: 0)), [0, 1, 2])
        XCTAssertEqual(window(count: 3, index: 0).count, 3)
        // count 4: center 0 → 0,1,3,2 (+2 and -2 collide on slide 2).
        XCTAssertEqual(Set(window(count: 4, index: 0)), [0, 1, 2, 3])
        XCTAssertEqual(window(count: 4, index: 0).count, 4)
    }

    // MARK: - Radius

    func testRadiusZeroIsCurrentOnly() {
        XCTAssertEqual(window(count: 20, index: 7, radius: 0), [7])
    }

    func testRadiusOneIsThreeSlots() {
        XCTAssertEqual(window(count: 20, index: 7, radius: 1), [7, 8, 6])
    }

    func testNegativeRadiusClampsToCurrentOnly() {
        XCTAssertEqual(window(count: 20, index: 7, radius: -3), [7])
    }

    // MARK: - Clamping an out-of-range fronted index

    func testOutOfRangeIndexClampsIntoRange() {
        XCTAssertEqual(window(count: 5, index: 99), window(count: 5, index: 4))
        XCTAssertEqual(window(count: 5, index: -3), window(count: 5, index: 0))
    }
}
