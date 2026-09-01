import XCTest
import CoreModels
@testable import FeatureHome

/// Verifies the instant-launch behaviour: `HomeViewModel` hydrates the last
/// content snapshot synchronously at construction (so the hero + rows paint with
/// no network), then the first appearance refreshes SILENTLY (never flashing a
/// loading skeleton), persists fresh content, and never lets a transient empty
/// aggregate blank out good content already on screen.
@MainActor
final class HomeViewModelSnapshotHydrationTests: XCTestCase {
    private func makeViewModel(
        provider: FakeMediaProvider,
        contentStore: HomeContentStoring
    ) -> HomeViewModel {
        let server = MediaServer(id: "srv", name: "Home", baseURL: URL(string: "http://host")!, provider: .jellyfin)
        let account = Account(id: "a", server: server, userID: "u", userName: "Me", deviceID: "d")
        let resolved = ResolvedAccount(account: account, provider: provider)
        return HomeViewModel(
            accounts: [resolved],
            layoutStore: InMemoryHomeLayoutStore(),
            contentStore: contentStore
        )
    }

    /// A view model for a profile that watches NO servers.
    private func makeSourcelessViewModel(contentStore: HomeContentStoring) -> HomeViewModel {
        HomeViewModel(
            accounts: [],
            layoutStore: InMemoryHomeLayoutStore(),
            contentStore: contentStore
        )
    }

    private func snapshot(cwIDs: [String]) -> HomeViewModel.Content {
        HomeViewModel.Content(
            continueWatching: cwIDs.map { MediaItem(id: $0, title: "Cached \($0)", kind: .movie) }
        )
    }

    private func loadedContent(_ vm: HomeViewModel) -> HomeViewModel.Content? {
        if case let .loaded(content) = vm.state { return content }
        return nil
    }

    func testHydratesCachedSnapshotSynchronouslyAtInit() {
        let store = InMemoryHomeContentStore(snapshot(cwIDs: ["cachedA", "cachedB"]))
        let vm = makeViewModel(provider: FakeMediaProvider(allItems: []), contentStore: store)
        // Painted from cache BEFORE any load — no network, no skeleton.
        XCTAssertEqual(loadedContent(vm)?.continueWatching.map(\.id), ["cachedA", "cachedB"])
    }

    func testNoCacheLeavesIdleForNormalLoadingState() {
        let vm = makeViewModel(provider: FakeMediaProvider(allItems: []), contentStore: InMemoryHomeContentStore())
        guard case .idle = vm.state else {
            return XCTFail("With no snapshot the VM must stay .idle so a normal loading state shows")
        }
    }

    func testFirstAppearanceRefreshesSilentlyAndSwapsFreshContentIn() async {
        let store = InMemoryHomeContentStore(snapshot(cwIDs: ["cachedA"]))
        let provider = FakeMediaProvider(allItems: [])
        // Fresh server content differs from the cache.
        provider.continueWatchingItems = [
            MediaItem(id: "freshA", title: "Fresh A", kind: .movie),
            MediaItem(id: "freshB", title: "Fresh B", kind: .movie)
        ]
        let vm = makeViewModel(provider: provider, contentStore: store)
        XCTAssertEqual(loadedContent(vm)?.continueWatching.map(\.id), ["cachedA"], "Starts on the cached snapshot")

        await vm.loadIfNeeded(for: .default)

        XCTAssertEqual(provider.librariesCallCount, 1, "The silent refresh actually re-aggregated")
        XCTAssertEqual(loadedContent(vm)?.continueWatching.map(\.id), ["freshA", "freshB"], "Fresh content swapped in")
    }

    func testSilentRefreshNeverEntersLoadingState() async {
        // Observe the state the moment loadIfNeeded runs: it must never become
        // `.loading` (which would render the skeleton over the instant cached hero).
        let store = InMemoryHomeContentStore(snapshot(cwIDs: ["cachedA"]))
        let provider = FakeMediaProvider(allItems: [])
        provider.continueWatchingItems = [MediaItem(id: "freshA", title: "Fresh", kind: .movie)]
        let vm = makeViewModel(provider: provider, contentStore: store)

        await vm.loadIfNeeded(for: .default)
        // Ends loaded (not empty/loading) with the fresh content.
        XCTAssertEqual(loadedContent(vm)?.continueWatching.map(\.id), ["freshA"])
    }

    func testRefreshingCoversTheFullSilentRefreshLifetime() async {
        let gate = HomeRefreshGate()
        let provider = FakeMediaProvider(allItems: [])
        provider.librariesGate = { await gate.wait() }
        let vm = makeViewModel(
            provider: provider,
            contentStore: InMemoryHomeContentStore(snapshot(cwIDs: ["cachedA"]))
        )

        let load = Task { await vm.loadIfNeeded(for: .default) }
        while provider.librariesCallCount == 0 {
            await Task.yield()
        }

        XCTAssertTrue(vm.isRefreshing, "Cached content should disclose that its live replacement is still loading")
        gate.open()
        await load.value
        XCTAssertFalse(vm.isRefreshing, "The loading disclosure must clear when aggregation finishes")
    }

    func testTransientEmptyRefreshKeepsCachedContent() async {
        // Cached snapshot present, but the fresh aggregate comes back empty (server
        // momentarily unreachable). The instant content must stay on screen.
        let store = InMemoryHomeContentStore(snapshot(cwIDs: ["cachedA", "cachedB"]))
        let provider = FakeMediaProvider(allItems: []) // returns empty rows
        let vm = makeViewModel(provider: provider, contentStore: store)

        await vm.loadIfNeeded(for: .default)

        XCTAssertEqual(
            loadedContent(vm)?.continueWatching.map(\.id), ["cachedA", "cachedB"],
            "A silent refresh that came back empty must not blank out the cached content"
        )

        // Regression: a SECOND appearance with unchanged visibility (tvOS restarts
        // the `.task` on every reappearance) must stay a no-op and keep the cached
        // content — NOT run a loud load that flashes the skeleton and then drops to
        // `.empty` while the server is still down.
        await vm.loadIfNeeded(for: .default)
        XCTAssertEqual(
            loadedContent(vm)?.continueWatching.map(\.id), ["cachedA", "cachedB"],
            "Reappearance before the first successful refresh must keep the cached content, not reload loudly"
        )
    }

    func testViewTaskCancellationKeepsCompletedModelOwnedRefresh() async {
        let store = InMemoryHomeContentStore(snapshot(cwIDs: ["cachedA"]))
        let provider = FakeMediaProvider(allItems: [])
        provider.librariesGate = {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let vm = makeViewModel(provider: provider, contentStore: store)

        let first = Task { await vm.loadIfNeeded(for: .default) }
        while provider.librariesCallCount == 0 {
            await Task.yield()
        }
        first.cancel()
        await first.value

        XCTAssertFalse(
            vm.isShowingCachedSnapshot,
            "View-task cancellation must not discard a completed model-owned refresh"
        )
        await vm.loadIfNeeded(for: .default)
        XCTAssertEqual(
            provider.librariesCallCount,
            1,
            "Reappearance must not repeat the already-completed fan-out"
        )
    }

    func testSuccessfulLoadPersistsSnapshotForNextLaunch() async {
        let store = InMemoryHomeContentStore()
        let provider = FakeMediaProvider(allItems: [])
        provider.continueWatchingItems = [MediaItem(id: "freshA", title: "Fresh", kind: .movie)]
        let vm = makeViewModel(provider: provider, contentStore: store)

        // No cache ⇒ a normal (loud) load; it should persist the fresh content.
        await vm.loadIfNeeded(for: .default)
        for _ in 0..<100 where store.load() == nil {
            await Task.yield()
        }

        XCTAssertEqual(store.load()?.continueWatching.map(\.id), ["freshA"], "Fresh content is cached for next launch")
    }

    // MARK: Watching nothing

    /// Turning every server off left the previous library on screen: the cached
    /// snapshot was hydrated at init regardless of whether the profile still had
    /// anything to aggregate, and it survived relaunches because `save` refuses
    /// to overwrite good content with an empty one.
    func testAProfileWithNoServersDoesNotPaintTheCachedSnapshot() {
        let store = InMemoryHomeContentStore(snapshot(cwIDs: ["cachedA"]))
        let vm = makeSourcelessViewModel(contentStore: store)

        XCTAssertNil(loadedContent(vm), "A profile watching nothing must not repaint an old library")
        XCTAssertNil(store.load(), "and the stale snapshot must not survive to the next launch")
    }

    /// The other half: an empty aggregate from a profile with no sources is the
    /// ANSWER, not a failed fetch, so the keep-cached rule must stand aside.
    func testLoadingWithNoServersEndsEmptyRatherThanKeepingContent() async {
        let store = InMemoryHomeContentStore()
        let vm = makeSourcelessViewModel(contentStore: store)
        await vm.load(showLoadingState: false)

        guard case .empty = vm.state else {
            return XCTFail("Expected .empty for a profile that watches nothing, got \(vm.state)")
        }
        XCTAssertNil(store.load())
    }

    /// The fix strips SERVER-derived rows, not everything: the universal
    /// watchlist is the user's own and isn't a server's to take away.
    func testAProfileWithNoServersKeepsItsUniversalWatchlist() {
        var snapshot = self.snapshot(cwIDs: ["cachedA"])
        snapshot.watchlist = [MediaItem(id: "wl", title: "Watchlisted", kind: .movie)]
        let vm = makeSourcelessViewModel(contentStore: InMemoryHomeContentStore(snapshot))

        XCTAssertEqual(loadedContent(vm)?.watchlist.map(\.id), ["wl"])
        XCTAssertEqual(
            loadedContent(vm)?.continueWatching, [],
            "but the switched-off server's rows must be gone"
        )
    }

    /// Guards the fix from over-reaching: a profile that DOES have a server and
    /// gets a transient empty (server briefly unreachable) must still keep what
    /// is on screen, which is what the cached snapshot exists for.
    func testATransientEmptyStillKeepsCachedContentWhenAServerExists() async {
        let store = InMemoryHomeContentStore(snapshot(cwIDs: ["cachedA"]))
        let vm = makeViewModel(provider: FakeMediaProvider(allItems: []), contentStore: store)
        await vm.load(showLoadingState: false)

        XCTAssertEqual(
            loadedContent(vm)?.continueWatching.map(\.id), ["cachedA"],
            "An unreachable server must not blank a good snapshot"
        )
    }
}

private final class HomeRefreshGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        lock.lock()
        opened = true
        let pending = waiters
        waiters = []
        lock.unlock()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if opened {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}
