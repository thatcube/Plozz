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

    func testFocusClearanceRequiresAComfortablyVisibleChip() {
        XCTAssertNil(SeriesSeasonRevealEdge.clippedEdge(
            frame: CGRect(x: 32, y: 0, width: 160, height: 60),
            viewportWidth: 600,
            clearance: 32
        ))
        XCTAssertEqual(
            SeriesSeasonRevealEdge.clippedEdge(
                frame: CGRect(x: 420, y: 0, width: 160, height: 60),
                viewportWidth: 600,
                clearance: 32
            ),
            .trailing
        )
    }

    func testRevealAnchorPlacesChipInsideFocusComfortMargin() {
        let viewportWidth: CGFloat = 600
        let targetWidth: CGFloat = 160
        let clearance: CGFloat = 32

        let trailing = SeriesSeasonRevealEdge.trailing.revealAnchor(
            targetWidth: targetWidth,
            viewportWidth: viewportWidth,
            clearance: clearance
        )
        let trailingMaxX = trailing.x * (viewportWidth - targetWidth) + targetWidth
        XCTAssertEqual(trailingMaxX, viewportWidth - clearance, accuracy: 0.001)

        let leading = SeriesSeasonRevealEdge.leading.revealAnchor(
            targetWidth: targetWidth,
            viewportWidth: viewportWidth,
            clearance: clearance
        )
        let leadingMinX = leading.x * (viewportWidth - targetWidth)
        XCTAssertEqual(leadingMinX, clearance, accuracy: 0.001)
    }
}

final class SeriesDetailBrowserPolicyTests: XCTestCase {
    func testLooseEpisodeBrowserRearmsWhenHeroRegainsFocus() {
        XCTAssertTrue(SeriesDetailBrowserPolicy.rearmsEpisodeRailOnHeroFocus(hasSeasons: false))
        XCTAssertFalse(SeriesDetailBrowserPolicy.rearmsEpisodeRailOnHeroFocus(hasSeasons: true))
    }

    func testCastRevealsOnlyWhenAnEmptyBrowserHasFinishedLoading() {
        XCTAssertFalse(SeriesDetailBrowserPolicy.revealsCastWithoutBrowser(
            childrenLoaded: false,
            hasSeasons: false,
            hasEpisodes: false
        ))
        XCTAssertFalse(SeriesDetailBrowserPolicy.revealsCastWithoutBrowser(
            childrenLoaded: true,
            hasSeasons: true,
            hasEpisodes: false
        ))
        XCTAssertFalse(SeriesDetailBrowserPolicy.revealsCastWithoutBrowser(
            childrenLoaded: true,
            hasSeasons: false,
            hasEpisodes: true
        ))
        XCTAssertTrue(SeriesDetailBrowserPolicy.revealsCastWithoutBrowser(
            childrenLoaded: true,
            hasSeasons: false,
            hasEpisodes: false
        ))
    }

    func testRequestAccessoryCannotStealInitialSeasonEntryFocus() {
        XCTAssertFalse(SeriesRequestFocusPolicy.accessoryEnabled(
            hasOwnedSeasons: true,
            seasonBarEngaged: false,
            hasRequestHandler: true
        ))
        XCTAssertTrue(SeriesRequestFocusPolicy.accessoryEnabled(
            hasOwnedSeasons: true,
            seasonBarEngaged: true,
            hasRequestHandler: true
        ))
        XCTAssertFalse(SeriesRequestFocusPolicy.accessoryEnabled(
            hasOwnedSeasons: true,
            seasonBarEngaged: true,
            hasRequestHandler: false
        ))
        XCTAssertTrue(SeriesRequestFocusPolicy.accessoryEnabled(
            hasOwnedSeasons: false,
            seasonBarEngaged: false,
            hasRequestHandler: true
        ))
    }

    func testRequestAccessoryCopyReflectsAvailableActions() {
        XCTAssertEqual(
            SeriesRequestAccessoryPresentation.title(hasRequestable: true, isRequesting: false),
            "Request More"
        )
        XCTAssertEqual(
            SeriesRequestAccessoryPresentation.title(hasRequestable: false, isRequesting: false),
            "Season Requests"
        )
        XCTAssertEqual(
            SeriesRequestAccessoryPresentation.title(hasRequestable: true, isRequesting: true),
            "Requesting…"
        )
    }

}
