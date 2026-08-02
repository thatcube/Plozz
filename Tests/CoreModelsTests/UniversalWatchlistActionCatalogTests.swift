import XCTest
@testable import CoreModels

final class UniversalWatchlistActionCatalogTests: XCTestCase {
    func testExplicitMembershipOverridesProviderFavorite() {
        let item = MediaItem(
            id: "m",
            title: "Movie",
            kind: .movie,
            isFavorite: true
        )
        let actions = MediaItemActionCatalog.actions(
            for: item,
            supportsWatchState: false,
            supportsWatchlist: false,
            isWatchlisted: false
        )
        XCTAssertTrue(actions.contains(.addToWatchlist))
        XCTAssertFalse(actions.contains(.removeFromWatchlist))
    }

    func testUniversalEligibilityIsExactlyMovieAndSeries() {
        for kind in MediaItemKind.allWatchlistTestCases {
            let item = MediaItem(id: "x", title: "X", kind: kind)
            let actions = MediaItemActionCatalog.actions(
                for: item,
                supportsWatchState: false,
                isWatchlisted: false
            )
            XCTAssertEqual(
                actions.contains(.addToWatchlist),
                kind == .movie || kind == .series
            )
        }
    }

    func testWatchlistActionsExposeExplicitAccessibilityState() {
        XCTAssertNotNil(MediaItemAction.addToWatchlist.accessibilityState)
        XCTAssertNotNil(MediaItemAction.removeFromWatchlist.accessibilityState)
    }
}

private extension MediaItemKind {
    static let allWatchlistTestCases: [MediaItemKind] = [
        .movie, .series, .video, .season, .episode, .folder, .collection,
        .unknown
    ]
}
