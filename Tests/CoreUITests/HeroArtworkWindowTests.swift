import XCTest
@testable import CoreUI

final class HeroArtworkWindowTests: XCTestCase {
    func testLargeCarouselWarmsOnlyFiveSlides() {
        XCTAssertEqual(
            HeroArtworkWindow.indices(count: 20, centeredAt: 10),
            [10, 11, 9, 12, 8]
        )
    }

    func testWindowWrapsAndDoesNotDuplicateSmallCarousels() {
        XCTAssertEqual(
            HeroArtworkWindow.indices(count: 3, centeredAt: 0),
            [0, 1, 2]
        )
    }
}

final class HeroPreviewWarmOrderTests: XCTestCase {
    func testLargeCarouselExpandsInBothPagingDirections() {
        XCTAssertEqual(
            Array(HeroPreviewWarmOrder.indices(count: 20, centeredAt: 10).prefix(7)),
            [10, 11, 9, 12, 8, 13, 7]
        )
    }

    func testWarmOrderWrapsAndIncludesEverySlideOnce() {
        let order = HeroPreviewWarmOrder.indices(count: 5, centeredAt: 0)

        XCTAssertEqual(order, [0, 1, 4, 2, 3])
        XCTAssertEqual(Set(order), Set(0..<5))
    }

    func testWarmOrderClampsOutOfRangeCenter() {
        XCTAssertEqual(
            HeroPreviewWarmOrder.indices(count: 3, centeredAt: 99),
            [2, 0, 1]
        )
    }
}
