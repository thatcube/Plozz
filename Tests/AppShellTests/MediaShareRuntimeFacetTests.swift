import XCTest
import CoreModels
import FeatureAuth
import MediaTransportCore
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

    /// Builds a facet backed by a spy runtime that records every `revision:` pushed
    /// to `setPreferredAccountKeys`, so a test can assert the monotonic-revision input
    /// the runtime's stale-out-of-order guard relies on.
    private func makeFacetWithSpy() -> (MediaShareRuntimeFacet, SpyShareRuntime) {
        let store = AccountStore(secureStore: InMemorySecureStore())
        let profiles = ProfilesModel(store: ProfileStore(defaults: makeDefaults()))
        let hub = AccountsProvidersModel(
            accountStore: store,
            registry: ProviderRegistry(),
            profilesModel: profiles
        )
        let spy = SpyShareRuntime()
        let facet = MediaShareRuntimeFacet(runtime: spy, accountsProviders: hub)
        return (facet, spy)
    }

    /// Polls `condition` until true or the timeout elapses, yielding between checks so
    /// the fire-and-forget `Task { await runtime.setPreferredAccountKeys(...) }` can run.
    @discardableResult
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 2_000_000) // 2ms
        }
        return await condition()
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

    /// Successive `setActiveShareAccounts` calls push STRICTLY INCREASING revisions to
    /// the runtime — the monotonic input the runtime's stale-out-of-order propagation
    /// guard depends on so a slow, superseded update can't overwrite a newer active
    /// set. Exercised across a shrink (2 → 1 shares) then a grow (1 → 2) to prove the
    /// revision keeps climbing regardless of whether the set itself grows or shrinks.
    func testSetActiveShareAccountsPushesStrictlyIncreasingRevisions() async {
        let (facet, spy) = makeFacetWithSpy()
        let shareA = account(id: "share-a", provider: .mediaShare)
        let shareB = account(id: "share-b", provider: .mediaShare)
        let all = [shareA, shareB]

        facet.setActiveShareAccounts(["share-a", "share-b"], accounts: all) // both active
        facet.setActiveShareAccounts(["share-a"], accounts: all)            // shrink → one
        facet.setActiveShareAccounts(["share-a", "share-b"], accounts: all) // grow → two

        let sawAll = await waitUntil { spy.revisionCount() == 3 }
        XCTAssertTrue(sawAll, "each setActiveShareAccounts should push one preferred-keys update")

        // The three fire-and-forget propagation Tasks may DELIVER out of order, but the
        // revision VALUES assigned synchronously per call must be strictly increasing
        // and distinct — that monotonic value is exactly what the runtime's
        // stale-out-of-order guard keys off to reject a superseded update.
        let revisions = spy.recordedRevisions()
        XCTAssertEqual(revisions.count, 3)
        XCTAssertEqual(Set(revisions).count, 3, "each call must push a DISTINCT revision")
        let sorted = revisions.sorted()
        for (earlier, later) in zip(sorted, sorted.dropFirst()) {
            XCTAssertLessThan(earlier, later, "revisions must be strictly increasing (monotonic guard input)")
        }
        XCTAssertEqual(sorted, [1, 2, 3], "revisions start at 1 and increment by one per call")
        // And the observable active set still reflects the final call.
        XCTAssertEqual(facet.activeShareAccounts, ["share-a", "share-b"])
    }

}

// MARK: - Test doubles

/// A spy ``MediaShareRuntime`` that records every `revision:` passed to
/// `setPreferredAccountKeys`, so a test can assert the facet's monotonic-revision
/// contract without standing up the real catalog/transport runtime. Everything else
/// is an inert stub — the facet only drives `configure` (fire-and-forget) and
/// `setPreferredAccountKeys` in these tests.
private final class SpyShareRuntime: MediaShareRuntime, @unchecked Sendable {
    private let lock = NSLock()
    private var revisions: [UInt64] = []
    private let resolver = StubNetworkFileResolver()

    var networkFileResolver: any MediaTransportNetworkFileResolving { resolver }

    func registerProvider(into registry: ProviderRegistry, durableLocalStateStore: DurableLocalStateStore?) {}
    func configure(reporter: ShareScanReporter) async {}
    func invalidate(accountKey: String) async {}
    func retire(accountID: String, credentialRevision: CredentialRevision) async {}

    func setPreferredAccountKeys(_ accountKeys: Set<String>, revision: UInt64) async {
        lock.lock()
        revisions.append(revision)
        lock.unlock()
    }

    func recordedRevisions() -> [UInt64] {
        lock.lock(); defer { lock.unlock() }
        return revisions
    }

    func revisionCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return revisions.count
    }
}

/// Inert network-file resolver for the spy runtime; never invoked by these tests.
private struct StubNetworkFileResolver: MediaTransportNetworkFileResolving {
    func resolve(_ locator: NetworkFileLocator) async throws -> MediaTransportResolvedSource {
        throw CancellationError()
    }
}
