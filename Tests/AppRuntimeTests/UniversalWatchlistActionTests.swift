import AppRuntime
import CoreModels
import XCTest

@MainActor
final class UniversalWatchlistActionTests: XCTestCase {
    func testExternalDiscoveryGetsLocalWatchlistWithoutProviderActions() {
        var providerResolutions = 0
        let coordinator = MediaItemActionCoordinator(
            providerResolver: { _ in
                providerResolutions += 1
                return nil
            },
            primaryAccountID: { nil },
            crossServerWatchSyncEnabled: { false },
            enqueueWatchMutation: { _ in },
            universalWatchlistEnabled: { true },
            watchlistMembership: { _ in false }
        )
        let external = MediaItem(
            id: "seer:10",
            title: "External",
            kind: .movie,
            availability: .unknown
        )

        let actions = coordinator.actions(for: external, context: .none)

        XCTAssertTrue(actions.contains(.addToWatchlist))
        XCTAssertFalse(actions.contains(.markWatched))
        XCTAssertFalse(actions.contains(.refreshMetadata))
        XCTAssertFalse(actions.contains(.startDownload))
        XCTAssertEqual(providerResolutions, 0)
    }

    func testMembershipIsIndependentOfProviderFavorite() {
        let favoriteButNotSaved = MediaItem(
            id: "m",
            title: "Movie",
            kind: .movie,
            isFavorite: true
        )
        let coordinator = MediaItemActionCoordinator(
            providerResolver: { _ in nil },
            primaryAccountID: { nil },
            crossServerWatchSyncEnabled: { false },
            enqueueWatchMutation: { _ in },
            universalWatchlistEnabled: { true },
            watchlistMembership: { _ in false }
        )

        XCTAssertTrue(
            coordinator.actions(
                for: favoriteButNotSaved,
                context: .none
            ).contains(.addToWatchlist)
        )
    }

    func testOwnedMenuUsesPreparedCapabilitiesWithoutProviderResolution() {
        var providerResolutions = 0
        let coordinator = MediaItemActionCoordinator(
            providerResolver: { _ in
                providerResolutions += 1
                return nil
            },
            providerCapabilityResolver: { _ in
                (
                    supportsWatchState: true,
                    supportsWatchlist: true,
                    supportsMetadataRefresh: true
                )
            },
            primaryAccountID: { nil },
            crossServerWatchSyncEnabled: { false },
            enqueueWatchMutation: { _ in },
            universalWatchlistEnabled: { true },
            watchlistMembership: { _ in false }
        )
        let item = MediaItem(id: "m", title: "Movie", kind: .movie)

        _ = coordinator.actions(for: item, context: .none)
        _ = coordinator.actions(for: item, context: .none)

        XCTAssertEqual(providerResolutions, 0)
    }

    func testUniversalPerformNeverCallsProviderOrSeerrPath() {
        var providerResolutions = 0
        var localCalls: [(Bool, String)] = []
        let coordinator = MediaItemActionCoordinator(
            providerResolver: { _ in
                providerResolutions += 1
                return nil
            },
            primaryAccountID: { nil },
            crossServerWatchSyncEnabled: { false },
            enqueueWatchMutation: { _ in },
            universalWatchlistEnabled: { true },
            performUniversalWatchlist: { adding, item in
                localCalls.append((adding, item.id))
            }
        )
        let item = MediaItem(
            id: "seer:20",
            title: "External",
            kind: .series,
            availability: .unknown
        )

        coordinator.perform(.addToWatchlist, on: item, context: .none)

        XCTAssertEqual(localCalls.map(\.0), [true])
        XCTAssertEqual(localCalls.map(\.1), ["seer:20"])
        XCTAssertEqual(providerResolutions, 0)
    }

    func testOnlyMovieAndSeriesReceiveUniversalAction() {
        let coordinator = MediaItemActionCoordinator(
            providerResolver: { _ in nil },
            primaryAccountID: { nil },
            crossServerWatchSyncEnabled: { false },
            enqueueWatchMutation: { _ in },
            universalWatchlistEnabled: { true }
        )

        for kind in [
            MediaItemKind.video, .season, .episode, .folder, .collection,
            .unknown
        ] {
            let item = MediaItem(id: "x", title: "X", kind: kind)
            let actions = coordinator.actions(for: item, context: .none)
            XCTAssertFalse(actions.contains(.addToWatchlist))
            XCTAssertFalse(actions.contains(.removeFromWatchlist))
        }
    }
}
