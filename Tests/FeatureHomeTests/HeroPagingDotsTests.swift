import XCTest
@testable import FeatureHome

/// Locks down the hero paging-dots windowing (`HeroPagingDots.layout`): the cap,
/// the shrinking edge dots on sides with hidden content, the "hold the active dot
/// while the window scrolls" behaviour, and the ends where the edge dots grow back
/// to full so the active dot can reach the last slides.
final class HeroPagingDotsTests: XCTestCase {
    private typealias Size = HeroPagingDots.Size

    private func layout(count: Int, index: Int) -> [HeroPagingDots.Dot] {
        HeroPagingDots.layout(count: count, index: index, maxVisible: 8, edgeShrink: 2)
    }

    // MARK: - No windowing at or below the cap

    func testAtOrBelowCapShowsEveryDotFullSize() {
        for count in [1, 2, 5, 8] {
            let dots = layout(count: count, index: 0)
            XCTAssertEqual(dots.count, count, "count \(count): shows every dot")
            XCTAssertEqual(dots.map(\.index), Array(0..<count))
            XCTAssertTrue(dots.allSatisfy { $0.size == .full }, "count \(count): all full size")
        }
    }

    // MARK: - Windowing kicks in beyond the cap

    func testStartShowsFullLeadingDotsAndShrinksTrailingEdge() {
        // 20 slides, on the first: window [0...7], only the right edge is hidden.
        let dots = layout(count: 20, index: 0)
        XCTAssertEqual(dots.count, 8)
        XCTAssertEqual(dots.map(\.index), Array(0...7))
        // Leading six full, trailing two shrink (medium then small at the very edge).
        XCTAssertEqual(dots.map(\.size), [.full, .full, .full, .full, .full, .full, .medium, .small])
    }

    func testActiveIsHeldAtSlotFiveWhileScrollingThroughTheMiddle() {
        // Middle of a long list: both edges hidden, active held at slot 5.
        let dots = layout(count: 20, index: 10)
        XCTAssertEqual(dots.count, 8)
        // windowStart = clamp(10 - 5, 0, 12) = 5 → indices 5...12.
        XCTAssertEqual(dots.map(\.index), Array(5...12))
        // Both edges shrink: slots 0,1 (small, medium) and 6,7 (medium, small).
        XCTAssertEqual(dots.map(\.size), [.small, .medium, .full, .full, .full, .full, .medium, .small])
        // The active slide (index 10) is the 6th slot (slot 5) and full size.
        XCTAssertEqual(dots[5].index, 10)
        XCTAssertEqual(dots[5].size, .full)
    }

    func testEachAdvanceInTheMiddleScrollsTheWindowByOne() {
        let a = layout(count: 20, index: 8)
        let b = layout(count: 20, index: 9)
        XCTAssertEqual(a.first?.index, 3, "windowStart = 8 - 5 = 3")
        XCTAssertEqual(b.first?.index, 4, "advancing one scrolls the window by one")
        // The active dot stays pinned at slot 5 in both.
        XCTAssertEqual(a[5].index, 8)
        XCTAssertEqual(b[5].index, 9)
    }

    // MARK: - The ends: edge dots grow back and the active reaches them

    func testThirdFromLastIsWhereTheWindowStopsScrollingAndTrailingDotsGrow() {
        // count 20 → last index 19; 3rd-from-last = 17. windowStart clamps at 12.
        let dots = layout(count: 20, index: 17)
        XCTAssertEqual(dots.map(\.index), Array(12...19))
        // Nothing hidden on the right anymore → trailing two are full again; only the
        // left edge still shrinks.
        XCTAssertEqual(dots.map(\.size), [.small, .medium, .full, .full, .full, .full, .full, .full])
        // Active (17) sits at slot 5, with the last two slots (18, 19) now full.
        XCTAssertEqual(dots[5].index, 17)
        XCTAssertEqual(dots[6].size, .full)
        XCTAssertEqual(dots[7].size, .full)
    }

    func testLastTwoSlidesPutTheActiveDotInTheGrownEdgeSlots() {
        // Second-to-last.
        let penultimate = layout(count: 20, index: 18)
        XCTAssertEqual(penultimate.map(\.index), Array(12...19), "window stays clamped at the end")
        XCTAssertEqual(penultimate[6].index, 18)
        XCTAssertEqual(penultimate[6].size, .full, "active reaches slot 6 only at the end")

        // Last.
        let last = layout(count: 20, index: 19)
        XCTAssertEqual(last.map(\.index), Array(12...19))
        XCTAssertEqual(last[7].index, 19)
        XCTAssertEqual(last[7].size, .full, "active reaches the final slot only on the last slide")
    }

    // MARK: - Directionality of the shrink

    func testOnlyTheHiddenSideShrinks() {
        // Near the start (index 3): window still [0...7], nothing hidden left.
        let start = layout(count: 20, index: 3)
        XCTAssertEqual(start.first?.size, .full, "no hidden content left → leading dot full")
        XCTAssertEqual(start.last?.size, .small, "hidden content right → trailing edge shrinks")

        // Deep middle: both sides hidden → both shrink.
        let middle = layout(count: 20, index: 10)
        XCTAssertEqual(middle.first?.size, .small)
        XCTAssertEqual(middle.last?.size, .small)
    }

    func testExactlyOneOverCapWindowsCleanly() {
        // 9 slides: the smallest windowed case.
        let start = layout(count: 9, index: 0)
        XCTAssertEqual(start.map(\.index), Array(0...7))
        XCTAssertEqual(start.last?.size, .small, "the 9th slide is hidden → right edge shrinks")

        let end = layout(count: 9, index: 8)
        XCTAssertEqual(end.map(\.index), Array(1...8), "window scrolled by one to reveal the last slide")
        XCTAssertEqual(end.first?.size, .small, "now the 1st slide is hidden → left edge shrinks")
        XCTAssertEqual(end.last?.size, .full, "the last slide is full and active-reachable")
        XCTAssertEqual(end[7].index, 8)
    }

    // MARK: - Robustness

    func testAlwaysExactlyMaxVisibleWhenWindowed() {
        for index in 0..<20 {
            XCTAssertEqual(layout(count: 20, index: index).count, 8, "index \(index): always 8 dots")
        }
    }

    func testOutOfRangeIndexIsClamped() {
        XCTAssertEqual(layout(count: 20, index: -5).map(\.index), Array(0...7))
        XCTAssertEqual(layout(count: 20, index: 999).map(\.index), Array(12...19))
    }
}

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
