import CoreModels
import XCTest
@testable import FeatureHomeCore

/// An empty curation looks identical whether the hero ran out of content or a
/// fetch failed, and the two demand opposite responses.
final class HeroEmptyCurationTests: XCTestCase {
    private func settings(_ sources: [HeroSourceKind]) -> HeroSettings {
        HeroSettings(
            isEnabled: true,
            sources: sources,
            maxItems: 8,
            trailersEnabled: false,
            hideWatched: true,
            randomLibraryKeys: [],
            autoAdvance: true,
            autoAdvanceSeconds: 12
        )
    }

    private func item(_ id: String) -> MediaItem {
        MediaItem(id: id, title: id, kind: .movie)
    }

    private let library = HeroRandomLibrary(
        accountID: "a",
        libraryID: "movies",
        kind: .movie
    )

    func testAPopulatedRowMeansAnEmptyCurationIsAFailure() {
        XCTAssertFalse(
            HeroEmptyCuration.isAuthoritative(
                settings: settings([.continueWatching]),
                continueWatching: [item("a")],
                watchlist: [],
                recentlyAdded: [],
                randomLibraries: []
            )
        )
    }

    func testOnlyEnabledSourcesCount() {
        // Continue Watching is full, but the hero doesn't draw from it.
        XCTAssertTrue(
            HeroEmptyCuration.isAuthoritative(
                settings: settings([.watchlist]),
                continueWatching: [item("a")],
                watchlist: [],
                recentlyAdded: [],
                randomLibraries: []
            )
        )
        XCTAssertFalse(
            HeroEmptyCuration.isAuthoritative(
                settings: settings([.watchlist]),
                continueWatching: [],
                watchlist: [item("a")],
                recentlyAdded: [],
                randomLibraries: []
            )
        )
    }

    func testAVisibleLibraryKeepsTheRandomSourceAlive() {
        XCTAssertFalse(
            HeroEmptyCuration.isAuthoritative(
                settings: settings([.randomFromLibrary]),
                continueWatching: [],
                watchlist: [],
                recentlyAdded: [],
                randomLibraries: [library]
            )
        )
        XCTAssertTrue(
            HeroEmptyCuration.isAuthoritative(
                settings: settings([.randomFromLibrary]),
                continueWatching: [],
                watchlist: [],
                recentlyAdded: [],
                randomLibraries: []
            )
        )
    }

    func testFeaturedAbstainsRatherThanVoting() {
        // Seerr answering nothing is ambiguous — unconfigured, offline, or
        // genuinely empty — so it neither keeps a dead carousel alive nor clears
        // a live one on its own.
        XCTAssertTrue(
            HeroEmptyCuration.isAuthoritative(
                settings: settings([.featured]),
                continueWatching: [],
                watchlist: [],
                recentlyAdded: [],
                randomLibraries: []
            )
        )
        XCTAssertFalse(
            HeroEmptyCuration.isAuthoritative(
                settings: settings([.featured, .continueWatching]),
                continueWatching: [item("a")],
                watchlist: [],
                recentlyAdded: [],
                randomLibraries: []
            )
        )
    }

    func testHidingEveryLibraryMakesAnEmptyCurationTheAnswer() {
        XCTAssertTrue(
            HeroEmptyCuration.isAuthoritative(
                settings: settings(HeroSourceKind.allCases),
                continueWatching: [],
                watchlist: [],
                recentlyAdded: [],
                randomLibraries: []
            )
        )
    }

    func testAnInactiveHeroIsAlwaysAuthoritative() {
        XCTAssertTrue(
            HeroEmptyCuration.isAuthoritative(
                settings: settings([]),
                continueWatching: [item("a")],
                watchlist: [],
                recentlyAdded: [],
                randomLibraries: []
            )
        )
    }
}
