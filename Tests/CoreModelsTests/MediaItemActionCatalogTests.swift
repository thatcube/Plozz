import XCTest
@testable import CoreModels

final class MediaItemActionCatalogTests: XCTestCase {
    private func item(
        id: String,
        kind: MediaItemKind,
        isPlayed: Bool = false,
        episodeNumber: Int? = nil
    ) -> MediaItem {
        MediaItem(id: id, title: id, kind: kind, episodeNumber: episodeNumber, isPlayed: isPlayed)
    }

    // MARK: - Capability gating

    func testNoActionsWhenWatchStateUnsupported() {
        let movie = item(id: "m", kind: .movie)
        XCTAssertTrue(MediaItemActionCatalog.actions(for: movie, supportsWatchState: false).isEmpty)
    }

    func testNoActionsForIneligibleKinds() {
        for kind in [MediaItemKind.folder, .collection, .unknown] {
            let it = item(id: "x", kind: kind)
            XCTAssertTrue(
                MediaItemActionCatalog.actions(for: it, supportsWatchState: true).isEmpty,
                "expected no actions for \(kind)"
            )
        }
    }

    // MARK: - Watched / unwatched toggle

    func testUnwatchedMovieOffersMarkWatched() {
        let movie = item(id: "m", kind: .movie, isPlayed: false)
        XCTAssertEqual(MediaItemActionCatalog.actions(for: movie, supportsWatchState: true), [.markWatched])
    }

    func testWatchedMovieOffersMarkUnwatched() {
        let movie = item(id: "m", kind: .movie, isPlayed: true)
        XCTAssertEqual(MediaItemActionCatalog.actions(for: movie, supportsWatchState: true), [.markUnwatched])
    }

    func testSeasonAndSeriesAreEligible() {
        for kind in [MediaItemKind.season, .series] {
            let it = item(id: "c", kind: kind, isPlayed: false)
            XCTAssertEqual(MediaItemActionCatalog.actions(for: it, supportsWatchState: true), [.markWatched])
        }
    }

    // MARK: - "Mark watched up to here"

    func testUpToHereOfferedWhenPrecedingSiblingUnwatched() {
        let e1 = item(id: "e1", kind: .episode, isPlayed: false, episodeNumber: 1)
        let e2 = item(id: "e2", kind: .episode, isPlayed: false, episodeNumber: 2)
        let context = MediaItemActionContext(orderedSiblings: [e1, e2])

        let actions = MediaItemActionCatalog.actions(for: e2, supportsWatchState: true, context: context)
        XCTAssertEqual(actions, [.markWatched, .markWatchedUpToHere])
    }

    func testUpToHereHiddenWhenNothingPrecedingUnwatched() {
        // Target is the first episode and already nothing earlier is unwatched.
        let e1 = item(id: "e1", kind: .episode, isPlayed: false, episodeNumber: 1)
        let context = MediaItemActionContext(orderedSiblings: [e1])

        let actions = MediaItemActionCatalog.actions(for: e1, supportsWatchState: true, context: context)
        XCTAssertEqual(actions, [.markWatched])
    }

    func testUpToHereOfferedWhenPrecedingContainerExistsEvenIfFirstInSeason() {
        let e1 = item(id: "e1", kind: .episode, isPlayed: true, episodeNumber: 1)
        let context = MediaItemActionContext(orderedSiblings: [e1], precedingContainerIDs: ["s1"])

        let actions = MediaItemActionCatalog.actions(for: e1, supportsWatchState: true, context: context)
        XCTAssertTrue(actions.contains(.markWatchedUpToHere))
    }

    func testUpToHereNotOfferedForMovies() {
        let movie = item(id: "m", kind: .movie)
        let other = item(id: "m2", kind: .movie)
        let context = MediaItemActionContext(orderedSiblings: [other, movie])
        XCTAssertFalse(
            MediaItemActionCatalog.actions(for: movie, supportsWatchState: true, context: context)
                .contains(.markWatchedUpToHere)
        )
    }

    // MARK: - siblingsToMarkUpToHere

    func testSiblingsToMarkUpToHereReturnsUnwatchedThroughTarget() {
        let e1 = item(id: "e1", kind: .episode, isPlayed: true, episodeNumber: 1)
        let e2 = item(id: "e2", kind: .episode, isPlayed: false, episodeNumber: 2)
        let e3 = item(id: "e3", kind: .episode, isPlayed: false, episodeNumber: 3)
        let e4 = item(id: "e4", kind: .episode, isPlayed: false, episodeNumber: 4)

        let result = MediaItemActionCatalog.siblingsToMarkUpToHere(e3, in: [e1, e2, e3, e4])
        XCTAssertEqual(result.map(\.id), ["e2", "e3"])
    }

    func testSiblingsToMarkUpToHereEmptyWhenTargetMissing() {
        let e1 = item(id: "e1", kind: .episode, episodeNumber: 1)
        let stray = item(id: "zz", kind: .episode, episodeNumber: 9)
        XCTAssertTrue(MediaItemActionCatalog.siblingsToMarkUpToHere(stray, in: [e1]).isEmpty)
    }
}
