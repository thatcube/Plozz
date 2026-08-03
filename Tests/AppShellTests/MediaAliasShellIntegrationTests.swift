import CoreModels
import FeatureAuth
import XCTest
@testable import AppShell

@MainActor
final class MediaAliasShellIntegrationTests: XCTestCase {
    func testLocalLedgerWorksWithoutCloudAndShellApplyRecapturesExactBytes() async throws {
        let state = makeState()
        let profileID = state.profilesModel.activeProfileID
        let localEvidence = try XCTUnwrap(MediaAliasEvidence(
            kind: .movie,
            weak: MediaAliasWeakEvidence(
                kind: .movie,
                title: "Local",
                year: 2026
            )
        ))

        let localID = try await state.mediaAliasLedger.resolveOrCreate(
            profileID: profileID,
            evidence: localEvidence
        )
        let remoteRecord = try XCTUnwrap(MediaAliasRecord(
            id: MediaAliasID(
                UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
            ),
            kind: .series,
            createdAt: Date(timeIntervalSince1970: 10),
            strongEvidence: [
                MediaAliasStrongEvidence(
                    kind: .series,
                    namespace: .tmdb,
                    value: "42"
                )!,
            ],
            presentation: MediaAliasPresentation(title: "Remote", year: 2025)
        ))
        let key = MediaStateRecordKey(profileID: profileID, aliasID: remoteRecord.id)
        let bytes = try XCTUnwrap(
            CanonicalJSON.encode(MediaAliasSyncDTO(record: remoteRecord))
        )

        await state.applyMediaStateSyncRecords([key.recordName: bytes])
        let captured = await state.captureMediaStateSyncRecords(fallback: [:])

        XCTAssertNotNil(captured[
            MediaStateRecordKey(profileID: profileID, aliasID: localID).recordName
        ])
        XCTAssertEqual(captured[key.recordName], bytes)
    }

    func testConfigAndMediaServicesUseDisjointSchemasAndStateFiles() {
        let state = makeState()
        let sync = state.cloudSync

        // Config V3 remains the PRIMARY channel's defaults, unchanged by
        // multiplexing.
        XCTAssertEqual(sync?.schema, .configV3)
        XCTAssertEqual(sync?.stateFileURL.lastPathComponent, "cloud-config-v3.json")

        // One service now multiplexes BOTH channels onto the same CKSyncEngine —
        // assert their schemas + state files are disjoint rather than reaching for
        // a second service instance.
        let schemas = sync?.channelSchemas ?? []
        let stateFileURLs = sync?.channelStateFileURLs ?? []
        XCTAssertEqual(schemas, [.configV3, .mediaStateV1, .trackerTokensV1])
        XCTAssertEqual(
            stateFileURLs.map(\.lastPathComponent),
            [
                "cloud-config-v3.json",
                "cloud-media-state-v1.json",
                "cloud-tracker-tokens-v1.json"
            ]
        )
        XCTAssertEqual(Set(stateFileURLs).count, stateFileURLs.count, "channel state files must be disjoint")
        XCTAssertEqual(
            Set(schemas.map(\.zoneName)).count,
            schemas.count,
            "channel zones must be disjoint"
        )

        // Credentials must never ride in a plaintext field, and nothing else
        // should quietly start being encrypted either.
        XCTAssertEqual(
            schemas.filter(\.encryptsValue),
            [.trackerTokensV1],
            "only the tracker-token channel carries an encrypted payload"
        )
    }

    func testMediaStateChannelCapturesAndAppliesWatchlistIntentExactly() async throws {
        let state = makeState()
        let profileID = state.profilesModel.activeProfileID
        try state.universalWatchlist.activate(profileID: profileID)
        let aliasID = MediaAliasID()
        try state.universalWatchlist.add(
            profileID: profileID,
            aliasID: aliasID,
            kind: .movie
        )
        let key = WatchlistMediaStateRecordKey(
            profileID: profileID,
            aliasID: aliasID
        )
        let captured = await state.captureMediaStateSyncRecords(fallback: [:])
        let addBytes = try XCTUnwrap(captured[key.recordName])

        let tombstone = WatchlistIntent(
            aliasID: aliasID,
            kind: .movie,
            desiredState: .absent,
            rank: 0,
            origin: .cloud,
            changedAt: Date(timeIntervalSince1970: 10)
        )!
        let removeBytes = try XCTUnwrap(
            CanonicalJSON.encode(WatchlistIntentSyncDTO(intent: tombstone))
        )
        await state.applyMediaStateSyncRecords([
            key.recordName: removeBytes
        ])

        XCTAssertFalse(
            state.universalWatchlist.activeSnapshot.contains(aliasID: aliasID)
        )
        let recaptured = await state.captureMediaStateSyncRecords(
            fallback: [key.recordName: removeBytes]
        )
        XCTAssertEqual(recaptured[key.recordName], removeBytes)
        XCTAssertNotEqual(addBytes, removeBytes)
    }

    func testPoisonAndDeletedProfileRecordsDoNotBlockValidMediaState() async throws {
        let state = makeState()
        let profileID = state.profilesModel.activeProfileID
        try state.universalWatchlist.activate(profileID: profileID)
        let validAlias = MediaAliasID()
        let poisonAlias = MediaAliasID()
        let validKey = WatchlistMediaStateRecordKey(
            profileID: profileID,
            aliasID: validAlias
        )
        let poisonKey = WatchlistMediaStateRecordKey(
            profileID: profileID,
            aliasID: poisonAlias
        )
        let validIntent = WatchlistIntent(
            aliasID: validAlias,
            kind: .series,
            desiredState: .present,
            rank: 1,
            origin: .cloud
        )!
        try state.universalWatchlist.activate(profileID: "deleted")
        try state.universalWatchlist.removeProfile("deleted")
        try state.universalWatchlist.activate(profileID: profileID)
        let deletedAlias = MediaAliasID()
        let deletedKey = WatchlistMediaStateRecordKey(
            profileID: "deleted",
            aliasID: deletedAlias
        )
        let deletedIntent = WatchlistIntent(
            aliasID: deletedAlias,
            kind: .movie,
            desiredState: .present,
            rank: 0,
            origin: .cloud
        )!
        let malformedAliasKey = "alias:\(profileID):not-a-uuid"
        let malformedWatchlistKey = "watchlist:\(profileID):not-a-uuid"
        let poisonMediaAlias = MediaStateRecordKey(
            profileID: profileID,
            aliasID: MediaAliasID()
        )

        await state.applyMediaStateSyncRecords([
            validKey.recordName: CanonicalJSON.encode(
                WatchlistIntentSyncDTO(intent: validIntent)
            )!,
            poisonKey.recordName: Data("poison".utf8),
            deletedKey.recordName: CanonicalJSON.encode(
                WatchlistIntentSyncDTO(intent: deletedIntent)
            )!,
            malformedAliasKey: Data("bad-key".utf8),
            malformedWatchlistKey: Data("bad-key".utf8),
            poisonMediaAlias.recordName: Data("poison-alias".utf8)
        ])

        XCTAssertTrue(
            state.universalWatchlist.activeSnapshot.contains(aliasID: validAlias)
        )
        XCTAssertFalse(
            state.universalWatchlist.snapshotsByProfile["deleted"]?
                .contains(aliasID: deletedAlias) ?? false
        )
    }

    private func makeState() -> AppState {
        let suite = "MediaAliasShellIntegrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let profiles = ProfilesModel(store: ProfileStore(defaults: defaults))
        return AppState(
            accountStore: AccountStore(secureStore: InMemorySecureStore()),
            registry: ProviderRegistry(),
            profilesModel: profiles
        )
    }
}
