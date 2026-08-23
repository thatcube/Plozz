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
                randomLibraries: [],
                seerConnected: false
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
                randomLibraries: [],
                seerConnected: false
            )
        )
        XCTAssertFalse(
            HeroEmptyCuration.isAuthoritative(
                settings: settings([.watchlist]),
                continueWatching: [],
                watchlist: [item("a")],
                recentlyAdded: [],
                randomLibraries: [],
                seerConnected: false
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
                randomLibraries: [library],
                seerConnected: false
            )
        )
        XCTAssertTrue(
            HeroEmptyCuration.isAuthoritative(
                settings: settings([.randomFromLibrary]),
                continueWatching: [],
                watchlist: [],
                recentlyAdded: [],
                randomLibraries: [],
                seerConnected: false
            )
        )
    }

    func testAConnectedSeerrBlocksAuthorityRatherThanGrantingIt() {
        // A Featured-only hero makes Seerr the ONLY vote, so treating its empty
        // answer as authoritative would let an outage blank the carousel.
        XCTAssertFalse(
            HeroEmptyCuration.isAuthoritative(
                settings: settings([.featured]),
                continueWatching: [],
                watchlist: [],
                recentlyAdded: [],
                randomLibraries: [],
                seerConnected: true
            )
        )
        XCTAssertFalse(
            HeroEmptyCuration.isAuthoritative(
                settings: settings(HeroSourceKind.allCases),
                continueWatching: [],
                watchlist: [],
                recentlyAdded: [],
                randomLibraries: [],
                seerConnected: true
            )
        )
    }

    func testAnUnconfiguredSeerrAbstainsSoTheOtherSourcesDecide() {
        // With no Seerr there is genuinely no pool, so it must not keep a hero
        // alive that every local source has stopped feeding.
        XCTAssertTrue(
            HeroEmptyCuration.isAuthoritative(
                settings: settings([.featured]),
                continueWatching: [],
                watchlist: [],
                recentlyAdded: [],
                randomLibraries: [],
                seerConnected: false
            )
        )
        XCTAssertFalse(
            HeroEmptyCuration.isAuthoritative(
                settings: settings([.featured, .continueWatching]),
                continueWatching: [item("a")],
                watchlist: [],
                recentlyAdded: [],
                randomLibraries: [],
                seerConnected: false
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
                randomLibraries: [],
                seerConnected: false
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
                randomLibraries: [],
                seerConnected: false
            )
        )
    }
}
