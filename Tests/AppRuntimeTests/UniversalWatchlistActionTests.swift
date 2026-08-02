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

    func testUniversalPerformNeverCallsProviderOrSeerrPath() async {
        var providerResolutions = 0
        var localCalls: [(Bool, String)] = []
        var feedback: [String] = []
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
                return true
            },
            presentUniversalWatchlistFeedback: { _, text in
                feedback.append(String(localized: text))
            }
        )
        let item = MediaItem(
            id: "seer:20",
            title: "External",
            kind: .series,
            availability: .unknown
        )

        coordinator.perform(.addToWatchlist, on: item, context: .none)
        await waitUntil { feedback.count == 1 }

        XCTAssertEqual(localCalls.map(\.0), [true])
        XCTAssertEqual(localCalls.map(\.1), ["seer:20"])
        XCTAssertEqual(feedback, ["Added to Watchlist"])
        XCTAssertEqual(providerResolutions, 0)
    }

    func testAddAndRemoveFeedbackFollowSuccessfulLocalPersistence() async {
        var feedback: [String] = []
        var events: [String] = []
        let coordinator = MediaItemActionCoordinator(
            providerResolver: { _ in nil },
            primaryAccountID: { nil },
            crossServerWatchSyncEnabled: { false },
            enqueueWatchMutation: { _ in },
            universalWatchlistEnabled: { true },
            performUniversalWatchlist: { _, _ in
                events.append("persisted")
                return true
            },
            presentUniversalWatchlistFeedback: { _, text in
                feedback.append(String(localized: text))
                events.append("feedback")
            },
            beginUniversalWatchlistFanOut: { _, _ in
                events.append("fanout")
            }
        )
        let item = MediaItem(id: "m", title: "Movie", kind: .movie)

        coordinator.perform(.addToWatchlist, on: item, context: .none)
        await waitUntil { feedback.count == 1 }
        coordinator.perform(.removeFromWatchlist, on: item, context: .none)
        await waitUntil { feedback.count == 2 }

        XCTAssertEqual(
            feedback,
            ["Added to Watchlist", "Removed from Watchlist"]
        )
        XCTAssertEqual(
            events,
            [
                "persisted", "feedback", "fanout",
                "persisted", "feedback", "fanout"
            ]
        )
    }

    func testFeedbackWaitsForPersistenceAndFailureEmitsNothing() async {
        let gate = WatchlistPersistenceGate()
        var feedback: [String] = []
        let successful = MediaItemActionCoordinator(
            providerResolver: { _ in nil },
            primaryAccountID: { nil },
            crossServerWatchSyncEnabled: { false },
            enqueueWatchMutation: { _ in },
            universalWatchlistEnabled: { true },
            performUniversalWatchlist: { _, _ in await gate.wait() },
            presentUniversalWatchlistFeedback: { _, text in
                feedback.append(String(localized: text))
            }
        )
        let item = MediaItem(id: "m", title: "Movie", kind: .movie)
        successful.perform(.addToWatchlist, on: item, context: .none)
        await gate.waitUntilStarted()
        XCTAssertTrue(feedback.isEmpty)
        await gate.complete(success: true)
        await waitUntil { feedback.count == 1 }

        var failureCalled = false
        let failed = MediaItemActionCoordinator(
            providerResolver: { _ in nil },
            primaryAccountID: { nil },
            crossServerWatchSyncEnabled: { false },
            enqueueWatchMutation: { _ in },
            universalWatchlistEnabled: { true },
            performUniversalWatchlist: { _, _ in
                failureCalled = true
                return false
            },
            presentUniversalWatchlistFeedback: { _, text in
                feedback.append(String(localized: text))
            }
        )
        failed.perform(.removeFromWatchlist, on: item, context: .none)
        await waitUntil { failureCalled }
        XCTAssertEqual(feedback, ["Added to Watchlist"])
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

    func testAccountTaggedGlobalItemGetsOnlyWatchlistUntilLocalCopyValidates() {
        var downloadQueries = 0
        let item = MediaItem(
            id: "global-discover-id",
            title: "The Legend of Hei",
            kind: .movie,
            providerIDs: ["PlexGuid": "plex://movie/global-discover-id"],
            locallyValidatedPlayableSource: false,
            sourceAccountID: "plex-account"
        )
        let capabilities: (String?) -> (
            supportsWatchState: Bool,
            supportsWatchlist: Bool,
            supportsMetadataRefresh: Bool
        )? = { _ in (true, true, true) }
        let external = MediaItemActionCoordinator(
            providerResolver: { _ in nil },
            providerCapabilityResolver: capabilities,
            primaryAccountID: { "plex-account" },
            crossServerWatchSyncEnabled: { false },
            enqueueWatchMutation: { _ in },
            universalWatchlistEnabled: { true },
            watchlistMembership: { _ in true },
            downloadState: { _ in
                downloadQueries += 1
                return .some(nil)
            }
        )

        let externalActions = external.actions(for: item, context: .none)
        XCTAssertTrue(externalActions.contains(.removeFromWatchlist))
        XCTAssertFalse(externalActions.contains(.markWatched))
        XCTAssertFalse(externalActions.contains(.refreshMetadata))
        XCTAssertFalse(externalActions.contains(.startDownload))
        XCTAssertEqual(downloadQueries, 0)

        let localSource = MediaSourceRef(
            accountID: "plex-account",
            itemID: "local-rating-key",
            kind: .movie,
            providerKind: .plex
        )
        let validated = MediaItemActionCoordinator(
            providerResolver: { _ in nil },
            providerCapabilityResolver: capabilities,
            additionalSources: { _ in [localSource] },
            primaryAccountID: { "plex-account" },
            crossServerWatchSyncEnabled: { false },
            enqueueWatchMutation: { _ in },
            universalWatchlistEnabled: { true },
            watchlistMembership: { _ in true },
            downloadState: { _ in
                downloadQueries += 1
                return .some(nil)
            }
        )
        let validatedActions = validated.actions(for: item, context: .none)
        XCTAssertTrue(validatedActions.contains(.markWatched))
        XCTAssertTrue(validatedActions.contains(.removeFromWatchlist))
        XCTAssertTrue(validatedActions.contains(.refreshMetadata))
        XCTAssertTrue(validatedActions.contains(.startDownload))
        XCTAssertEqual(downloadQueries, 1)
    }

    private func waitUntil(_ predicate: @escaping () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for watchlist feedback")
    }

    private actor WatchlistPersistenceGate {
        private var started = false
        private var continuation: CheckedContinuation<Bool, Never>?

        func wait() async -> Bool {
            started = true
            return await withCheckedContinuation { continuation = $0 }
        }

        func waitUntilStarted() async {
            while !started { await Task.yield() }
        }

        func complete(success: Bool) {
            continuation?.resume(returning: success)
            continuation = nil
        }
    }
}
