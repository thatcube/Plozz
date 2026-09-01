import CoreModels
import XCTest
@testable import FeatureWatchlistCore

@MainActor
final class WatchlistModelTests: XCTestCase {
    func testExplicitAddsInsertAtFrontWithoutReorderingExistingEntries() throws {
        let model = WatchlistModel()
        let first = MediaAliasID()
        let second = MediaAliasID()
        let third = MediaAliasID()
        try model.activate(profileID: "p")

        try model.add(profileID: "p", aliasID: first, kind: .movie)
        try model.add(profileID: "p", aliasID: second, kind: .series)
        try model.add(profileID: "p", aliasID: third, kind: .movie)

        XCTAssertEqual(
            model.activeSnapshot.orderedEntries.map(\.aliasID),
            [third, second, first]
        )
    }

    func testExplicitRemoveThenReaddMovesTitleToFront() throws {
        let model = WatchlistModel()
        let first = MediaAliasID()
        let second = MediaAliasID()
        try model.activate(profileID: "p")
        try model.add(profileID: "p", aliasID: first, kind: .movie)
        try model.add(profileID: "p", aliasID: second, kind: .movie)

        try model.remove(profileID: "p", aliasID: first, kind: .movie)
        try model.add(profileID: "p", aliasID: first, kind: .movie)

        XCTAssertEqual(
            model.activeSnapshot.orderedEntries.map(\.aliasID),
            [first, second]
        )
    }

    /// Native entries follow explicit ones, in the destination's own order, and
    /// the SAME two reads produce the same row — no dictionary-order shuffle.
    func testNativeEntriesFollowExplicitOnesInStableOrder() throws {
        let model = WatchlistModel()
        let explicit = MediaAliasID()
        let nativeFirst = MediaAliasID()
        let nativeSecond = MediaAliasID()
        let destination = WatchlistDestinationID(rawValue: "native")!
        try model.activate(profileID: "p")
        try model.add(profileID: "p", aliasID: explicit, kind: .movie)

        var view = NativeWatchlistView()
        view.applySuccess(
            destinationID: destination,
            entries: [
                NativeWatchlistEntry(aliasID: nativeFirst, kind: .movie, index: 0)!,
                NativeWatchlistEntry(aliasID: nativeSecond, kind: .series, index: 1)!
            ]
        )

        let first = model.union(
            profileID: "p",
            nativeView: view,
            aliasSnapshot: .empty,
            enabledDestinationIDs: [destination]
        )
        let second = model.union(
            profileID: "p",
            nativeView: view,
            aliasSnapshot: .empty,
            enabledDestinationIDs: [destination]
        )

        XCTAssertEqual(
            first.orderedEntries.map(\.aliasID),
            [explicit, nativeFirst, nativeSecond]
        )
        XCTAssertEqual(
            first.orderedEntries.map(\.aliasID),
            second.orderedEntries.map(\.aliasID)
        )
        // Only the add is the viewer's own; the rest is the server talking.
        XCTAssertEqual(first.orderedEntries.map(\.isExplicit), [true, false, false])
    }

    func testTombstonePersistsAndReaddKeepsStableRank() throws {
        let model = WatchlistModel()
        let alias = MediaAliasID()
        try model.activate(profileID: "p")

        let added = try model.add(
            profileID: "p",
            aliasID: alias,
            kind: .movie
        )
        let removed = try model.remove(
            profileID: "p",
            aliasID: alias,
            kind: .movie
        )

        XCTAssertEqual(removed.rank, added.rank)
        XCTAssertFalse(model.activeSnapshot.contains(aliasID: alias))
        XCTAssertEqual(model.activeSnapshot.tombstoneCount, 1)

        let readded = try model.add(
            profileID: "p",
            aliasID: alias,
            kind: .movie
        )
        XCTAssertEqual(readded.rank, added.rank)
        XCTAssertTrue(model.activeSnapshot.contains(aliasID: alias))
    }

    func testProfileActivationIsolatesSnapshotsAndDeletionPurges() throws {
        let model = WatchlistModel()
        let first = MediaAliasID()
        let second = MediaAliasID()
        try model.activate(profileID: "one")
        try model.add(profileID: "one", aliasID: first, kind: .movie)
        try model.activate(profileID: "two")
        try model.add(profileID: "two", aliasID: second, kind: .series)

        XCTAssertFalse(model.activeSnapshot.contains(aliasID: first))
        XCTAssertTrue(model.activeSnapshot.contains(aliasID: second))

        try model.removeProfile("two")
        XCTAssertNil(model.activeProfileID)
        XCTAssertThrowsError(try model.hydrate(profileID: "two"))
        try model.activate(profileID: "one")
        XCTAssertTrue(model.activeSnapshot.contains(aliasID: first))
    }

    func testLegacyAndNativeMigrationMarkersAreIdempotent() throws {
        let model = WatchlistModel()
        let alias = MediaAliasID()
        let destination = WatchlistDestinationID(rawValue: "native")!
        try model.activate(profileID: "p")
        try model.seedLegacyIfNeeded(
            profileID: "p",
            entries: [(alias, .movie, nil)]
        )
        try model.seedLegacyIfNeeded(
            profileID: "p",
            entries: [(MediaAliasID(), .movie, nil)]
        )
        try model.retireNativeImports(profileID: "p")
        try model.markLegacyPresentationArtworkScrubbed(profileID: "p")

        let metadata = try model.migrationMetadata(profileID: "p")
        XCTAssertNotNil(metadata.legacyHomeSeedCompletedAt)
        XCTAssertNotNil(
            metadata.legacyPresentationArtworkScrubbedAt
        )
        XCTAssertNotNil(metadata.nativeImportRetiredAt)
        XCTAssertEqual(model.activeSnapshot.orderedEntries.count, 1)
    }

    /// Removing something that lives on a server keeps it gone across re-reads,
    /// and stays gone — a server still listing it is not a new statement.
    func testExplicitRemovalOutranksAServerThatStillListsIt() throws {
        let model = WatchlistModel()
        let alias = MediaAliasID()
        let destination = WatchlistDestinationID(rawValue: "native")!
        try model.activate(profileID: "p")
        try model.add(profileID: "p", aliasID: alias, kind: .movie)
        try model.remove(profileID: "p", aliasID: alias, kind: .movie)

        var view = NativeWatchlistView()
        view.applySuccess(
            destinationID: destination,
            entries: [NativeWatchlistEntry(aliasID: alias, kind: .movie, index: 0)!]
        )

        for _ in 0..<2 {
            let union = model.union(
                profileID: "p",
                nativeView: view,
                aliasSnapshot: .empty,
                enabledDestinationIDs: [destination]
            )
            XCTAssertFalse(union.contains(aliasID: alias))
        }
    }

    /// A native re-add AFTER the removal was confirmed applied is a new
    /// statement, so the title comes back — but on the server's evidence, which
    /// means switching that server off still takes it away again.
    func testSupersededRemovalSurfacesAgainAndStaysServerOwned() throws {
        let model = WatchlistModel()
        let alias = MediaAliasID()
        let destination = WatchlistDestinationID(rawValue: "native")!
        try model.activate(profileID: "p")
        try model.add(profileID: "p", aliasID: alias, kind: .movie)
        try model.remove(profileID: "p", aliasID: alias, kind: .movie)

        var view = NativeWatchlistView()
        view.applySuccess(
            destinationID: destination,
            entries: [NativeWatchlistEntry(aliasID: alias, kind: .movie, index: 0)!]
        )

        XCTAssertTrue(try model.markRemovalSuperseded(
            profileID: "p",
            aliasID: alias
        ))
        XCTAssertTrue(model.union(
            profileID: "p",
            nativeView: view,
            aliasSnapshot: .empty,
            enabledDestinationIDs: [destination]
        ).contains(aliasID: alias))

        // The tombstone is kept, not deleted: deleting it would let a peer
        // re-deliver the old `.absent` record with no absence boundary left to
        // clear it, hiding the title for good.
        XCTAssertEqual(
            model.activeSnapshot.intent(for: alias)?.desiredState,
            .absent
        )
        XCTAssertFalse(model.union(
            profileID: "p",
            nativeView: view,
            aliasSnapshot: .empty,
            enabledDestinationIDs: []
        ).contains(aliasID: alias))
    }

    func testStaleNativeReAddCannotSupersedeANewerLocalRemoval() throws {
        let model = WatchlistModel()
        let alias = MediaAliasID()
        let observedAt = Date(timeIntervalSince1970: 100)
        try model.activate(profileID: "p")
        try model.remove(
            profileID: "p",
            aliasID: alias,
            kind: .movie,
            at: observedAt
        )
        try model.remove(
            profileID: "p",
            aliasID: alias,
            kind: .movie,
            at: observedAt.addingTimeInterval(1)
        )

        XCTAssertFalse(try model.markRemovalSuperseded(
            profileID: "p",
            aliasID: alias,
            expectedChangedAt: observedAt
        ))
        XCTAssertTrue(
            model.activeSnapshot.intent(for: alias)?
                .metadata.suppressesNativePresence ?? false
        )
    }

    func testRedirectRekeysAndMergesWithoutChangingOldestRank() throws {
        let winner = MediaAliasID(
            uuidString: "00000000-0000-0000-0000-000000000001"
        )!
        let loser = MediaAliasID(
            uuidString: "00000000-0000-0000-0000-000000000002"
        )!
        let now = Date()
        let winnerRecord = MediaAliasRecord(
            id: winner,
            kind: .movie,
            createdAt: now
        )!
        let loserRecord = MediaAliasRecord(
            id: loser,
            kind: .movie,
            createdAt: now,
            redirectTarget: winner
        )!
        let model = WatchlistModel()
        try model.activate(profileID: "p")
        let first = try model.add(
            profileID: "p",
            aliasID: loser,
            kind: .movie,
            at: now
        )
        _ = try model.remove(
            profileID: "p",
            aliasID: winner,
            kind: .movie,
            at: now.addingTimeInterval(1)
        )

        try model.reconcileAliases(
            profileID: "p",
            aliasSnapshot: MediaAliasSnapshot(
                records: [winnerRecord, loserRecord]
            )
        )

        XCTAssertEqual(model.activeSnapshot.intentsByAliasID.count, 1)
        XCTAssertEqual(model.activeSnapshot.intent(for: loser)?.aliasID, winner)
        XCTAssertEqual(model.activeSnapshot.intent(for: winner)?.rank, first.rank)
        XCTAssertEqual(
            model.activeSnapshot.intent(for: winner)?.desiredState,
            .absent
        )
    }

    func testMergedTombstoneRetainsNativeReaddSupersession() {
        let alias = MediaAliasID()
        let removedAt = Date(timeIntervalSince1970: 100)
        let supersededAt = Date(timeIntervalSince1970: 200)
        let snapshot = WatchlistSnapshot(intents: [
            WatchlistIntent(
                aliasID: alias,
                kind: .movie,
                desiredState: .absent,
                rank: 0,
                origin: .local,
                changedAt: removedAt,
                metadata: WatchlistIntentMetadata(
                    lastExplicitRemovalAt: removedAt,
                    removalSupersededAt: supersededAt
                )
            )!,
            WatchlistIntent(
                aliasID: alias,
                kind: .movie,
                desiredState: .absent,
                rank: 1,
                origin: .cloud,
                changedAt: removedAt.addingTimeInterval(-1)
            )!
        ])

        let merged = snapshot.intent(for: alias)
        XCTAssertEqual(merged?.metadata.removalSupersededAt, supersededAt)
        XCTAssertFalse(merged?.metadata.suppressesNativePresence ?? true)
    }

    func testSyncCaptureApplyIsByteStableForAddAndTombstone() throws {
        let alias = MediaAliasID()
        let source = WatchlistModel()
        try source.activate(profileID: "p")
        try source.add(
            profileID: "p",
            aliasID: MediaAliasID(),
            kind: .series
        )
        try source.add(profileID: "p", aliasID: alias, kind: .movie)
        let key = WatchlistMediaStateRecordKey(
            profileID: "p",
            aliasID: alias
        )
        let addBytes = try XCTUnwrap(
            source.captureSyncRecords(profileID: "p")[key.recordName]
        )

        let receiver = WatchlistModel()
        try receiver.activate(profileID: "p")
        try receiver.add(
            profileID: "p",
            aliasID: alias,
            kind: .movie,
            origin: .nativeImport
        )
        try receiver.applyRemoteSyncRecords(
            profileID: "p",
            changes: [key: addBytes]
        )
        let recapturedAdd = try receiver.captureSyncRecords(
            profileID: "p",
            fallback: [key.recordName: addBytes]
        )
        XCTAssertEqual(recapturedAdd[key.recordName], addBytes)

        try source.remove(profileID: "p", aliasID: alias, kind: .movie)
        let removeBytes = try XCTUnwrap(
            source.captureSyncRecords(profileID: "p")[key.recordName]
        )
        try receiver.applyRemoteSyncRecords(
            profileID: "p",
            changes: [key: removeBytes]
        )
        XCTAssertFalse(receiver.activeSnapshot.contains(aliasID: alias))
        let recapturedRemove = try receiver.captureSyncRecords(
            profileID: "p",
            fallback: [key.recordName: removeBytes]
        )
        XCTAssertEqual(recapturedRemove[key.recordName], removeBytes)
    }

    func testSnapshotIndicesHaveBoundedShapeAtOneAndTenThousand() {
        for count in [1_000, 10_000] {
            let intents = (0..<count).map { index in
                WatchlistIntent(
                    aliasID: MediaAliasID(),
                    kind: index.isMultiple(of: 2) ? .movie : .series,
                    desiredState: index.isMultiple(of: 3) ? .absent : .present,
                    rank: UInt64(index),
                    origin: .local
                )!
            }
            let snapshot = WatchlistSnapshot(intents: intents)
            XCTAssertEqual(snapshot.intentsByAliasID.count, count)
            XCTAssertEqual(
                snapshot.orderedEntries.count + snapshot.tombstoneCount,
                count
            )
            XCTAssertEqual(
                snapshot.contains(aliasID: intents.last!.aliasID),
                intents.last!.desiredState == .present
            )
        }
    }

    func testAtomicStoreRoundTripAndCorruptionBlocksOverwrite() throws {
        let root = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent(
            "PlozzWatchlistTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AtomicWatchlistIntentStore(
            directoryURL: root,
            profileID: "p"
        )
        _ = try store.load()
        let intent = WatchlistIntent(
            aliasID: MediaAliasID(),
            kind: .movie,
            desiredState: .present,
            rank: 0,
            origin: .local
        )!
        try store.save(.init(intents: [intent]))
        XCTAssertEqual(try store.load().intents, [intent])

        try Data("not-json".utf8).write(to: store.fileURL, options: [.atomic])
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(.empty))
        XCTAssertEqual(
            try Data(contentsOf: store.fileURL),
            Data("not-json".utf8)
        )
    }

    func testAtomicStoreLoadRewritesCompletedLegacyPresentation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PlozzWatchlistRewriteTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AtomicWatchlistIntentStore(
            directoryURL: root,
            profileID: "p"
        )
        _ = try store.load()
        let intent = WatchlistIntent(
            aliasID: MediaAliasID(),
            kind: .series,
            desiredState: .present,
            rank: 0,
            origin: .local,
            presentation: MediaAliasPresentation(
                title: "Arcane",
                year: 2021,
                artworkURL: "https://art.example/clean.jpg"
            )
        )!
        try store.save(WatchlistIntentStoreState(
            intents: [intent],
            migration: WatchlistMigrationMetadata(
                legacyHomeSeedCompletedAt: Date()
            )
        ))

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: store.fileURL)
            ) as? [String: Any]
        )
        var intents = try XCTUnwrap(
            object["intents"] as? [[String: Any]]
        )
        var legacy = intents[0]
        legacy["origin"] = "legacyHomeSeed"
        var presentation = try XCTUnwrap(
            legacy["presentation"] as? [String: Any]
        )
        presentation["artworkURL"] =
            "https://art.example/wrong.jpg?X-Plex-Token=SECRET"
        legacy["presentation"] = presentation
        intents[0] = legacy
        object["intents"] = intents
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ).write(to: store.fileURL, options: [.atomic])

        let reloaded = try AtomicWatchlistIntentStore(
            directoryURL: root,
            profileID: "p"
        )
        let loaded = try XCTUnwrap(reloaded.load().intents.first)

        XCTAssertNil(loaded.presentation?.artworkURL)
        XCTAssertFalse(
            String(
                decoding: try Data(contentsOf: store.fileURL),
                as: UTF8.self
            ).contains("SECRET")
        )
    }

    func testProfileDeletionMarkerSurvivesModelRelaunch() throws {
        let root = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent(
            "PlozzWatchlistDeletionTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let first = WatchlistModel(storageDirectory: root)
        try first.activate(profileID: "removed")
        try first.add(
            profileID: "removed",
            aliasID: MediaAliasID(),
            kind: .movie
        )
        try first.removeProfile("removed")

        let relaunched = WatchlistModel(storageDirectory: root)
        XCTAssertThrowsError(try relaunched.hydrate(profileID: "removed"))
        try relaunched.activate(profileID: "removed")
        XCTAssertTrue(relaunched.activeSnapshot.orderedEntries.isEmpty)
    }

    func testOrderingPersistsAcrossRelaunch() throws {
        let root = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent(
            "PlozzWatchlistOrderingTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let first = MediaAliasID()
        let second = MediaAliasID()
        let native = MediaAliasID()
        let original = WatchlistModel(storageDirectory: root)
        try original.activate(profileID: "p")
        try original.add(profileID: "p", aliasID: first, kind: .movie)
        try original.add(profileID: "p", aliasID: second, kind: .series)
        let destination = WatchlistDestinationID(rawValue: "native")!
        var view = NativeWatchlistView()
        view.applySuccess(
            destinationID: destination,
            entries: [NativeWatchlistEntry(aliasID: native, kind: .movie, index: 0)!]
        )

        let relaunched = WatchlistModel(storageDirectory: root)
        try relaunched.activate(profileID: "p")

        XCTAssertEqual(
            relaunched.union(
                profileID: "p",
                nativeView: view,
                aliasSnapshot: .empty,
                enabledDestinationIDs: [destination]
            ).orderedEntries.map(\.aliasID),
            [second, first, native]
        )
    }

    func testPresentationEnrichmentDoesNotReorderEntries() throws {
        let model = WatchlistModel()
        let first = MediaAliasID()
        let second = MediaAliasID()
        try model.activate(profileID: "p")
        try model.add(profileID: "p", aliasID: first, kind: .movie)
        try model.add(profileID: "p", aliasID: second, kind: .series)
        let before = model.activeSnapshot.orderedEntries.map(\.aliasID)
        let aliasSnapshot = MediaAliasSnapshot(records: [
            MediaAliasRecord(
                id: first,
                kind: .movie,
                presentation: MediaAliasPresentation(
                    title: "Enriched Movie",
                    year: 2020
                )
            )!,
            MediaAliasRecord(
                id: second,
                kind: .series,
                presentation: MediaAliasPresentation(
                    title: "Enriched Series",
                    year: 2021
                )
            )!
        ])

        try model.reconcileAliases(
            profileID: "p",
            aliasSnapshot: aliasSnapshot
        )
        _ = try model.presentationSnapshot(
            profileID: "p",
            union: model.union(
                profileID: "p",
                nativeView: .empty,
                aliasSnapshot: aliasSnapshot,
                enabledDestinationIDs: []
            ),
            aliasSnapshot: aliasSnapshot,
            currentItemsByAliasID: [:]
        )

        XCTAssertEqual(
            model.snapshotsByProfile["p"]?.orderedEntries.map(\.aliasID),
            before
        )
    }

    func testRedirectedTombstoneDoesNotMoveActiveWinner() {
        let neighbor = MediaAliasID()
        let winner = MediaAliasID()
        let tombstone = MediaAliasID()
        let now = Date()
        let intents = [
            WatchlistIntent(
                aliasID: neighbor,
                kind: .movie,
                desiredState: .present,
                rank: 0,
                orderingRank: 0,
                origin: .local,
                changedAt: now
            )!,
            WatchlistIntent(
                aliasID: winner,
                kind: .movie,
                desiredState: .present,
                rank: 1,
                orderingRank: 5,
                origin: .local,
                changedAt: now
            )!,
            WatchlistIntent(
                aliasID: tombstone,
                kind: .movie,
                desiredState: .absent,
                rank: 2,
                orderingRank: -100,
                origin: .local,
                changedAt: now.addingTimeInterval(-1)
            )!
        ]
        let aliasSnapshot = MediaAliasSnapshot(records: [
            MediaAliasRecord(id: neighbor, kind: .movie)!,
            MediaAliasRecord(id: winner, kind: .movie)!,
            MediaAliasRecord(
                id: tombstone,
                kind: .movie,
                redirectTarget: winner
            )!
        ])

        let snapshot = WatchlistSnapshot(
            intents: intents,
            aliasSnapshot: aliasSnapshot
        )

        XCTAssertEqual(
            snapshot.orderedEntries.map(\.aliasID),
            [neighbor, winner]
        )
    }

    func testUnvalidatedSyncedHintStaysUnownedUntilLocalCopyReplacesInPlace() throws {
        let model = WatchlistModel()
        let older = MediaAliasID()
        let newer = MediaAliasID()
        try model.activate(profileID: "p")
        try model.add(
            profileID: "p",
            aliasID: older,
            kind: .movie,
            presentation: MediaAliasPresentation(title: "Older", year: 2020)
        )
        try model.add(
            profileID: "p",
            aliasID: newer,
            kind: .movie,
            presentation: MediaAliasPresentation(title: "Newer", year: 2021)
        )
        let binding = MediaAliasProviderBindingKey(
            providerKind: .plex,
            accountDescriptorID: "account",
            providerItemID: "global"
        )!
        let aliasSnapshot = MediaAliasSnapshot(records: [
            MediaAliasRecord(
                id: older,
                kind: .movie,
                presentation: MediaAliasPresentation(
                    title: "Older",
                    year: 2020
                )
            )!,
            MediaAliasRecord(
                id: newer,
                kind: .movie,
                presentation: MediaAliasPresentation(
                    title: "Newer",
                    year: 2021
                ),
                bindingHints: [
                    MediaAliasProviderBindingHint(binding: binding)
                ],
                locallyValidatedBindings: []
            )!
        ])

        let fallback = try model.presentationSnapshot(
            profileID: "p",
            union: model.union(
                profileID: "p",
                nativeView: .empty,
                aliasSnapshot: aliasSnapshot,
                enabledDestinationIDs: []
            ),
            aliasSnapshot: aliasSnapshot,
            currentItemsByAliasID: [:]
        )
        XCTAssertEqual(fallback.map(\.id), [newer, older])
        XCTAssertTrue(
            fallback.allSatisfy {
                !$0.item.locallyValidatedPlayableSource
            }
        )

        let localCopy = MediaItem(
            id: "local-rating-key",
            title: "Newer",
            kind: .movie,
            locallyValidatedPlayableSource: true,
            sourceAccountID: "account"
        )
        let enriched = try model.presentationSnapshot(
            profileID: "p",
            union: model.union(
                profileID: "p",
                nativeView: .empty,
                aliasSnapshot: aliasSnapshot,
                enabledDestinationIDs: []
            ),
            aliasSnapshot: aliasSnapshot,
            currentItemsByAliasID: [newer: localCopy]
        )
        XCTAssertEqual(enriched.map(\.id), [newer, older])
        XCTAssertEqual(enriched.first?.item.id, "local-rating-key")
        XCTAssertTrue(
            enriched.first?.item.locallyValidatedPlayableSource == true
        )
    }

    /// Retiring a big imported ledger persists once, whatever its size — this
    /// runs on activate, in front of the first paint.
    func testRetiringImportedIntentsPersistsOnceAtOneAndTenThousand() throws {
        for count in [1_000, 10_000] {
            let store = CountingWatchlistIntentStore()
            try store.save(WatchlistIntentStoreState(
                intents: (0..<count).map { index in
                    WatchlistIntent(
                        aliasID: MediaAliasID(),
                        kind: .movie,
                        desiredState: .present,
                        rank: UInt64(index),
                        origin: .nativeImport
                    )!
                }
            ))
            let model = WatchlistModel(storeFactory: { _ in store })
            store.saveCount = 0
            try model.activate(profileID: "p")

            let retired = try model.retireNativeImports(profileID: "p")

            XCTAssertEqual(retired, count)
            XCTAssertEqual(store.saveCount, 1)
            XCTAssertTrue(store.current.intents.isEmpty)
        }
    }

    func testRemoteApplyRejectsPoisonIndividuallyAndIgnoresDeletedProfile() throws {
        let model = WatchlistModel()
        try model.activate(profileID: "valid")
        let goodAlias = MediaAliasID()
        let poisonAlias = MediaAliasID()
        let goodKey = WatchlistMediaStateRecordKey(
            profileID: "valid",
            aliasID: goodAlias
        )
        let poisonKey = WatchlistMediaStateRecordKey(
            profileID: "valid",
            aliasID: poisonAlias
        )
        let intent = WatchlistIntent(
            aliasID: goodAlias,
            kind: .movie,
            desiredState: .present,
            rank: 0,
            origin: .cloud
        )!
        let report = try model.applyRemoteSyncRecords(
            profileID: "valid",
            changes: [
                goodKey: CanonicalJSON.encode(
                    WatchlistIntentSyncDTO(intent: intent)
                )!,
                poisonKey: Data("poison".utf8)
            ]
        )
        XCTAssertEqual(report.appliedRecordNames, [goodKey.recordName])
        XCTAssertEqual(report.rejectedRecordNames, [poisonKey.recordName])
        XCTAssertTrue(model.activeSnapshot.contains(aliasID: goodAlias))

        try model.activate(profileID: "deleted")
        try model.removeProfile("deleted")
        let deletedKey = WatchlistMediaStateRecordKey(
            profileID: "deleted",
            aliasID: MediaAliasID()
        )
        let deletedReport = try model.applyRemoteSyncRecords(
            profileID: "deleted",
            changes: [deletedKey: Data("ignored".utf8)]
        )
        XCTAssertEqual(
            deletedReport.ignoredDeletedProfileRecordNames,
            [deletedKey.recordName]
        )
        XCTAssertTrue(deletedReport.rejectedRecordNames.isEmpty)
    }

    /// Removing a title whose presence came from a DESTINATION's own list — a
    /// show added on Plex rather than in Plozz — has to be visible to a caller
    /// that memoizes membership against O(1) counts.
    ///
    /// It is the one removal that leaves the active count alone: there was no
    /// local `.present` intent to retire, so the removal only writes a
    /// tombstone. A revision built from active ids alone was byte-identical
    /// before and after, the memoized membership set was served again, and the
    /// bookmark on the page kept rendering "on the watchlist" for a title that
    /// had really come off it.
    func testRemovingNativeOnlyTitleIsVisibleToCountBasedMembershipCaching() throws {
        let model = WatchlistModel()
        let series = MediaAliasID()
        let destination = WatchlistDestinationID(rawValue: "plex-discover")!
        try model.activate(profileID: "p")

        var view = NativeWatchlistView()
        view.applySuccess(
            destinationID: destination,
            entries: [NativeWatchlistEntry(aliasID: series, kind: .series, index: 0)!]
        )
        func membership() -> WatchlistUnion {
            model.union(
                profileID: "p",
                nativeView: view,
                aliasSnapshot: .empty,
                enabledDestinationIDs: [destination]
            )
        }

        XCTAssertTrue(membership().activeAliasIDs.contains(series))
        let before = model.activeSnapshot

        try model.remove(profileID: "p", aliasID: series, kind: .series)

        let after = model.activeSnapshot
        XCTAssertFalse(membership().activeAliasIDs.contains(series))
        // The blind spot itself: the count every other watchlist input is
        // derived from does not move here…
        XCTAssertEqual(before.activeAliasIDs.count, after.activeAliasIDs.count)
        // …and the tombstone is the only signal that anything happened, so any
        // membership revision has to include it.
        XCTAssertEqual(before.tombstoneCount, 0)
        XCTAssertEqual(after.tombstoneCount, 1)
    }
}

private final class CountingWatchlistIntentStore:
    WatchlistIntentStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var state = WatchlistIntentStoreState.empty
    var saveCount = 0
    var current: WatchlistIntentStoreState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }
    func load() throws -> WatchlistIntentStoreState { current }
    func save(_ state: WatchlistIntentStoreState) throws {
        lock.lock()
        self.state = state
        saveCount += 1
        lock.unlock()
    }
    func destructiveRemove() throws {
        lock.lock()
        state = .empty
        lock.unlock()
    }
}
