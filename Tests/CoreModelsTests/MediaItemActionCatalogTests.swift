import XCTest
@testable import CoreModels

final class MediaItemActionCatalogTests: XCTestCase {
    /// "Episode Info" is offered for every episode, wherever it is shown —
    /// including inside its own season's list, unlike the other navigation
    /// actions. The series page shows one episode at a time and episode cards stay
    /// deliberately sparse, so the rail is exactly where someone needs to inspect a
    /// different episode's file before playing it.
    func testEpisodeInfoOfferedForEveryEpisodeIncludingInsideItsOwnList() {
        let episode = item(id: "e2", kind: .episode, episodeNumber: 2, seasonID: "s1")
        let inOwnList = MediaItemActionCatalog.actions(
            for: episode,
            supportsWatchState: false,
            context: MediaItemActionContext(orderedSiblings: [episode])
        )
        XCTAssertTrue(inOwnList.contains(.goToEpisode))
        XCTAssertFalse(
            inOwnList.contains(.goToSeason),
            "Go to Season stays suppressed inside its own list — it would be a no-op"
        )
    }

    func testEpisodeInfoNotOfferedForMoviesOrSeries() {
        for kind in [MediaItemKind.movie, .series, .season] {
            let actions = MediaItemActionCatalog.actions(
                for: item(id: "x", kind: kind),
                supportsWatchState: false
            )
            XCTAssertFalse(actions.contains(.goToEpisode), "\(kind) is not an episode")
        }
    }

    private func item(
        id: String,
        kind: MediaItemKind,
        isPlayed: Bool = false,
        episodeNumber: Int? = nil,
        seasonID: String? = nil
    ) -> MediaItem {
        MediaItem(
            id: id,
            title: id,
            kind: kind,
            seasonNumber: nil,
            episodeNumber: episodeNumber,
            seasonID: seasonID,
            isPlayed: isPlayed
        )
    }

    // MARK: - Download actions

    /// The gap this closes: downloads were only ever offered by the episode rows'
    /// own hand-rolled menu, so no other surface — Continue Watching included —
    /// could show them. They're catalog actions now.
    func testDownloadActionFollowsCurrentState() {
        let movie = item(id: "m", kind: .movie)
        func actions(_ state: MediaItemDownloadState?) -> [MediaItemAction] {
            MediaItemActionCatalog.actions(
                for: movie, supportsWatchState: false, downloadState: .some(state)
            )
        }
        XCTAssertTrue(actions(nil).contains(.startDownload))
        XCTAssertTrue(actions(.inFlight).contains(.pauseDownload))
        XCTAssertTrue(actions(.interrupted).contains(.resumeDownload))
        XCTAssertTrue(actions(.downloaded).contains(.removeDownload))
    }

    /// A surface with no download capability (tvOS) passes `nil` and must be
    /// offered nothing — the outer optional is the capability, the inner one is
    /// "nothing downloaded yet".
    func testNoDownloadActionsWhenCapabilityAbsent() {
        let movie = item(id: "m", kind: .movie)
        let actions = MediaItemActionCatalog.actions(
            for: movie, supportsWatchState: true, downloadState: nil
        )
        XCTAssertFalse(actions.contains { $0.isDownload })
    }

    /// A series resolves to many files, so there's no single download to act on.
    func testNoDownloadActionsForNonDownloadableKinds() {
        for kind in [MediaItemKind.series, .season, .folder] {
            let actions = MediaItemActionCatalog.actions(
                for: item(id: "x", kind: kind),
                supportsWatchState: true,
                downloadState: .some(nil)
            )
            XCTAssertFalse(
                actions.contains { $0.isDownload },
                "\(kind) must not offer download actions"
            )
        }
    }

    /// Removing a download destroys local bytes, so it must be styled destructive
    /// while the other three stay neutral.
    func testOnlyRemoveDownloadIsDestructive() {
        XCTAssertTrue(MediaItemAction.removeDownload.isDestructive)
        for action in [MediaItemAction.startDownload, .pauseDownload, .resumeDownload] {
            XCTAssertFalse(action.isDestructive)
        }
    }

    // MARK: - Capability gating

    func testNoWatchActionsWhenWatchStateUnsupported() {
        // Navigation actions remain (Go to Movie); only watched-state actions are gated.
        let movie = item(id: "m", kind: .movie)
        XCTAssertEqual(MediaItemActionCatalog.actions(for: movie, supportsWatchState: false), [.goToMovie])
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
        XCTAssertEqual(MediaItemActionCatalog.actions(for: movie, supportsWatchState: true), [.markWatched, .goToMovie])
    }

    func testWatchedMovieOffersMarkUnwatched() {
        let movie = item(id: "m", kind: .movie, isPlayed: true)
        XCTAssertEqual(MediaItemActionCatalog.actions(for: movie, supportsWatchState: true), [.markUnwatched, .goToMovie])
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
        XCTAssertEqual(actions, [.markWatched, .markWatchedUpToHere, .goToEpisode])
    }

    func testUpToHereHiddenWhenNothingPrecedingUnwatched() {
        // Target is the first episode and already nothing earlier is unwatched.
        let e1 = item(id: "e1", kind: .episode, isPlayed: false, episodeNumber: 1)
        let context = MediaItemActionContext(orderedSiblings: [e1])

        let actions = MediaItemActionCatalog.actions(for: e1, supportsWatchState: true, context: context)
        XCTAssertEqual(actions, [.markWatched, .goToEpisode])
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

    // MARK: - Go to Season

    func testGoToSeasonOfferedForEpisodeOutsideSeasonList() {
        let episode = item(id: "e", kind: .episode, episodeNumber: 3, seasonID: "s1")
        // No orderedSiblings == not on the season's own page (e.g. Continue Watching).
        let actions = MediaItemActionCatalog.actions(for: episode, supportsWatchState: true)
        XCTAssertTrue(actions.contains(.goToSeason))
    }

    func testGoToSeasonHiddenWhenAlreadyInSeasonList() {
        let e1 = item(id: "e1", kind: .episode, episodeNumber: 1, seasonID: "s1")
        let e2 = item(id: "e2", kind: .episode, episodeNumber: 2, seasonID: "s1")
        let context = MediaItemActionContext(orderedSiblings: [e1, e2])
        let actions = MediaItemActionCatalog.actions(for: e2, supportsWatchState: true, context: context)
        XCTAssertFalse(actions.contains(.goToSeason))
    }

    func testGoToSeasonHiddenWhenSeasonIDMissing() {
        let episode = item(id: "e", kind: .episode, episodeNumber: 3, seasonID: nil)
        let actions = MediaItemActionCatalog.actions(for: episode, supportsWatchState: true)
        XCTAssertFalse(actions.contains(.goToSeason))
    }

    func testGoToSeasonOfferedEvenWithoutWatchStateSupport() {
        let episode = item(id: "e", kind: .episode, episodeNumber: 3, seasonID: "s1")
        let actions = MediaItemActionCatalog.actions(for: episode, supportsWatchState: false)
        XCTAssertEqual(actions, [.goToSeason, .goToEpisode])
    }

    func testGoToSeasonNotOfferedForMovies() {
        let movie = item(id: "m", kind: .movie, seasonID: "s1")
        let actions = MediaItemActionCatalog.actions(for: movie, supportsWatchState: true)
        XCTAssertFalse(actions.contains(.goToSeason))
    }

    // MARK: - Go to Movie

    func testGoToMovieOfferedForMovieOutsideList() {
        let movie = item(id: "m", kind: .movie)
        // No orderedSiblings == not inside a list (e.g. Continue Watching).
        let actions = MediaItemActionCatalog.actions(for: movie, supportsWatchState: true)
        XCTAssertTrue(actions.contains(.goToMovie))
    }

    func testGoToMovieHiddenWhenInsideList() {
        let m1 = item(id: "m1", kind: .movie)
        let m2 = item(id: "m2", kind: .movie)
        let context = MediaItemActionContext(orderedSiblings: [m1, m2])
        let actions = MediaItemActionCatalog.actions(for: m2, supportsWatchState: true, context: context)
        XCTAssertFalse(actions.contains(.goToMovie))
    }

    func testGoToMovieOfferedEvenWithoutWatchStateSupport() {
        let movie = item(id: "m", kind: .movie)
        let actions = MediaItemActionCatalog.actions(for: movie, supportsWatchState: false)
        XCTAssertEqual(actions, [.goToMovie])
    }

    func testGoToMovieNotOfferedForNonMovies() {
        for kind in [MediaItemKind.episode, .series, .season, .video] {
            let it = item(id: "x", kind: kind, seasonID: "s1")
            XCTAssertFalse(
                MediaItemActionCatalog.actions(for: it, supportsWatchState: true).contains(.goToMovie),
                "expected no Go to Movie for \(kind)"
            )
        }
    }
}
