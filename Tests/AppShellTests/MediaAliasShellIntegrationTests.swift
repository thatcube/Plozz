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
        XCTAssertEqual(schemas, [.configV3, .mediaStateV1])
        XCTAssertEqual(stateFileURLs.map(\.lastPathComponent), ["cloud-config-v3.json", "cloud-media-state-v1.json"])
        XCTAssertEqual(Set(stateFileURLs).count, stateFileURLs.count, "channel state files must be disjoint")
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
