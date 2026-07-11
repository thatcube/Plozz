import CoreGraphics
import XCTest
@testable import FeatureHome

final class SeriesSeasonRevealEdgeTests: XCTestCase {
    func testFullyVisibleChipDoesNotMoveTheSeasonBar() {
        XCTAssertNil(SeriesSeasonRevealEdge.clippedEdge(
            frame: CGRect(x: 20, y: 0, width: 160, height: 60),
            viewportWidth: 600
        ))
    }

    func testToleranceAvoidsSubpixelReveal() {
        XCTAssertNil(SeriesSeasonRevealEdge.clippedEdge(
            frame: CGRect(x: -0.4, y: 0, width: 600.8, height: 60),
            viewportWidth: 600
        ))
    }

    func testTrailingClippingRevealsToTrailingEdge() {
        XCTAssertEqual(
            SeriesSeasonRevealEdge.clippedEdge(
                frame: CGRect(x: 520, y: 0, width: 160, height: 60),
                viewportWidth: 600
            ),
            .trailing
        )
    }

    func testLeadingClippingRevealsToLeadingEdge() {
        XCTAssertEqual(
            SeriesSeasonRevealEdge.clippedEdge(
                frame: CGRect(x: -80, y: 0, width: 160, height: 60),
                viewportWidth: 600
            ),
            .leading
        )
    }

    func testMissingViewportDoesNotRequestReveal() {
        XCTAssertNil(SeriesSeasonRevealEdge.clippedEdge(
            frame: CGRect(x: 100, y: 0, width: 160, height: 60),
            viewportWidth: 0
        ))
    }
}
