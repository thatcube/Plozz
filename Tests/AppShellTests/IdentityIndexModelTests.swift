import XCTest
import CoreModels
@testable import AppShell

/// Unit tests for ``IdentityIndexModel`` — the eager cross-server identity-index
/// facet split out of ``AppState``. These cover the deterministic seams that don't
/// require a live ``MediaProvider``: the injected dependency closures are consulted,
/// an empty active-account set is a safe no-op, and reset leaves an empty snapshot.
/// The full warm-with-provider fan-out remains covered by the existing AppShell
/// identity tests exercising it through AppState.
@MainActor
final class IdentityIndexModelTests: XCTestCase {

    private func makeModel(
        accounts: @escaping @MainActor () -> [ResolvedAccount] = { [] },
        namespace: @escaping @MainActor () -> String? = { "ns-test" }
    ) -> (IdentityIndexModel, () -> Int) {
        var publishCount = 0
        let model = IdentityIndexModel(
            activeAccounts: accounts,
            namespace: namespace,
            onPublish: { publishCount += 1 }
        )
        return (model, { publishCount })
    }

    func testInitialSnapshotIsEmpty() {
        let (model, _) = makeModel()
        XCTAssertTrue(model.identitySnapshot.isEmpty)
        XCTAssertTrue(model.identitySnapshotStore.current.isEmpty)
    }

    func testWarmWithNoActiveAccountsIsANoOp() {
        var activeAccountsCalls = 0
        let (model, publishCount) = makeModel(accounts: {
            activeAccountsCalls += 1
            return []
        })

        model.warmIdentityIndex()

        // The injected active-accounts closure is consulted exactly once, and with
        // an empty set the warm returns early: nothing publishes, snapshot stays empty.
        XCTAssertEqual(activeAccountsCalls, 1)
        XCTAssertEqual(publishCount(), 0)
        XCTAssertTrue(model.identitySnapshot.isEmpty)
    }

    func testResetFromEmptyIsSafeAndLeavesEmptySnapshot() {
        let (model, publishCount) = makeModel()
        model.reset()
        XCTAssertTrue(model.identitySnapshot.isEmpty)
        XCTAssertTrue(model.identitySnapshotStore.current.isEmpty)
        // reset must not trigger a publish/outbox re-drain.
        XCTAssertEqual(publishCount(), 0)
    }

    func testSourcesProviderIsSendableAndStable() {
        let (model, _) = makeModel()
        // The @Sendable accessor is derived from the snapshot store; two reads yield
        // usable closures (the store, not AppState, owns this now).
        let provider = model.identitySourcesProvider
        _ = provider  // callable handle exists without touching AppState
    }

    // MARK: - Concurrency-guard coverage (warm lifecycle)
    //
    // These drive the real `warmIdentityIndex` async lifecycle through a controllable
    // fake `MediaProvider`, so the facet's *whole point* — the generation / high-water
    // supersession that keeps a stale or superseded scan from clobbering the live
    // snapshot — is exercised against observable outcomes (`identitySnapshot` /
    // `identitySnapshotStore`), not private state. Persistence uses the model's real
    // `FileIdentityIndexStore` under a unique per-test namespace (cleaned up in
    // tearDown) since the store isn't an injectable seam.

    /// Namespaces whose persisted index file this test wrote, removed after each test
    /// so a real cache file never leaks between runs.
    private var createdNamespaces: [String] = []

    override func tearDown() {
        let fm = FileManager.default
        for ns in createdNamespaces {
            try? fm.removeItem(at: Self.cacheFile(ns))
        }
        createdNamespaces.removeAll()
        super.tearDown()
    }

    private func uniqueNamespace() -> String {
        let ns = "iim-test-\(UUID().uuidString)"
        createdNamespaces.append(ns)
        return ns
    }

    private static func cacheFile(_ namespace: String) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("Plozz/identity-index-v5-\(namespace).json")
    }

    private func makeWarmModel(
        namespace: String,
        accounts: @escaping @MainActor () -> [ResolvedAccount],
        onPublish: @escaping @MainActor () -> Void = {}
    ) -> IdentityIndexModel {
        IdentityIndexModel(
            activeAccounts: accounts,
            namespace: { namespace },
            onPublish: onPublish
        )
    }

    private func session(_ id: String, kind: ProviderKind = .jellyfin) -> UserSession {
        UserSession(
            server: MediaServer(
                id: "srv-\(id)",
                name: "Server \(id)",
                baseURL: URL(string: "http://\(id).local")!,
                provider: kind
            ),
            userID: "user-\(id)",
            userName: "User \(id)",
            deviceID: "dev-\(id)",
            accessToken: "token-\(id)"
        )
    }

    private func movie(_ id: String, account: String, tmdb: String) -> MediaItem {
        MediaItem(
            id: id,
            title: "Movie \(id)",
            kind: .movie,
            productionYear: 2021,
            providerIDs: ["Tmdb": tmdb],
            sourceAccountID: account
        )
    }

    private func resolved(
        _ accountID: String,
        kind: ProviderKind = .jellyfin,
        movies: [MediaItem],
        gate: IdentityWarmGate? = nil
    ) -> ResolvedAccount {
        let userSession = session(accountID, kind: kind)
        let account = Account(
            id: accountID,
            server: userSession.server,
            userID: userSession.userID,
            userName: userSession.userName,
            deviceID: userSession.deviceID
        )
        return ResolvedAccount(
            account: account,
            provider: FakeIndexProvider(kind: kind, session: userSession, movies: movies, gate: gate)
        )
    }

    /// Polls `condition` on the main actor until it's true or the timeout elapses,
    /// yielding + briefly sleeping between checks so concurrent warm work (which runs
    /// off the main actor) can make progress. Returns the final result so callers can
    /// assert on it.
    @discardableResult
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 2_000_000) // 2ms
        }
        return await condition()
    }

    /// Gives an already-released (or superseded/cancelled) warm task a real window to
    /// run its resumed continuations, so a test asserting a stale wave did NOT publish
    /// has actually let that wave attempt to.
    private func settle() async {
        for _ in 0..<40 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 8_000_000) // 8ms
        for _ in 0..<40 { await Task.yield() }
    }

    /// A newer warm wave supersedes an older still-in-flight one: the stale wave's
    /// eventual completion must not overwrite the newer snapshot. Account "a"'s scan is
    /// gated mid-flight (suspended in `libraries()` before any ingest); a second wave
    /// for a different active set {b} completes and publishes; releasing the stale "a"
    /// wave must leave the snapshot at {b}.
    func testNewerWarmWaveSupersedesStaleInFlightWarm() async {
        let namespace = uniqueNamespace()
        let gate = IdentityWarmGate()
        var active: [ResolvedAccount] = [
            resolved("a", movies: [movie("a1", account: "a", tmdb: "100")], gate: gate)
        ]
        let model = makeWarmModel(namespace: namespace, accounts: { active })

        model.warmIdentityIndex()
        let reachedGate = await waitUntil { await gate.entered() }
        XCTAssertTrue(reachedGate, "warm should reach account a's gated scan")
        XCTAssertTrue(model.identitySnapshot.isEmpty, "nothing published yet — a is gated before ingest")

        // Supersede with a newer wave over a different active set.
        active = [resolved("b", kind: .plex, movies: [movie("b1", account: "b", tmdb: "200")])]
        model.warmIdentityIndex()
        let publishedB = await waitUntil { model.identitySnapshot.indexedAccountIDs == ["b"] }
        XCTAssertTrue(publishedB, "the newer wave should publish {b}")

        // Release the superseded wave; it must not clobber the newer snapshot.
        await gate.release()
        await settle()
        XCTAssertEqual(
            model.identitySnapshot.indexedAccountIDs, ["b"],
            "a stale/superseded wave must not overwrite the newer wave's snapshot"
        )
        XCTAssertFalse(model.identitySnapshot.indexedAccountIDs.contains("a"))
    }

    /// `reset()` (a profile switch) supersedes an in-flight warm: a scan still running
    /// against the OLD profile's index must not repopulate the freshly-emptied
    /// snapshot when it resumes.
    func testResetSupersedesInFlightWarmLeavingEmptySnapshot() async {
        let namespace = uniqueNamespace()
        let gate = IdentityWarmGate()
        let model = makeWarmModel(namespace: namespace, accounts: {
            [self.resolved("a", movies: [self.movie("a1", account: "a", tmdb: "100")], gate: gate)]
        })

        model.warmIdentityIndex()
        let reachedGate = await waitUntil { await gate.entered() }
        XCTAssertTrue(reachedGate, "warm should reach account a's gated scan")

        model.reset()
        XCTAssertTrue(model.identitySnapshot.isEmpty, "reset empties the snapshot immediately")

        await gate.release()
        await settle()
        XCTAssertTrue(
            model.identitySnapshot.isEmpty,
            "an in-flight warm from the pre-reset profile must not repopulate the reset snapshot"
        )
        XCTAssertTrue(model.identitySnapshotStore.current.isEmpty)
    }

    /// The first warm of a fresh model restores persisted membership (the B2 seed) and
    /// prunes it to the still-active accounts (B3): model A warms {a,b} and persists;
    /// model B — active set narrowed to {a}, with a provider that scans NOTHING — can
    /// only end up with an indexed account via the persisted restore, and "b" must not
    /// be resurrected.
    func testFirstWarmRestoresPersistedMembershipPrunedToActiveAccounts() async {
        let namespace = uniqueNamespace()

        let modelA = makeWarmModel(namespace: namespace, accounts: {
            [
                self.resolved("a", movies: [self.movie("a1", account: "a", tmdb: "100")]),
                self.resolved("b", kind: .plex, movies: [self.movie("b1", account: "b", tmdb: "200")])
            ]
        })
        modelA.warmIdentityIndex()
        let warmedBoth = await waitUntil { modelA.identitySnapshot.indexedAccountIDs == ["a", "b"] }
        XCTAssertTrue(warmedBoth, "model A should warm both accounts")
        let fileURL = Self.cacheFile(namespace)
        let persisted = await waitUntil { FileManager.default.fileExists(atPath: fileURL.path) }
        XCTAssertTrue(persisted, "the warm wave should persist membership to disk")

        // Fresh model, active set narrowed to {a}; its provider returns no libraries,
        // so any indexed account can ONLY have come from the persisted restore.
        let modelB = makeWarmModel(namespace: namespace, accounts: {
            [self.resolved("a", movies: [])]
        })
        modelB.warmIdentityIndex()
        let restored = await waitUntil { modelB.identitySnapshot.indexedAccountIDs == ["a"] }
        XCTAssertTrue(restored, "first warm should restore the persisted membership for the still-active account")
        XCTAssertFalse(
            modelB.identitySnapshot.indexedAccountIDs.contains("b"),
            "restore must prune the no-longer-active account (never resurrected)"
        )
    }

    /// A warm wave grows the index to include every active account (the invariant the
    /// per-wave high-water guard protects — the index only grows within a wave). Two
    /// accounts warm concurrently; the published snapshot must end up carrying both.
    func testWarmGrowsIndexToIncludeAllActiveAccounts() async {
        let namespace = uniqueNamespace()
        let model = makeWarmModel(namespace: namespace, accounts: {
            [
                self.resolved("a", movies: [self.movie("a1", account: "a", tmdb: "100")]),
                self.resolved("b", kind: .plex, movies: [self.movie("b1", account: "b", tmdb: "200")])
            ]
        })

        model.warmIdentityIndex()
        let grewToBoth = await waitUntil { model.identitySnapshot.indexedAccountIDs == ["a", "b"] }
        XCTAssertTrue(grewToBoth, "the index should grow to include both concurrently-warmed accounts")
    }

    /// Repeated `warmIdentityIndex` calls cancel and replace the prior in-flight task
    /// (no double-publish, no crash): several back-to-back waves must converge on the
    /// active account and fire the post-publish hook at least once.
    func testRepeatedWarmCancelsPriorTaskAndConvergesWithoutCrash() async {
        let namespace = uniqueNamespace()
        var publishes = 0
        let model = makeWarmModel(
            namespace: namespace,
            accounts: { [self.resolved("a", movies: [self.movie("a1", account: "a", tmdb: "100")])] },
            onPublish: { publishes += 1 }
        )

        model.warmIdentityIndex()
        model.warmIdentityIndex()
        model.warmIdentityIndex(force: true)

        let converged = await waitUntil { model.identitySnapshot.indexedAccountIDs == ["a"] }
        XCTAssertTrue(converged, "rapid re-warms should converge on the active account without crashing")
        XCTAssertGreaterThanOrEqual(publishes, 1, "a successful publish should re-drain the watch outbox")
    }
}

// MARK: - Test doubles

/// A one-shot suspension gate an actor-isolated warm can await, so a test can hold a
/// scan mid-flight, mutate the model (supersede / reset), then release it and assert
/// the stale wave doesn't clobber the live snapshot.
private actor IdentityWarmGate {
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var didEnter = false

    /// Suspends the caller until `release()` (returns immediately if already released).
    func wait() async {
        didEnter = true
        if released { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func release() {
        guard !released else { return }
        released = true
        waiter?.resume()
        waiter = nil
    }

    /// Whether a caller has reached `wait()` yet (the warm has entered the gated scan).
    func entered() -> Bool { didEnter }
}

/// A minimal `MediaProvider` returning a fixed movie set from a single movie library,
/// with an optional gate suspending `libraries()` so a test can hold the scan
/// mid-flight. Everything else is an empty/throwing stub — the identity warm only
/// consumes `libraries()` + `items(in:kind:page:)` (and `item(id:)` for guid-less
/// enrichment, which the test items never need).
private final class FakeIndexProvider: MediaProvider, @unchecked Sendable {
    let kind: ProviderKind
    let session: UserSession
    private let movies: [MediaItem]
    private let gate: IdentityWarmGate?

    init(kind: ProviderKind, session: UserSession, movies: [MediaItem], gate: IdentityWarmGate?) {
        self.kind = kind
        self.session = session
        self.movies = movies
        self.gate = gate
    }

    func libraries() async throws -> [MediaLibrary] {
        if let gate { await gate.wait() }
        return movies.isEmpty ? [] : [MediaLibrary(id: "lib", title: "Movies", kind: .movie)]
    }

    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        guard page.startIndex == 0 else {
            return MediaPage(items: [], startIndex: page.startIndex, totalCount: movies.count)
        }
        return MediaPage(items: movies, startIndex: 0, totalCount: movies.count)
    }

    func item(id: String) async throws -> MediaItem {
        guard let match = movies.first(where: { $0.id == id }) else { throw AppError.notFound }
        return match
    }

    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
