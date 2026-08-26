#if canImport(SwiftUI)
import XCTest
import CoreModels
@testable import CoreUI

final class PlozzMetricsTests: XCTestCase {
    func testStandardMatchesPlozzThemeConstants() {
        let m = PlozzMetrics(density: .standard)
        XCTAssertEqual(m.scale, 1.0)
        XCTAssertEqual(m.posterWidth, PlozzTheme.Metrics.posterWidth)
        XCTAssertEqual(m.landscapeWidth, PlozzTheme.Metrics.landscapeWidth)
        XCTAssertEqual(m.cardSpacing, PlozzTheme.Metrics.cardSpacing)
        XCTAssertEqual(m.gridSpacing, PlozzTheme.Metrics.gridSpacing)
        XCTAssertEqual(m.posterGridColumns, UIDensity.standard.posterGridColumns)
    }

    func testCompactShrinksAndExtraLargeGrows() {
        let compact = PlozzMetrics(density: .compact)
        let standard = PlozzMetrics(density: .standard)
        let extraLarge = PlozzMetrics(density: .extraLarge)

        XCTAssertLessThan(compact.posterWidth, standard.posterWidth)
        XCTAssertGreaterThan(extraLarge.posterWidth, standard.posterWidth)

        XCTAssertLessThan(compact.cardSpacing, standard.cardSpacing)
        XCTAssertGreaterThan(extraLarge.cardSpacing, standard.cardSpacing)

        // Fewer columns at higher density (bigger tiles); more at lower density.
        XCTAssertGreaterThan(compact.posterGridColumns, standard.posterGridColumns)
        XCTAssertLessThan(extraLarge.posterGridColumns, standard.posterGridColumns)
    }

    /// The caption only moves to stay clear of a growing card, so it has to move
    /// further in the style that grows further — and the outlined style must not
    /// budge from what it has always done.
    func testCaptionPushFollowsTheFocusStyle() {
        for density in UIDensity.allCases {
            let m = PlozzMetrics(density: density)
            XCTAssertEqual(m.focusCaptionPush(for: .outlined), m.focusCaptionPush)
            XCTAssertGreaterThan(
                m.focusCaptionPush(for: .highlight),
                m.focusCaptionPush(for: .outlined),
                "highlight grows further, so its caption has to clear further (\(density))"
            )
        }
    }

    func testPosterColumnsCountMatchesDensity() {
        for density in UIDensity.allCases {
            let m = PlozzMetrics(density: density)
            XCTAssertEqual(m.posterColumns.count, density.posterGridColumns)
        }
    }

    func testLandscapeSlotIncludesBothInsets() {
        let m = PlozzMetrics(density: .standard)
        XCTAssertEqual(m.landscapeCardSlotWidth, m.landscapeWidth + m.cardInset * 2)
    }

    func testCardSlotsExactlyMatchRenderedSurfaceWidths() {
        let metrics = PlozzMetrics.touch(density: .standard)

        XCTAssertEqual(
            metrics.cardSlotWidth(for: .poster, cardStyle: .framed),
            metrics.posterWidth + metrics.cardInset * 2
        )
        XCTAssertEqual(
            metrics.cardSlotWidth(for: .poster, cardStyle: .borderless),
            metrics.posterWidth + metrics.borderlessCardSideMargin * 2
        )
        XCTAssertEqual(
            metrics.cardSlotWidth(for: .landscape, cardStyle: .framed),
            metrics.landscapeWidth + metrics.cardInset * 2
        )
    }

    func testCardStatusCueScalesWithoutBecomingTooSmall() {
        let micro = PlozzMetrics(density: .micro)
        let standard = PlozzMetrics(density: .standard)
        let extraLarge = PlozzMetrics(density: .extraLarge)

        XCTAssertEqual(micro.cardStatusCueFontSize, PlozzTheme.Metrics.cardStatusCueMinFontSize)
        XCTAssertGreaterThan(extraLarge.cardStatusCueFontSize, standard.cardStatusCueFontSize)
        XCTAssertGreaterThanOrEqual(
            micro.cardStatusCueHorizontalPadding,
            PlozzTheme.Metrics.cardStatusCueMinHorizontalPadding
        )
        XCTAssertGreaterThanOrEqual(
            micro.cardStatusCueVerticalPadding,
            PlozzTheme.Metrics.cardStatusCueMinVerticalPadding
        )
    }
}
#endif
