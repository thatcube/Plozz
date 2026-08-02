import CoreModels
import XCTest
@testable import FeatureWatchlistCore

@MainActor
final class WatchlistModelTests: XCTestCase {
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
        try model.markNativeImportComplete(
            profileID: "p",
            destinationID: destination
        )

        let metadata = try model.migrationMetadata(profileID: "p")
        XCTAssertNotNil(metadata.legacyHomeSeedCompletedAt)
        XCTAssertTrue(metadata.hasCompletedNativeImport(destinationID: "native"))
        XCTAssertEqual(model.activeSnapshot.orderedEntries.count, 1)
    }

    func testNativeImportIsAdditiveAndExplicitRemovalNeedsAbsenceBoundary() throws {
        let model = WatchlistModel()
        let alias = MediaAliasID()
        let destination = WatchlistDestinationID(rawValue: "native")!
        try model.activate(profileID: "p")
        XCTAssertTrue(try model.importNative(
            profileID: "p",
            aliasID: alias,
            kind: .movie,
            destinationID: destination
        ))
        try model.remove(profileID: "p", aliasID: alias, kind: .movie)
        XCTAssertFalse(try model.importNative(
            profileID: "p",
            aliasID: alias,
            kind: .movie,
            destinationID: destination
        ))
        XCTAssertTrue(try model.importNative(
            profileID: "p",
            aliasID: alias,
            kind: .movie,
            destinationID: destination,
            observedAfterConfirmedAbsence: true
        ))
        XCTAssertTrue(model.activeSnapshot.contains(aliasID: alias))
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

    func testNativeImportBatchPersistsOnceAtOneAndTenThousand() throws {
        for count in [1_000, 10_000] {
            let store = CountingWatchlistIntentStore()
            let model = WatchlistModel(storeFactory: { _ in store })
            try model.activate(profileID: "p")
            let candidates = (0..<count).map { _ in
                WatchlistNativeImportCandidate(
                    aliasID: MediaAliasID(),
                    kind: .movie
                )
            }

            let imported = try model.importNativeBatch(
                profileID: "p",
                destinationID: WatchlistDestinationID(rawValue: "native")!,
                candidates: candidates
            )

            XCTAssertEqual(imported, count)
            XCTAssertEqual(store.saveCount, 1)
            XCTAssertEqual(store.current.intents.count, count)
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
}

private final class CountingWatchlistIntentStore:
    WatchlistIntentStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var state = WatchlistIntentStoreState.empty
    private(set) var saveCount = 0
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
