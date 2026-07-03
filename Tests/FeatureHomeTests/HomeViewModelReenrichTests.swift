import XCTest
import CoreModels
@testable import FeatureHome

/// Verifies `HomeViewModel.reenrich()` — the in-place re-fold that runs when the
/// cross-server identity index warms further (a new account finishes indexing).
///
/// The bug it fixes: a Continue Watching card that cold-loaded before its local
/// twin was known kept an incomplete `sources` set for the whole session, so
/// play-time locality selection had no local copy to route to. `reenrich()` must
/// fold the freshly-discovered sources into the already-loaded cards *in place*
/// (no refetch), and must be a true no-op when nothing new was discovered.
@MainActor
final class HomeViewModelReenrichTests: XCTestCase {
    /// Thread-safe, mutable identity-sources lookup so a test can flip what the
    /// index "knows" between the initial load and the re-enrich.
    private final class SourcesBox: @unchecked Sendable {
        private let lock = NSLock()
        private var map: [String: [MediaSourceRef]] = [:]
        func set(_ newMap: [String: [MediaSourceRef]]) {
            lock.lock(); defer { lock.unlock() }
            map = newMap
        }
        func sources(for item: MediaItem) -> [MediaSourceRef] {
            lock.lock(); defer { lock.unlock() }
            return map[item.id] ?? []
        }
    }

    private func makeViewModel(
        provider: FakeMediaProvider,
        box: SourcesBox
    ) -> HomeViewModel {
        let server = MediaServer(id: "srv-a", name: "Local", baseURL: URL(string: "http://host")!, provider: .jellyfin)
        let account = Account(id: "a", server: server, userID: "u", userName: "Me", deviceID: "d")
        let resolved = ResolvedAccount(account: account, provider: provider)
        return HomeViewModel(
            accounts: [resolved],
            layoutStore: InMemoryHomeLayoutStore(),
            identitySources: { box.sources(for: $0) },
            currentVisibility: { .default }
        )
    }

    func testReenrichFoldsNewlyDiscoveredSourceIntoLoadedCard() async {
        let provider = FakeMediaProvider(allItems: [])
        provider.continueWatchingItems = [MediaItem(id: "m1", title: "Movie", kind: .movie)]
        let box = SourcesBox()
        let vm = makeViewModel(provider: provider, box: box)

        // Cold load: the index knows nothing yet, so the card has no cross-server twin.
        await vm.load()
        let cwBefore = vm.state.value?.continueWatching ?? []
        XCTAssertEqual(cwBefore.count, 1)
        XCTAssertFalse(cwBefore[0].sources.contains { $0.accountID == "b" })

        // The index warms: account "b" (a second server) turns out to host the same title.
        box.set([
            "m1": [
                MediaSourceRef(accountID: "a", itemID: "m1", providerKind: .jellyfin),
                MediaSourceRef(accountID: "b", itemID: "m1-on-b", providerKind: .plex)
            ]
        ])
        vm.reenrich()

        let cwAfter = vm.state.value?.continueWatching ?? []
        XCTAssertEqual(cwAfter.count, 1, "Re-enrich must not add or drop cards, only fold sources")
        XCTAssertTrue(
            cwAfter[0].sources.contains { $0.accountID == "b" },
            "The newly-discovered local twin must be folded into the loaded card so play can route to it"
        )
    }

    func testReenrichIsNoOpWhenNothingNewDiscovered() async {
        let provider = FakeMediaProvider(allItems: [])
        provider.continueWatchingItems = [MediaItem(id: "m1", title: "Movie", kind: .movie)]
        let box = SourcesBox()
        let vm = makeViewModel(provider: provider, box: box)

        await vm.load()
        let before = vm.state.value

        // Index hasn't grown (box still empty): re-enrich must leave content identical.
        vm.reenrich()
        XCTAssertEqual(before, vm.state.value)
    }
}
