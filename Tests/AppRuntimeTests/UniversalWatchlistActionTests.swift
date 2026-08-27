@testable import AppRuntime
import CoreModels
import XCTest

@MainActor
final class UniversalWatchlistActionTests: XCTestCase {
    func testPersistedArtworkRehydratesEvenWhenUniversalWatchlistIsOff() {
        let signed = URL(
            string: "https://plex.example/poster?token=current"
        )!
        let coordinator = MediaItemActionCoordinator(
            providerResolver: { _ in nil },
            primaryAccountID: { nil },
            crossServerWatchSyncEnabled: { false },
            enqueueWatchMutation: { _ in },
            universalWatchlistEnabled: { false },
            rehydratePersistedArtworkItems: { items in
                items.map { item in
                    var item = item
                    item.posterURL = signed
                    return item
                }
            }
        )
        let item = MediaItem(
            id: "item",
            title: "Item",
            kind: .movie
        )

        XCTAssertEqual(
            coordinator.rehydratePersistedArtwork([item])
                .first?.posterURL,
            signed
        )
    }

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
        // Feedback is raised before the write, so it is no longer the signal that
        // the work finished — wait on the write itself.
        await waitUntil { localCalls.count == 1 }

        XCTAssertEqual(localCalls.map(\.0), [true])
        XCTAssertEqual(localCalls.map(\.1), ["seer:20"])
        XCTAssertEqual(feedback, ["Added to Watchlist"])
        XCTAssertEqual(providerResolutions, 0)
    }

    /// Feedback is raised BEFORE the write, deliberately.
    ///
    /// The ledger write posts a change notification every watchlist surface
    /// rebuilds from, and that work can hold the main thread long enough for a
    /// 1.6s toast to be set and expire without a single frame being drawn with it
    /// on screen — a press appeared to do nothing at all. The confirmation belongs
    /// to the tap, not to the end of the fan-out.
    func testFeedbackPrecedesPersistenceSoAPressIsAcknowledgedImmediately() async {
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
        await waitUntil { events.filter { $0 == "fanout" }.count == 1 }
        coordinator.perform(.removeFromWatchlist, on: item, context: .none)
        await waitUntil { events.filter { $0 == "fanout" }.count == 2 }

        XCTAssertEqual(
            feedback,
            ["Added to Watchlist", "Removed from Watchlist"]
        )
        XCTAssertEqual(
            events,
            [
                "feedback", "persisted", "fanout",
                "feedback", "persisted", "fanout"
            ]
        )
    }

    func testPressIsAcknowledgedImmediatelyAndAFailureSaysSo() async {
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
        // Acknowledged the moment it is pressed, without waiting on the write.
        XCTAssertEqual(feedback, ["Added to Watchlist"])
        await gate.complete(success: true)

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
        await waitUntil { feedback.count == 3 }
        XCTAssertTrue(failureCalled)
        // A failure now says so. Optimistic acknowledgement means silence would
        // leave a confirmation standing for something that never happened.
        XCTAssertEqual(
            feedback,
            [
                "Added to Watchlist",
                "Removed from Watchlist",
                "Couldn't update Watchlist",
            ]
        )
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

    /// Resolving membership walks the identity index's component graph and builds
    /// alias evidence. `actions(for:)` runs from every card's `body`, so doing that
    /// per call cost sustained 200-500 ms main-thread stalls on an idle Apple TV
    /// Home. It must be resolved once per world, not once per body.
    func testMembershipIsResolvedOncePerWorldNotPerCardBody() {
        var resolutions = 0
        var revision: UInt64 = 1
        let coordinator = MediaItemActionCoordinator(
            providerResolver: { _ in nil },
            primaryAccountID: { nil },
            crossServerWatchSyncEnabled: { false },
            enqueueWatchMutation: { _ in },
            universalWatchlistEnabled: { true },
            watchlistMembership: { _ in
                resolutions += 1
                return true
            },
            watchlistMembershipRevision: { revision }
        )
        let a = MediaItem(id: "1", title: "A", kind: .movie, sourceAccountID: "acct")
        let b = MediaItem(id: "2", title: "B", kind: .movie, sourceAccountID: "acct")

        // A row of cards re-evaluating many times over an unchanged world.
        for _ in 0..<50 {
            _ = coordinator.isWatchlisted(a)
            _ = coordinator.isWatchlisted(b)
        }
        XCTAssertEqual(resolutions, 2, "one resolution per distinct item, not per call")

        // A changed world must be seen — a stale heart is the bug this replaced.
        revision = 2
        XCTAssertTrue(coordinator.isWatchlisted(a))
        XCTAssertEqual(resolutions, 3)

        // Two cards showing the same copy share one answer.
        let aAgain = MediaItem(id: "1", title: "A", kind: .movie, sourceAccountID: "acct")
        _ = coordinator.isWatchlisted(aAgain)
        XCTAssertEqual(resolutions, 3)
    }

    /// The same title on two different servers is two copies and must be asked
    /// about separately — the cache key must not collapse them.
    func testMembershipCacheIsScopedByAccount() {
        var asked: [String] = []
        let coordinator = MediaItemActionCoordinator(
            providerResolver: { _ in nil },
            primaryAccountID: { nil },
            crossServerWatchSyncEnabled: { false },
            enqueueWatchMutation: { _ in },
            universalWatchlistEnabled: { true },
            watchlistMembership: { item in
                asked.append(item.sourceAccountID ?? "-")
                return false
            },
            watchlistMembershipRevision: { 7 }
        )
        _ = coordinator.isWatchlisted(
            MediaItem(id: "9", title: "T", kind: .movie, sourceAccountID: "plex")
        )
        _ = coordinator.isWatchlisted(
            MediaItem(id: "9", title: "T", kind: .movie, sourceAccountID: "jellyfin")
        )
        XCTAssertEqual(asked, ["plex", "jellyfin"])
    }

    /// The process-wide membership memo has to be droppable, not just re-keyed.
    ///
    /// Its key is a hash of COUNTS, and a removal of a title whose presence came
    /// from a destination's own list moves none of them — only a tombstone lands.
    /// Without an explicit drop the pre-removal set is served back under the same
    /// key and the bookmark keeps rendering "on the watchlist". Every local
    /// mutation calls `invalidate()` through `announceUniversalWatchlistDidChange`.
    func testMembershipMemoCanBeDroppedUnderAnUnchangedRevision() {
        let cache = UniversalWatchlistMembershipCache.shared
        let series = MediaAliasID()
        let revision: UInt64 = 4_242

        cache.store([series], revision: revision)
        XCTAssertEqual(cache.ids(for: revision), [series])

        cache.invalidate()

        XCTAssertNil(cache.ids(for: revision))
    }
}
