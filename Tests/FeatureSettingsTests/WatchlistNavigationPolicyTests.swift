import XCTest
@testable import FeatureSettings

final class WatchlistNavigationPolicyTests: XCTestCase {
    private enum Destination {
        case home
        case watchlist
        case search
    }

    func testHiddenSelectedWatchlistFallsBackToHome() {
        XCTAssertEqual(
            WatchlistNavigationPolicy.resolvedSelection(
                Destination.watchlist,
                watchlist: Destination.watchlist,
                home: Destination.home,
                showsWatchlist: false
            ),
            Destination.home
        )
    }

    func testVisibleWatchlistAndRequiredDestinationsRemainSelected() {
        XCTAssertEqual(
            WatchlistNavigationPolicy.resolvedSelection(
                Destination.watchlist,
                watchlist: Destination.watchlist,
                home: Destination.home,
                showsWatchlist: true
            ),
            Destination.watchlist
        )
        XCTAssertEqual(
            WatchlistNavigationPolicy.resolvedSelection(
                Destination.search,
                watchlist: Destination.watchlist,
                home: Destination.home,
                showsWatchlist: false
            ),
            Destination.search
        )
    }
}
