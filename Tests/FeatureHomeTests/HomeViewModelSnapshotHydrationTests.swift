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

        await vm.loadIfNeeded(excludedKeys: [])

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

        await vm.loadIfNeeded(excludedKeys: [])
        // Ends loaded (not empty/loading) with the fresh content.
        XCTAssertEqual(loadedContent(vm)?.continueWatching.map(\.id), ["freshA"])
    }

    func testTransientEmptyRefreshKeepsCachedContent() async {
        // Cached snapshot present, but the fresh aggregate comes back empty (server
        // momentarily unreachable). The instant content must stay on screen.
        let store = InMemoryHomeContentStore(snapshot(cwIDs: ["cachedA", "cachedB"]))
        let provider = FakeMediaProvider(allItems: []) // returns empty rows
        let vm = makeViewModel(provider: provider, contentStore: store)

        await vm.loadIfNeeded(excludedKeys: [])

        XCTAssertEqual(
            loadedContent(vm)?.continueWatching.map(\.id), ["cachedA", "cachedB"],
            "A silent refresh that came back empty must not blank out the cached content"
        )
    }

    func testSuccessfulLoadPersistsSnapshotForNextLaunch() async {
        let store = InMemoryHomeContentStore()
        let provider = FakeMediaProvider(allItems: [])
        provider.continueWatchingItems = [MediaItem(id: "freshA", title: "Fresh", kind: .movie)]
        let vm = makeViewModel(provider: provider, contentStore: store)

        // No cache ⇒ a normal (loud) load; it should persist the fresh content.
        await vm.loadIfNeeded(excludedKeys: [])

        XCTAssertEqual(store.load()?.continueWatching.map(\.id), ["freshA"], "Fresh content is cached for next launch")
    }
}
