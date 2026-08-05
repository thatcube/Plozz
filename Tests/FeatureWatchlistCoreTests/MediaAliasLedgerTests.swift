import CoreModels
import Foundation
import Observation
import XCTest
@testable import FeatureWatchlistCore

final class MediaAliasLedgerTests: XCTestCase {
    func testProfileIsolationAndProfileRemoval() async throws {
        let model = await MediaAliasLedgerModel()
        let request = evidence(.movie, title: "One", year: 2020)

        let first = try await model.resolveOrCreate(profileID: "p1", evidence: request)
        let secondLookup = try await model.lookup(profileID: "p2", evidence: request)
        XCTAssertNil(secondLookup)
        let second = try await model.resolveOrCreate(profileID: "p2", evidence: request)
        XCTAssertNotEqual(first, second)
        let captured = try await model.captureAllAliasSyncRecords(profileIDs: ["p1", "p2"])
        XCTAssertEqual(captured.count, 2)
        XCTAssertTrue(captured.keys.contains {
            MediaStateRecordKey.parse($0)?.profileID == "p1"
        })
        XCTAssertTrue(captured.keys.contains {
            MediaStateRecordKey.parse($0)?.profileID == "p2"
        })

        try await model.removeProfile("p1")
        let removedLookup = try await model.lookup(profileID: "p1", evidence: request)
        let retainedLookup = try await model.lookup(profileID: "p2", evidence: request)
        XCTAssertNil(removedLookup)
        XCTAssertEqual(retainedLookup, second)
    }

    func testDurableReloadPreservesAliasID() async throws {
        let secure = AliasSecureStoreDouble()
        let durable = try DurableLocalStateStore(secureStore: secure)
        let firstStore = try DurableMediaAliasStore(store: durable, profileID: "p1")
        let firstLedger = try MediaAliasLedger(profileID: "p1", store: firstStore)
        let request = evidence(.series, title: "Show", year: 2024)
        let id = try await firstLedger.resolveOrCreate(evidence: request)

        let reloaded = try MediaAliasLedger(
            profileID: "p1",
            store: try DurableMediaAliasStore(store: durable, profileID: "p1")
        )
        let found = await reloaded.lookup(evidence: request)
        XCTAssertEqual(found, id)
    }

    func testAtomicFileStoreMigratesLegacyStateAndReloads() throws {
        let directory = testStorageDirectory()
        defer {
            XCTAssertNoThrow(try FileManager.default.removeItem(at: directory))
        }
        let legacyRecord = record(
            id: id(1),
            createdAt: 1,
            strong: [strong(.movie, .tmdb, "1")]
        )
        let legacy = InMemoryMediaAliasStore(
            MediaAliasLedgerState(records: [legacyRecord])
        )
        let store = try AtomicFileMediaAliasStore(
            directoryURL: directory,
            profileID: "profile:one",
            legacyStore: legacy
        )

        XCTAssertEqual(try store.load().records, [legacyRecord])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))
        try legacy.remove()

        let reloaded = try AtomicFileMediaAliasStore(
            directoryURL: directory,
            profileID: "profile:one",
            legacyStore: legacy
        )
        XCTAssertEqual(try reloaded.load().records, [legacyRecord])
    }

    func testAtomicFileStoreCorruptionSurfaces() throws {
        let directory = testStorageDirectory()
        defer {
            XCTAssertNoThrow(try FileManager.default.removeItem(at: directory))
        }
        let store = try AtomicFileMediaAliasStore(
            directoryURL: directory,
            profileID: "corrupt"
        )
        try store.save(MediaAliasLedgerState(records: [
            record(
                id: id(1),
                createdAt: 1,
                strong: [strong(.movie, .tmdb, "1")]
            )
        ]))
        try Data("{".utf8).write(to: store.fileURL, options: [.atomic])

        XCTAssertThrowsError(try store.load()) {
            XCTAssertEqual($0 as? DurableLocalStateError, .malformedPayload)
        }
    }

    func testAtomicFileStoreRejectsStaleWriter() throws {
        let directory = testStorageDirectory()
        defer {
            XCTAssertNoThrow(try FileManager.default.removeItem(at: directory))
        }
        let first = try AtomicFileMediaAliasStore(
            directoryURL: directory,
            profileID: "shared"
        )
        let second = try AtomicFileMediaAliasStore(
            directoryURL: directory,
            profileID: "shared"
        )
        XCTAssertEqual(try first.load(), .empty)
        XCTAssertEqual(try second.load(), .empty)

        try first.save(MediaAliasLedgerState(records: [
            record(id: id(1), createdAt: 1, strong: [strong(.movie, .tmdb, "1")])
        ]))
        XCTAssertThrowsError(try second.save(MediaAliasLedgerState(records: [
            record(id: id(2), createdAt: 2, strong: [strong(.movie, .tmdb, "2")])
        ]))) {
            XCTAssertEqual($0 as? DurableLocalStateError, .writeConflict)
        }
    }

    func testCorruptDurableLoadThrowsInsteadOfReplacingWithEmpty() async throws {
        let secure = AliasSecureStoreDouble()
        let durable = try DurableLocalStateStore(secureStore: secure)
        let ledger = try MediaAliasLedger(
            profileID: "corrupt",
            store: try DurableMediaAliasStore(store: durable, profileID: "corrupt")
        )
        _ = try await ledger.resolveOrCreate(
            evidence: evidence(.movie, title: "One", year: 2020)
        )
        secure.corruptFirstValue(containing: "mediaAliasLedger", excluding: "manifest")

        XCTAssertThrowsError(try MediaAliasLedger(
            profileID: "corrupt",
            store: try DurableMediaAliasStore(store: durable, profileID: "corrupt")
        ))
    }

    func testWriteFailurePreservesLastGoodSnapshot() async throws {
        let store = ControllableAliasStore()
        let ledger = try MediaAliasLedger(profileID: "p", store: store)
        let firstRequest = evidence(.movie, title: "One", year: 2020)
        let first = try await ledger.resolveOrCreate(evidence: firstRequest)
        store.failWrites = true

        do {
            _ = try await ledger.resolveOrCreate(
                evidence: evidence(.movie, title: "Two", year: 2021)
            )
            XCTFail("Expected write failure")
        } catch AliasStoreFailure.write {
        }

        let snapshot = await ledger.snapshot()
        XCTAssertEqual(snapshot.recordCount, 1)
        XCTAssertEqual(snapshot.record(for: first)?.id, first)
    }

    func testDurableChunkWriteFailureLeavesPreviousGenerationLoadable() async throws {
        let secure = AliasSecureStoreDouble()
        let durable = try DurableLocalStateStore(secureStore: secure)
        let ledger = try MediaAliasLedger(
            profileID: "atomic",
            store: try DurableMediaAliasStore(store: durable, profileID: "atomic")
        )
        let firstRequest = evidence(.movie, title: "One", year: 2020)
        let first = try await ledger.resolveOrCreate(evidence: firstRequest)
        secure.failNextWrite = true

        do {
            _ = try await ledger.resolveOrCreate(
                evidence: evidence(.movie, title: "Two", year: 2021)
            )
            XCTFail("Expected durable write failure")
        } catch AliasStoreFailure.write {
        }
        let unchanged = await ledger.snapshot()
        XCTAssertEqual(unchanged.recordCount, 1)

        let reloaded = try MediaAliasLedger(
            profileID: "atomic",
            store: try DurableMediaAliasStore(store: durable, profileID: "atomic")
        )
        let reloadedSnapshot = await reloaded.snapshot()
        XCTAssertEqual(reloadedSnapshot.recordCount, 1)
        XCTAssertEqual(reloadedSnapshot.record(for: first)?.id, first)
    }

    func testFailedProfileRemovalPreservesPublishedSnapshot() async throws {
        let store = ControllableAliasStore()
        let ledger = try MediaAliasLedger(profileID: "p", store: store)
        _ = try await ledger.resolveOrCreate(
            evidence: evidence(.movie, title: "One", year: 2020)
        )
        store.failWrites = true

        do {
            try await ledger.removeForProfileDeletion()
            XCTFail("Expected removal failure")
        } catch AliasStoreFailure.write {
        }
        let snapshot = await ledger.snapshot()
        XCTAssertEqual(snapshot.recordCount, 1)
    }

    func testLoadFailureSurfaces() {
        let store = ControllableAliasStore()
        store.failLoads = true
        XCTAssertThrowsError(try MediaAliasLedger(profileID: "p", store: store)) {
            XCTAssertEqual($0 as? AliasStoreFailure, .load)
        }
    }

    func testRemoteDeletionAndDuplicateRedirectPersistAcrossReload() async throws {
        let shared = strong(.movie, .imdb, "tt1")
        let winner = record(
            id: id(1),
            createdAt: 1,
            strong: [shared, strong(.movie, .tmdb, "1")]
        )
        let loser = record(
            id: id(2),
            createdAt: 2,
            strong: [shared, strong(.movie, .tvdb, "2")]
        )
        let store = InMemoryMediaAliasStore()
        let ledger = try MediaAliasLedger(profileID: "p", store: store)

        try await ledger.mergeRemote(records: [
            MediaAliasSyncDTO(record: loser),
            MediaAliasSyncDTO(record: winner),
        ])
        var snapshot = await ledger.snapshot()
        XCTAssertEqual(snapshot.resolvedAliasID(for: loser.id), winner.id)

        let reloaded = try MediaAliasLedger(profileID: "p", store: store)
        snapshot = await reloaded.snapshot()
        XCTAssertEqual(snapshot.resolvedAliasID(for: loser.id), winner.id)

        try await reloaded.mergeRemote(records: [], deletedAliasIDs: [loser.id])
        snapshot = await reloaded.snapshot()
        XCTAssertNil(snapshot.recordsByID[loser.id])
        XCTAssertNotNil(snapshot.recordsByID[winner.id])
    }

    func testCanonicalRemoteApplyRecapturesExactBytes() async throws {
        let localBinding = MediaAliasProviderBindingKey(
            providerKind: .plex,
            accountDescriptorID: "00000000-0000-0000-0000-000000000010",
            providerItemID: "8"
        )!
        let hint = MediaAliasProviderBindingHint(binding: localBinding)
        let local = MediaAliasRecord(
            id: id(1),
            kind: .movie,
            bindingHints: [hint],
            locallyValidatedBindings: [localBinding]
        )!
        let store = InMemoryMediaAliasStore(
            MediaAliasLedgerState(records: [local])
        )
        let ledger = try MediaAliasLedger(profileID: "p", store: store)
        var incoming = local
        incoming.presentation = MediaAliasPresentation(title: "Remote", year: 2020)
        let dto = MediaAliasSyncDTO(record: incoming)
        let bytes = CanonicalJSON.encode(dto)!

        try await ledger.mergeRemote(records: [
            CanonicalJSON.decode(MediaAliasSyncDTO.self, from: bytes)!
        ])
        let captured = await ledger.captureSyncDTOs()
        let snapshot = await ledger.snapshot()

        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(CanonicalJSON.encode(captured[0]), bytes)
        XCTAssertEqual(
            snapshot.recordsByID[local.id]?.locallyValidatedBindings,
            [localBinding]
        )
    }

    func testEqualTimestampPresentationConflictsConvergeDeterministically() throws {
        let timestamp = Date(timeIntervalSince1970: 10)
        let first = try XCTUnwrap(MediaAliasRecord(
            id: id(1),
            kind: .movie,
            createdAt: timestamp,
            updatedAt: timestamp,
            presentation: MediaAliasPresentation(
                title: "Zulu",
                year: 2020,
                artworkURL: "https://first.example/art.jpg"
            )
        ))
        let second = try XCTUnwrap(MediaAliasRecord(
            id: id(1),
            kind: .movie,
            createdAt: timestamp,
            updatedAt: timestamp,
            presentation: MediaAliasPresentation(
                title: "Alpha",
                year: 2021,
                artworkURL: "https://second.example/art.jpg"
            )
        ))

        let firstResult = try XCTUnwrap(
            MediaAliasSyncDTO(record: second).applying(to: first)
        )
        let secondResult = try XCTUnwrap(
            MediaAliasSyncDTO(record: first).applying(to: second)
        )

        XCTAssertEqual(firstResult.presentation?.title, "Alpha")
        XCTAssertEqual(secondResult.presentation?.title, "Alpha")
        XCTAssertEqual(
            MediaAliasSyncDTO(record: firstResult),
            MediaAliasSyncDTO(record: secondResult)
        )
        XCTAssertEqual(
            firstResult.presentation?.artworkURL,
            "https://first.example/art.jpg"
        )
        XCTAssertEqual(
            secondResult.presentation?.artworkURL,
            "https://second.example/art.jpg"
        )
    }

    func testMalformedRemoteRecordDoesNotPoisonValidBatch() async throws {
        let model = await MediaAliasLedgerModel()
        let valid = record(
            id: id(1),
            createdAt: 1,
            strong: [strong(.movie, .tmdb, "1")]
        )
        let validKey = MediaStateRecordKey(profileID: "p", aliasID: valid.id)
        let invalidKey = MediaStateRecordKey(profileID: "p", aliasID: id(2))

        let report = try await model.applyRemoteChanges([
            validKey: CanonicalJSON.encode(MediaAliasSyncDTO(record: valid)),
            invalidKey: Data("{".utf8),
        ])

        XCTAssertEqual(report.rejectedRecordNames, [invalidKey.recordName])
        let snapshot = await model.snapshotsByProfile["p"]
        XCTAssertEqual(snapshot?.recordsByID[valid.id]?.id, valid.id)
    }

    func testCapturePreservesFallbackUntilProfileIsExplicitlyRemoved() async throws {
        let model = await MediaAliasLedgerModel()
        let remote = record(
            id: id(1),
            createdAt: 1,
            strong: [strong(.movie, .tmdb, "1")]
        )
        let key = MediaStateRecordKey(profileID: "remote-profile", aliasID: remote.id)
        let bytes = CanonicalJSON.encode(MediaAliasSyncDTO(record: remote))!

        var captured = try await model.captureAllAliasSyncRecords(
            profileIDs: ["local-profile"],
            fallback: [key.recordName: bytes]
        )
        XCTAssertEqual(captured[key.recordName], bytes)

        try await model.removeProfile("remote-profile")
        captured = try await model.captureAllAliasSyncRecords(
            profileIDs: ["local-profile"],
            fallback: [key.recordName: bytes]
        )
        XCTAssertNil(captured[key.recordName])
    }

    func testProfileDeletionTombstoneSurvivesRelaunchAndSuppressesFallback() async throws {
        let directory = testStorageDirectory()
        defer {
            XCTAssertNoThrow(try FileManager.default.removeItem(at: directory))
        }
        let remote = record(
            id: id(1),
            createdAt: 1,
            strong: [strong(.movie, .tmdb, "1")]
        )
        let key = MediaStateRecordKey(profileID: "deleted", aliasID: remote.id)
        let bytes = CanonicalJSON.encode(MediaAliasSyncDTO(record: remote))!
        let first = await MediaAliasLedgerModel(storageDirectory: directory)

        try await first.removeProfile("deleted")
        let reloaded = await MediaAliasLedgerModel(storageDirectory: directory)
        let captured = try await reloaded.captureAllAliasSyncRecords(
            profileIDs: ["active"],
            fallback: [key.recordName: bytes]
        )

        XCTAssertNil(captured[key.recordName])
    }

    func testCorruptDeletionStateIsQuarantinedWithoutBrickingAliases() async throws {
        let directory = testStorageDirectory()
        defer {
            XCTAssertNoThrow(try FileManager.default.removeItem(at: directory))
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data("{".utf8).write(
            to: directory.appendingPathComponent("deleted-profiles-v1.json")
        )

        let model = await MediaAliasLedgerModel(storageDirectory: directory)
        let aliasID = try await model.resolveOrCreate(
            profileID: "active",
            evidence: MediaAliasEvidence(
                kind: .movie,
                strong: [strong(.movie, .tmdb, "1")],
                weak: MediaAliasWeakEvidence(
                    kind: .movie,
                    title: "Recovered",
                    year: 2024
                ),
                presentation: MediaAliasPresentation(
                    title: "Recovered",
                    year: 2024
                )
            )!
        )

        let recoveryOccurred = await model.deletionStateRecoveryOccurred
        let foundAliasID = try await model.lookup(
            profileID: "active",
            evidence: MediaAliasEvidence(
                kind: .movie,
                strong: [strong(.movie, .tmdb, "1")]
            )!
        )
        XCTAssertTrue(recoveryOccurred)
        XCTAssertEqual(
            foundAliasID,
            aliasID
        )
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                atPath: directory.path
            ).contains { $0.hasPrefix("deleted-profiles-v1.corrupt-") }
        )
    }

    func testFutureDeletionStateVersionPreservesKnownTombstones() async throws {
        let directory = testStorageDirectory()
        defer {
            XCTAssertNoThrow(try FileManager.default.removeItem(at: directory))
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let state = Data(#"{"profileIDs":["deleted"],"version":2}"#.utf8)
        try state.write(
            to: directory.appendingPathComponent("deleted-profiles-v1.json")
        )
        let remote = record(
            id: id(1),
            createdAt: 1,
            strong: [strong(.movie, .tmdb, "1")]
        )
        let key = MediaStateRecordKey(profileID: "deleted", aliasID: remote.id)
        let bytes = CanonicalJSON.encode(MediaAliasSyncDTO(record: remote))!

        let model = await MediaAliasLedgerModel(storageDirectory: directory)
        let captured = try await model.captureAllAliasSyncRecords(
            profileIDs: ["active"],
            fallback: [key.recordName: bytes]
        )

        let recoveryOccurred = await model.deletionStateRecoveryOccurred
        XCTAssertFalse(recoveryOccurred)
        XCTAssertNil(captured[key.recordName])
    }

    func testForwardCompatiblePayloadIsAppliedAndRecapturedByteForByte() async throws {
        let model = await MediaAliasLedgerModel()
        let remote = record(
            id: id(1),
            createdAt: 1,
            strong: [strong(.movie, .tmdb, "1")]
        )
        let key = MediaStateRecordKey(profileID: "p", aliasID: remote.id)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: CanonicalJSON.encode(MediaAliasSyncDTO(record: remote))!
            ) as? [String: Any]
        )
        object["futureField"] = ["version": 2]
        let bytes = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )

        let report = try await model.applyRemoteChanges([key: bytes])
        let captured = try await model.captureAllAliasSyncRecords(
            profileIDs: ["p"],
            fallback: [key.recordName: bytes]
        )

        XCTAssertEqual(report.forwardCompatibleRecordNames, [key.recordName])
        XCTAssertEqual(captured[key.recordName], bytes)
    }

    func testSnapshotAndEncodedSizeMetricsForOneAndTenThousandRecords() throws {
        let thousand = makeRecords(count: 1_000)
        let thousandSnapshot = MediaAliasSnapshot(records: thousand)
        let thousandMetric = try MediaAliasEncodingMetrics.measure(records: thousand)
        XCTAssertEqual(thousandMetric.recordCount, 1_000)
        XCTAssertGreaterThan(thousandMetric.encodedByteCount, 0)
        XCTAssertGreaterThan(thousandMetric.largestRecordByteCount, 0)
        XCTAssertEqual(thousandSnapshot.recordCount, 1_000)
        XCTAssertEqual(thousandSnapshot.aliasesByStrongEvidence.count, 1_000)
        XCTAssertEqual(thousandSnapshot.aliasesByValidatedBinding.count, 1_000)
        XCTAssertEqual(
            thousandSnapshot.aliases(for: strong(.movie, .tmdb, "999")).count,
            1
        )

        let tenThousand = makeRecords(count: 10_000)
        let tenThousandSnapshot = MediaAliasSnapshot(records: tenThousand)
        let tenThousandMetric = try MediaAliasEncodingMetrics.measure(
            records: tenThousand
        )
        XCTAssertEqual(thousandMetric.encodedByteCount, 666_365)
        XCTAssertEqual(thousandMetric.largestRecordByteCount, 670)
        XCTAssertEqual(tenThousandMetric.encodedByteCount, 6_727_165)
        XCTAssertEqual(tenThousandMetric.largestRecordByteCount, 678)
        XCTAssertEqual(tenThousandMetric.recordCount, 10_000)
        XCTAssertEqual(tenThousandSnapshot.recordCount, 10_000)
        XCTAssertEqual(tenThousandSnapshot.aliasesByStrongEvidence.count, 10_000)
        XCTAssertEqual(tenThousandSnapshot.aliasesByWeakEvidence.count, 10_000)
        XCTAssertEqual(tenThousandSnapshot.aliasesByValidatedBinding.count, 10_000)
        XCTAssertEqual(
            tenThousandSnapshot.aliases(for: strong(.movie, .tmdb, "9999")).count,
            1
        )
        XCTAssertEqual(
            try MediaAliasEncodingMetrics.measure(records: thousand),
            thousandMetric
        )
        XCTAssertEqual(
            try MediaAliasEncodingMetrics.measure(records: tenThousand),
            tenThousandMetric
        )
        XCTAssertGreaterThan(
            tenThousandMetric.encodedByteCount,
            thousandMetric.encodedByteCount * 9
        )
        XCTAssertLessThan(
            tenThousandMetric.encodedByteCount,
            thousandMetric.encodedByteCount * 11
        )
        XCTContext.runActivity(
            named: "1,000 aliases: \(thousandMetric.encodedByteCount) encoded bytes; largest record \(thousandMetric.largestRecordByteCount) bytes"
        ) { _ in }
        XCTContext.runActivity(
            named: "10,000 aliases: \(tenThousandMetric.encodedByteCount) encoded bytes; largest record \(tenThousandMetric.largestRecordByteCount) bytes"
        ) { _ in }
    }

    func testIdentityEnrichmentWavePersistsOnceAndNoOpWaveDoesNotPersist() async throws {
        let records = (0..<1_000).map { index in
            record(
                id: id(index + 1),
                createdAt: TimeInterval(index),
                strong: [strong(.movie, .tmdb, String(index))]
            )
        }

        let store = ControllableAliasStore(
            initialState: MediaAliasLedgerState(records: records)
        )
        let ledger = try MediaAliasLedger(profileID: "p", store: store)
        let enrichments = records.enumerated().map { index, record in
            MediaAliasEnrichment(
                aliasID: record.id,
                evidence: MediaAliasEvidence(
                    kind: .movie,
                    strong: [strong(.movie, .tmdb, String(index))],
                    weak: MediaAliasWeakEvidence(
                        kind: .movie,
                        title: "Title \(index)",
                        year: 2000
                    ),
                    presentation: MediaAliasPresentation(
                        title: "Title \(index)",
                        year: 2000
                    )
                )!
            )
        }

        let changed = try await ledger.enrich(enrichments)
        XCTAssertEqual(changed, 1_000)
        XCTAssertEqual(store.saveCount, 1)

        let unchanged = try await ledger.enrich(enrichments)
        XCTAssertEqual(unchanged, 0)
        XCTAssertEqual(
            store.saveCount,
            1,
            "an identical identity publication performs no durable write"
        )
    }

    @MainActor
    func testRepeatedActivationDoesNotRepublishUnchangedSnapshot() async throws {
        let model = MediaAliasLedgerModel()
        try await model.activate(profileID: "p")
        let changed = ObservationFlag()
        withObservationTracking {
            _ = model.snapshotsByProfile
            _ = model.activeProfileID
        } onChange: {
            changed.mark()
        }

        try await model.activate(profileID: "p")

        XCTAssertFalse(
            changed.value,
            "idempotent activation cannot re-arm the shell observation loop"
        )
    }

    private func makeRecords(count: Int) -> [MediaAliasRecord] {
        (0..<count).map { index in
            let binding = MediaAliasProviderBindingKey(
                providerKind: index.isMultiple(of: 2) ? .jellyfin : .plex,
                accountDescriptorID: "account-\(index % 4)",
                providerItemID: "item-\(index)"
            )!
            return MediaAliasRecord(
                id: id(index + 1),
                kind: .movie,
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                strongEvidence: [strong(.movie, .tmdb, String(index))],
                weakEvidence: [MediaAliasWeakEvidence(
                    kind: .movie,
                    title: "Title \(index)",
                    year: 1900 + index
                )!],
                presentation: MediaAliasPresentation(
                    title: "Title \(index)",
                    year: 1900 + index,
                    artworkURL: "https://art.example/\(index).jpg"
                ),
                bindingHints: [MediaAliasProviderBindingHint(binding: binding)],
                locallyValidatedBindings: [binding]
            )!
        }
    }

    private func testStorageDirectory() -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("media-alias-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func id(_ value: Int) -> MediaAliasID {
        let suffix = String(format: "%012llx", UInt64(value))
        return MediaAliasID(
            UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
        )
    }

    private func strong(
        _ kind: MediaItemKind,
        _ namespace: ProviderIDNamespace,
        _ value: String
    ) -> MediaAliasStrongEvidence {
        MediaAliasStrongEvidence(kind: kind, namespace: namespace, value: value)!
    }

    private func evidence(
        _ kind: MediaItemKind,
        title: String,
        year: Int
    ) -> MediaAliasEvidence {
        MediaAliasEvidence(
            kind: kind,
            weak: MediaAliasWeakEvidence(kind: kind, title: title, year: year),
            presentation: MediaAliasPresentation(title: title, year: year)
        )!
    }

    private func record(
        id: MediaAliasID,
        createdAt: TimeInterval,
        strong: [MediaAliasStrongEvidence] = [],
        weak: [MediaAliasWeakEvidence] = []
    ) -> MediaAliasRecord {
        MediaAliasRecord(
            id: id,
            kind: .movie,
            createdAt: Date(timeIntervalSince1970: createdAt),
            strongEvidence: strong,
            weakEvidence: weak
        )!
    }
}

private enum AliasStoreFailure: Error, Equatable {
    case load
    case write
}

private final class ObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var changed = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return changed
    }

    func mark() {
        lock.lock()
        changed = true
        lock.unlock()
    }
}

private final class ControllableAliasStore: MediaAliasStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var state: MediaAliasLedgerState
    private var saves = 0
    var failLoads = false
    var failWrites = false

    init(initialState: MediaAliasLedgerState = .empty) {
        state = initialState
    }

    var saveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return saves
    }

    func load() throws -> MediaAliasLedgerState {
        lock.lock()
        defer { lock.unlock() }
        if failLoads { throw AliasStoreFailure.load }
        return state
    }

    func save(_ state: MediaAliasLedgerState) throws {
        lock.lock()
        defer { lock.unlock() }
        if failWrites { throw AliasStoreFailure.write }
        self.state = state
        saves += 1
    }

    func remove() throws {
        lock.lock()
        defer { lock.unlock() }
        if failWrites { throw AliasStoreFailure.write }
        state = .empty
    }
}

private final class AliasSecureStoreDouble: SecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    var failNextWrite = false

    func setString(_ value: String, for key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if failNextWrite {
            failNextWrite = false
            throw AliasStoreFailure.write
        }
        values[key] = value
    }

    func string(for key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func readString(for key: String) throws -> String? {
        string(for: key)
    }

    func removeValue(for key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values[key] = nil
    }

    func corruptFirstValue(containing included: String, excluding excluded: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let key = values.keys.first(where: {
            $0.contains(included) && !$0.contains(excluded)
        }) else {
            XCTFail("Missing stored alias chunk")
            return
        }
        values[key] = "{"
    }
}
