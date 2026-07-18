import XCTest
import CoreModels
import FeatureAuth
@testable import AppShell

/// Unit tests for ``MediaShareRuntimeFacet`` — the media-share runtime facet split
/// out of ``AppState``. Cover the facet's own deterministic behavior: the active
/// share set is recomputed to the media-share accounts in the resolved active set,
/// a bare/unknown rescan is a safe no-op, and the network-file resolver forwards to
/// the runtime. The full scan/enrich reporting path stays covered by the media-share
/// suites through AppState.
@MainActor
final class MediaShareRuntimeFacetTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "MediaShareRuntimeFacetTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func account(id: String, provider: ProviderKind) -> Account {
        Account(
            id: id,
            server: MediaServer(
                id: "srv-\(id)",
                name: id,
                baseURL: URL(string: "https://\(id).example.com")!,
                provider: provider
            ),
            userID: "user-\(id)",
            userName: "User \(id)",
            deviceID: "device"
        )
    }

    private func makeFacet() -> (MediaShareRuntimeFacet, AccountsProvidersModel) {
        let store = AccountStore(secureStore: InMemorySecureStore())
        let profiles = ProfilesModel(store: ProfileStore(defaults: makeDefaults()))
        let hub = AccountsProvidersModel(
            accountStore: store,
            registry: ProviderRegistry(),
            profilesModel: profiles
        )
        let facet = MediaShareRuntimeFacet(
            runtime: DefaultMediaShareRuntime.make(accountStore: store),
            accountsProviders: hub
        )
        return (facet, hub)
    }

    func testSetActiveShareAccountsKeepsOnlyActiveMediaShares() {
        let (facet, _) = makeFacet()
        let share = account(id: "share-1", provider: .mediaShare)
        let otherShare = account(id: "share-2", provider: .mediaShare)
        let jellyfin = account(id: "jf-1", provider: .jellyfin)
        let all = [share, otherShare, jellyfin]

        // Only share-1 and the (non-share) jf-1 are "active"; the result must be
        // just the media-share subset of the active set → share-1.
        facet.setActiveShareAccounts(["share-1", "jf-1"], accounts: all)
        XCTAssertEqual(facet.activeShareAccounts, ["share-1"])

        // A later empty active set clears it.
        facet.setActiveShareAccounts([], accounts: all)
        XCTAssertTrue(facet.activeShareAccounts.isEmpty)
    }

    func testRescanUnknownOrNonShareAccountIsANoOp() {
        let (facet, hub) = makeFacet()
        // No accounts loaded → unknown id is a safe no-op (must not crash).
        facet.rescanShare(accountID: "missing")
        _ = hub  // hub has no accounts; nothing to assert beyond no crash.
        XCTAssertTrue(facet.activeShareAccounts.isEmpty)
    }

    func testNetworkFileResolverIsAccessible() {
        let (facet, _) = makeFacet()
        // Smoke test: the resolver forwards to the runtime and is reachable without
        // touching AppState (single-owner instance lives on the runtime).
        _ = facet.networkFileResolver
    }
}
