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

    func testPosterColumnsCountMatchesDensity() {
        for density in UIDensity.allCases {
            let m = PlozzMetrics(density: density)
            XCTAssertEqual(m.posterColumns.count, density.posterGridColumns)
        }
    }

    func testLandscapeSlotIncludesBothInsets() {
        let m = PlozzMetrics(density: .standard)
        XCTAssertEqual(m.landscapeCardSlotWidth, m.landscapeWidth + m.mediumCardInset * 2)
    }
}
#endif
