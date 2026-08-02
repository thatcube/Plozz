import XCTest
@testable import CoreModels

final class WatchlistSyncRecordTests: XCTestCase {
    func testWatchlistKeyIsIsolatedFromAliasAndConfigV3Parsers() {
        let alias = MediaAliasID()
        let key = WatchlistMediaStateRecordKey(
            profileID: "profile:with:colons",
            aliasID: alias
        )

        XCTAssertEqual(
            WatchlistMediaStateRecordKey.parse(key.recordName),
            key
        )
        XCTAssertNil(MediaStateRecordKey.parse(key.recordName))
        XCTAssertNil(SyncRecordKey.parse(key.recordName))
    }

    func testIntentDTOCanonicalRoundTripPreservesSemanticTombstone() throws {
        let intent = WatchlistIntent(
            aliasID: MediaAliasID(),
            kind: .series,
            desiredState: .absent,
            rank: 9,
            origin: .local,
            changedAt: Date(timeIntervalSince1970: 1_000),
            presentation: MediaAliasPresentation(
                title: "Series",
                year: 2020
            ),
            metadata: WatchlistIntentMetadata(
                sourceDestinationIDs: ["z", "a", "a"],
                lastExplicitRemovalAt: Date(timeIntervalSince1970: 1_000)
            )
        )!
        let first = try XCTUnwrap(
            CanonicalJSON.encode(WatchlistIntentSyncDTO(intent: intent))
        )
        let decoded = try XCTUnwrap(
            CanonicalJSON.decode(WatchlistIntentSyncDTO.self, from: first)
        )
        let second = try XCTUnwrap(CanonicalJSON.encode(decoded))

        XCTAssertEqual(first, second)
        XCTAssertEqual(decoded.makeIntent()?.desiredState, .absent)
        XCTAssertEqual(decoded.metadata.sourceDestinationIDs, ["a", "z"])
    }

    func testLogicalClockRejectsStaleAddAfterNewerRemoval() throws {
        let alias = MediaAliasID()
        let key = WatchlistMediaStateRecordKey(
            profileID: "p",
            aliasID: alias
        ).recordName
        let add = WatchlistIntent(
            aliasID: alias,
            kind: .movie,
            desiredState: .present,
            rank: 0,
            origin: .local,
            changedAt: Date(timeIntervalSince1970: 1)
        )!
        let remove = WatchlistIntent(
            aliasID: alias,
            kind: .movie,
            desiredState: .absent,
            rank: 0,
            origin: .local,
            changedAt: Date(timeIntervalSince1970: 2)
        )!
        let addBytes = try XCTUnwrap(
            CanonicalJSON.encode(WatchlistIntentSyncDTO(intent: add))
        )
        let removeBytes = try XCTUnwrap(
            CanonicalJSON.encode(WatchlistIntentSyncDTO(intent: remove))
        )
        var ledger = SyncLedger()

        let removalChanges = ledger.applyFetched(
            saved: [
                SyncRemoteRecord(
                    recordName: key,
                    value: removeBytes,
                    editedAt: 20,
                    systemFields: Data([2])
                )
            ],
            deleted: [],
            now: 20
        )
        XCTAssertEqual(removalChanges[key]!, removeBytes)

        let staleChanges = ledger.applyFetched(
            saved: [
                SyncRemoteRecord(
                    recordName: key,
                    value: addBytes,
                    editedAt: 10,
                    systemFields: Data([1])
                )
            ],
            deleted: [],
            now: 21
        )
        XCTAssertNil(staleChanges[key])
        XCTAssertEqual(ledger.syncedValues()[key], removeBytes)
    }
}
