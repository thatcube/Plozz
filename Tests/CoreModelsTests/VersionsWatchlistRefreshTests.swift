import XCTest
@testable import CoreModels

// MARK: - MediaItem versions / favourite back-compatibility

final class MediaItemVersionsCodableTests: XCTestCase {
    func testLegacyJSONWithoutVersionsOrFavoriteDecodes() throws {
        // JSON written before `versions`/`isFavorite` existed must still decode,
        // defaulting the new fields rather than throwing.
        let legacy = #"{"id":"i1","title":"Old Movie","kind":"movie"}"#
        let item = try JSONDecoder().decode(MediaItem.self, from: Data(legacy.utf8))
        XCTAssertEqual(item.id, "i1")
        XCTAssertEqual(item.versions, [])
        XCTAssertFalse(item.isFavorite)
        XCTAssertFalse(item.hasBeenPlayed)
        XCTAssertNil(item.selectedVersionID)
        XCTAssertFalse(item.hasMultipleVersions)
    }

    func testHistoricalWatchStateDefaultsFromCompletionAndRoundTrips() throws {
        let legacyWatched = #"{"id":"i1","title":"Old Movie","kind":"movie","isPlayed":true}"#
        let legacy = try JSONDecoder().decode(MediaItem.self, from: Data(legacyWatched.utf8))
        XCTAssertTrue(legacy.hasBeenPlayed)

        let rewatch = MediaItem(
            id: "i2",
            title: "Rewatch",
            kind: .movie,
            resumePosition: 120,
            isPlayed: false,
            hasBeenPlayed: true
        )
        let decoded = try JSONDecoder().decode(
            MediaItem.self,
            from: JSONEncoder().encode(rewatch)
        )
        XCTAssertFalse(decoded.isPlayed)
        XCTAssertTrue(decoded.hasBeenPlayed)
    }

    func testLegacySourceHistoricalStateDefaultsFromCompletion() throws {
        let json = #"{"accountID":"a","itemID":"i","isPlayed":true}"#
        let source = try JSONDecoder().decode(MediaSourceRef.self, from: Data(json.utf8))
        XCTAssertTrue(source.hasBeenPlayed)
    }

    func testVersionsAndFavoriteRoundTrip() throws {
        let item = MediaItem(
            id: "i2", title: "New", kind: .movie,
            versions: [MediaVersion(id: "v1", height: 2160), MediaVersion(id: "v2", height: 1080)],
            isFavorite: true
        )
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(MediaItem.self, from: data)
        XCTAssertEqual(decoded.versions.map(\.id), ["v1", "v2"])
        XCTAssertTrue(decoded.isFavorite)
        XCTAssertTrue(decoded.hasMultipleVersions)
    }

    func testSelectedVersionIDIsTransientAndNotEncoded() throws {
        let item = MediaItem(id: "i3", title: "T", kind: .movie,
                             versions: [MediaVersion(id: "v1")])
            .selectingVersion("v1")
        XCTAssertEqual(item.selectedVersionID, "v1")
        XCTAssertEqual(item.selectedVersion?.id, "v1")

        let json = String(data: try JSONEncoder().encode(item), encoding: .utf8)!
        XCTAssertFalse(json.contains("selectedVersionID"))

        // And it does not survive a round trip — it's per-play UI state.
        let decoded = try JSONDecoder().decode(MediaItem.self, from: Data(json.utf8))
        XCTAssertNil(decoded.selectedVersionID)
    }
}

// MARK: - MediaItemMutation (optional played / favourite)

final class MediaItemMutationOptionalTests: XCTestCase {
    func testWatchlistOnlyMutationLeavesPlayedNil() {
        let m = MediaItemMutation(itemIDs: ["a"], favorite: true)
        XCTAssertNil(m.played)
        XCTAssertEqual(m.favorite, true)
    }

    func testPlayedOnlyMutationLeavesFavoriteNil() {
        let m = MediaItemMutation(itemIDs: ["a"], played: true)
        XCTAssertEqual(m.played, true)
        XCTAssertNil(m.favorite)
    }

    func testNotificationRoundTripPreservesBothFields() throws {
        let original = MediaItemMutation(itemIDs: ["a", "b"], played: false, favorite: true)
        let note = Notification(name: .mediaItemDidMutate, object: nil, userInfo: {
            var info: [String: Any] = ["itemIDs": ["a", "b"]]
            info["played"] = false
            info["favorite"] = true
            return info
        }())
        let restored = try XCTUnwrap(MediaItemMutation.from(note))
        XCTAssertEqual(restored.itemIDs, original.itemIDs)
        XCTAssertEqual(restored.played, false)
        XCTAssertEqual(restored.favorite, true)
    }

    func testNotificationWithNoChangeFieldsIsNil() {
        let note = Notification(name: .mediaItemDidMutate, object: nil, userInfo: ["itemIDs": ["a"]])
        XCTAssertNil(MediaItemMutation.from(note))
    }

    func testDurablePlayedMutationReconstructsOptimisticState() throws {
        let durable = WatchMutation(
            capturedAt: Date(),
            canonicalMediaID: "tmdb:1",
            played: true,
            targets: [
                WatchMutationTarget(accountID: "a", itemID: "one"),
                WatchMutationTarget(accountID: "b", itemID: "two")
            ]
        )
        var partiallyDrained = durable
        partiallyDrained.targets = [durable.targets[1]]

        let mutation = try XCTUnwrap(MediaItemMutation(watchMutation: partiallyDrained))

        XCTAssertEqual(mutation.played, true)
        XCTAssertEqual(mutation.itemIDs, ["one", "two"])
        XCTAssertEqual(mutation.scopedItemIDs, ["a:one", "b:two"])
    }

    func testTargetsMatchesPrimaryID() {
        let item = MediaItem(id: "primary", title: "T", kind: .movie)
        XCTAssertTrue(MediaItemMutation(itemIDs: ["primary"], played: true).targets(item))
        XCTAssertFalse(MediaItemMutation(itemIDs: ["other"], played: true).targets(item))
    }

    func testTargetsMatchesNonPrimarySourceItemID() {
        // A merged card whose PRIMARY is server A's id, but which also lists a
        // twin on server B. A mutation built against server B (e.g. the user
        // finished the copy there, or the index was cold so the fan-out never
        // reached server A's id) must still match this card via its sources.
        let item = MediaItem(
            id: "A-id", title: "Dune", kind: .movie,
            sources: [
                MediaSourceRef(accountID: "A", itemID: "A-id", providerKind: .jellyfin),
                MediaSourceRef(accountID: "B", itemID: "B-id", providerKind: .plex)
            ]
        )
        let mutation = MediaItemMutation(itemIDs: ["B-id"], played: true, resumePosition: 0, playedPercentage: 1)
        XCTAssertTrue(mutation.targets(item), "Play on a non-primary server's copy must still target the merged card")

        let applied = mutation.applied(to: item)
        XCTAssertTrue(applied.isPlayed, "The merged card must reflect the play made on any of its sources")
        XCTAssertTrue(applied.hasBeenPlayed)
        XCTAssertTrue(applied.sources[1].hasBeenPlayed)
    }

    func testTargetsDoesNotMatchUnrelatedCard() {
        let item = MediaItem(
            id: "A-id", title: "Dune", kind: .movie,
            sources: [MediaSourceRef(accountID: "A", itemID: "A-id", providerKind: .jellyfin)]
        )
        XCTAssertFalse(MediaItemMutation(itemIDs: ["Z-id"], played: true).targets(item))
    }

    func testUnwatchingOneSourcePreservesAnotherSourcesHistory() {
        let item = MediaItem(
            id: "A-id",
            title: "Dune",
            kind: .movie,
            hasBeenPlayed: true,
            sources: [
                MediaSourceRef(
                    accountID: "A",
                    itemID: "A-id",
                    isPlayed: true,
                    hasBeenPlayed: true
                ),
                MediaSourceRef(
                    accountID: "B",
                    itemID: "B-id",
                    isPlayed: true,
                    hasBeenPlayed: true
                )
            ]
        )
        let mutation = MediaItemMutation(
            itemIDs: ["A-id"],
            scopedItemIDs: ["A:A-id"],
            played: false
        )

        let applied = mutation.applied(to: item)

        XCTAssertTrue(applied.hasBeenPlayed)
        XCTAssertFalse(applied.sources[0].hasBeenPlayed)
        XCTAssertTrue(applied.sources[1].hasBeenPlayed)
    }
}

// MARK: - Action catalog: watchlist + refresh gating

final class MediaItemActionCatalogWatchlistRefreshTests: XCTestCase {
    private func item(_ id: String, _ kind: MediaItemKind, isFavorite: Bool = false) -> MediaItem {
        MediaItem(id: id, title: id, kind: kind, isFavorite: isFavorite)
    }

    func testWatchlistActionHiddenWhenUnsupported() {
        let actions = MediaItemActionCatalog.actions(
            for: item("m", .movie), supportsWatchState: true, supportsWatchlist: false
        )
        XCTAssertFalse(actions.contains(.addToWatchlist))
        XCTAssertFalse(actions.contains(.removeFromWatchlist))
    }

    func testAddToWatchlistOfferedForUnsavedMovie() {
        let actions = MediaItemActionCatalog.actions(
            for: item("m", .movie, isFavorite: false), supportsWatchState: true, supportsWatchlist: true
        )
        XCTAssertTrue(actions.contains(.addToWatchlist))
        XCTAssertFalse(actions.contains(.removeFromWatchlist))
    }

    func testRemoveFromWatchlistOfferedForSavedSeries() {
        let actions = MediaItemActionCatalog.actions(
            for: item("s", .series, isFavorite: true), supportsWatchState: true, supportsWatchlist: true
        )
        XCTAssertTrue(actions.contains(.removeFromWatchlist))
        XCTAssertFalse(actions.contains(.addToWatchlist))
    }

    func testWatchlistNotOfferedForEpisodesOrSeasons() {
        for kind in [MediaItemKind.episode, .season, .folder, .collection] {
            let actions = MediaItemActionCatalog.actions(
                for: item("x", kind), supportsWatchState: true, supportsWatchlist: true
            )
            XCTAssertFalse(actions.contains(.addToWatchlist), "watchlist should not apply to \(kind)")
        }
    }

    func testRefreshMetadataOfferedLastWhenSupported() {
        let actions = MediaItemActionCatalog.actions(
            for: item("m", .movie), supportsWatchState: true,
            supportsWatchlist: true, supportsMetadataRefresh: true
        )
        XCTAssertEqual(actions.last, .refreshMetadata)
    }

    func testRefreshMetadataHiddenWhenUnsupported() {
        let actions = MediaItemActionCatalog.actions(
            for: item("m", .movie), supportsWatchState: true, supportsMetadataRefresh: false
        )
        XCTAssertFalse(actions.contains(.refreshMetadata))
    }

    func testRefreshMetadataNotOfferedForFolders() {
        let actions = MediaItemActionCatalog.actions(
            for: item("f", .folder), supportsWatchState: true, supportsMetadataRefresh: true
        )
        XCTAssertFalse(actions.contains(.refreshMetadata))
    }
}

// MARK: - VersionPreferenceStore (per-title remembered version)

final class VersionPreferenceStoreTests: XCTestCase {
    private func makeStore() -> (VersionPreferenceStore, UserDefaults) {
        let suite = "test.versionpref.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (VersionPreferenceStore(defaults: defaults), defaults)
    }

    func testUnsetTitleReturnsNil() {
        let (store, _) = makeStore()
        XCTAssertNil(store.preferredVersionID(forTitle: "movie-1"))
    }

    func testRememberAndReadBack() {
        let (store, _) = makeStore()
        store.setPreferredVersionID("v-4k", forTitle: "movie-1")
        XCTAssertEqual(store.preferredVersionID(forTitle: "movie-1"), "v-4k")
        // Distinct titles are independent.
        XCTAssertNil(store.preferredVersionID(forTitle: "movie-2"))
    }

    func testClearingRemovesPreference() {
        let (store, _) = makeStore()
        store.setPreferredVersionID("v-4k", forTitle: "movie-1")
        store.setPreferredVersionID(nil, forTitle: "movie-1")
        XCTAssertNil(store.preferredVersionID(forTitle: "movie-1"))
    }

    func testEmptyTitleIDIsIgnored() {
        let (store, _) = makeStore()
        store.setPreferredVersionID("v", forTitle: "")
        XCTAssertNil(store.preferredVersionID(forTitle: ""))
    }

    func testNamespacesAreIsolated() {
        let suite = "test.versionpref.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let primary = VersionPreferenceStore(defaults: defaults, namespace: nil)
        let profileB = VersionPreferenceStore(defaults: defaults, namespace: "profileB")
        primary.setPreferredVersionID("v-primary", forTitle: "m")
        profileB.setPreferredVersionID("v-b", forTitle: "m")
        XCTAssertEqual(primary.preferredVersionID(forTitle: "m"), "v-primary")
        XCTAssertEqual(profileB.preferredVersionID(forTitle: "m"), "v-b")
    }
}
