import XCTest
import CoreModels
import FeatureAuth
import MediaTransportCore
@testable import AppShell

/// Locks the Step 6 facet forwarding: the metadata settings surface delegates
/// diagnostics, cache-budget application, and clear to the underlying runtime.
@MainActor
final class MediaShareRuntimeFacetMetadataTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "FacetMetadataTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeFacet() -> (MediaShareRuntimeFacet, MetadataSpyRuntime) {
        let store = AccountStore(secureStore: InMemorySecureStore())
        let profiles = ProfilesModel(store: ProfileStore(defaults: makeDefaults()))
        let hub = AccountsProvidersModel(
            accountStore: store, registry: ProviderRegistry(), profilesModel: profiles
        )
        let spy = MetadataSpyRuntime()
        return (MediaShareRuntimeFacet(runtime: spy, accountsProviders: hub), spy)
    }

    func testDiagnosticsSnapshotForwards() async {
        let (facet, spy) = makeFacet()
        let snapshot = await facet.metadataDiagnosticsSnapshot()
        XCTAssertEqual(spy.snapshotCalls, 1)
        XCTAssertEqual(snapshot.metadataCacheBytes, 4242)
    }

    func testApplyCacheBudgetsForwards() async {
        let (facet, spy) = makeFacet()
        await facet.applyCacheBudgets(CacheBudgetSettings(artworkCacheBytes: 32 * 1024 * 1024, metadataCacheBytes: 8 * 1024 * 1024))
        XCTAssertEqual(spy.appliedBudgets?.metadataCacheBytes, 8 * 1024 * 1024)
    }

    func testClearForwards() async {
        let (facet, spy) = makeFacet()
        await facet.clearMetadataCaches()
        XCTAssertEqual(spy.clearCalls, 1)
    }
}

private final class MetadataSpyRuntime: MediaShareRuntime, @unchecked Sendable {
    var snapshotCalls = 0
    var clearCalls = 0
    var appliedBudgets: CacheBudgetSettings?

    private let resolver = InertResolver()
    var networkFileResolver: any MediaTransportNetworkFileResolving { resolver }

    func registerProvider(into registry: ProviderRegistry, durableLocalStateStore: DurableLocalStateStore?) {}
    func configure(reporter: ShareScanReporter) async {}
    func invalidate(accountKey: String) async {}
    func retire(accountID: String, credentialRevision: CredentialRevision) async {}
    func setPreferredAccountKeys(_ accountKeys: Set<String>, revision: UInt64) async {}

    func metadataDiagnosticsSnapshot() async -> MetadataEnrichmentDiagnosticsSnapshot {
        snapshotCalls += 1
        return MetadataEnrichmentDiagnosticsSnapshot(metadataCacheBytes: 4242)
    }

    func applyCacheBudgets(_ settings: CacheBudgetSettings) async {
        appliedBudgets = settings
    }

    func clearMetadataCaches() async {
        clearCalls += 1
    }
}

private struct InertResolver: MediaTransportNetworkFileResolving {
    func resolve(_ locator: NetworkFileLocator) async throws -> MediaTransportResolvedSource {
        throw CancellationError()
    }
}
