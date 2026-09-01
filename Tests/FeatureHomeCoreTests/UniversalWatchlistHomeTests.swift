import CoreModels
import XCTest
@testable import FeatureHomeCore

@MainActor
final class UniversalWatchlistHomeTests: XCTestCase {
    func testCachedProviderWatchlistIsReplacedByDurableAliasOrder() {
        let oldProviderFavorite = MediaItem(
            id: "old",
            title: "Old",
            kind: .movie,
            isFavorite: true
        )
        let second = MediaItem(
            id: "second",
            title: "Second",
            kind: .series,
            watchlistAliasID: MediaAliasID()
        )
        let first = MediaItem(
            id: "first",
            title: "First",
            kind: .movie,
            watchlistAliasID: MediaAliasID()
        )
        let store = UniversalWatchlistHomeStore(
            content: .init(watchlist: [oldProviderFavorite])
        )
        let handler = UniversalWatchlistHomeHandler(items: [first, second])

        let model = HomeViewModel(
            accounts: [],
            contentStore: store,
            mediaItemActionHandler: handler
        )

        guard case .loaded(let content) = model.state else {
            return XCTFail("Expected cached content")
        }
        XCTAssertEqual(content.watchlist.map(\.title), ["First", "Second"])
        XCTAssertEqual(
            content.watchlist.map(\.stablePresentationID),
            [first.stablePresentationID, second.stablePresentationID]
        )
    }

    func testDurableAdditionUsesAuthoritativeOrder() {
        let older = MediaItem(
            id: "older",
            title: "Older",
            kind: .movie,
            watchlistAliasID: MediaAliasID()
        )
        let newlyAdded = MediaItem(
            id: "new",
            title: "New",
            kind: .series,
            watchlistAliasID: MediaAliasID()
        )
        let store = UniversalWatchlistHomeStore(
            content: .init(watchlist: [older])
        )
        let handler = UniversalWatchlistHomeHandler(items: [older])
        let model = HomeViewModel(
            accounts: [],
            contentStore: store,
            mediaItemActionHandler: handler
        )

        handler.items = [newlyAdded, older]
        model.refreshDurableWatchlist()

        guard case .loaded(let content) = model.state else {
            return XCTFail("Expected loaded content")
        }
        XCTAssertEqual(content.watchlist.map(\.title), ["New", "Older"])
        XCTAssertEqual(
            content.watchlist.map(\.stablePresentationID),
            [newlyAdded.stablePresentationID, older.stablePresentationID]
        )
    }

    /// Home's own snapshot is already a complete last-known presentation. Before
    /// the watchlist runtime has opened its native-view cache, resolving against
    /// the runtime means resolving against explicit intents only — and replacing
    /// this complete row with a smaller, unowned one.
    func testCachedRowIsNotDowngradedBeforeWatchlistCacheLoads() {
        let cachedOwned = MediaItem(
            id: "owned",
            title: "Cached owned copy",
            kind: .movie,
            watchlistAliasID: MediaAliasID(),
            locallyValidatedPlayableSource: true
        )
        let explicitOnly = MediaItem(
            id: "explicit",
            title: "Explicit only",
            kind: .movie,
            watchlistAliasID: MediaAliasID(),
            availability: .unknown,
            locallyValidatedPlayableSource: false
        )
        let store = UniversalWatchlistHomeStore(
            content: .init(watchlist: [cachedOwned])
        )
        let handler = UniversalWatchlistHomeHandler(
            items: [explicitOnly],
            ready: false
        )

        let model = HomeViewModel(
            accounts: [],
            contentStore: store,
            mediaItemActionHandler: handler
        )

        guard case .loaded(let initial) = model.state else {
            return XCTFail("Expected cached content")
        }
        XCTAssertEqual(initial.watchlist.map(\.id), ["owned"])
        XCTAssertTrue(
            initial.watchlist[0].locallyValidatedPlayableSource,
            "The first frame must keep last-known ownership"
        )

        // Once cache restoration says the runtime is authoritative, its ordinary
        // refresh path takes over.
        handler.ready = true
        model.refreshDurableWatchlist()
        guard case .loaded(let refreshed) = model.state else {
            return XCTFail("Expected refreshed content")
        }
        XCTAssertEqual(refreshed.watchlist.map(\.id), ["explicit"])
    }

    /// Provider records are not ownership answers. Keep the resolved launch row
    /// fixed and use skeleton slots until durable reconciliation is ready.
    func testBackgroundAggregationKeepsResolvedRowBeforeCacheIsReady() {
        let freshlyFetched = (0..<177).map {
            MediaItem(id: "item-\($0)", title: "Item \($0)", kind: .movie)
        }
        let cached = Array(freshlyFetched.prefix(30)) + [
            MediaItem(
                id: "tracker-only",
                title: "Tracker only",
                kind: .series,
                locallyValidatedPlayableSource: true
            )
        ]
        let handler = UniversalWatchlistHomeHandler(
            items: freshlyFetched,
            ready: false
        )

        let beforeCache = HomeViewModel.resolvedWatchlist(
            candidates: freshlyFetched,
            fetched: freshlyFetched,
            lastKnown: cached,
            handler: handler
        )
        XCTAssertEqual(beforeCache.map(\.id), cached.map(\.id))
        XCTAssertTrue(
            beforeCache.last?.locallyValidatedPlayableSource == true,
            "Resolved cached entries remain visible until durable reconciliation"
        )

        handler.ready = true
        let afterCache = HomeViewModel.resolvedWatchlist(
            candidates: cached + freshlyFetched,
            fetched: freshlyFetched,
            lastKnown: cached,
            handler: handler
        )
        XCTAssertEqual(afterCache.map(\.id), freshlyFetched.map(\.id))
    }

    func testAuthoritativeRefreshAppliesServerOrderAfterInteractionSettles() {
        let first = MediaItem(
            id: "first",
            title: "First",
            kind: .movie,
            watchlistAliasID: MediaAliasID()
        )
        let second = MediaItem(
            id: "second",
            title: "Second",
            kind: .movie,
            watchlistAliasID: MediaAliasID()
        )
        let new = MediaItem(
            id: "new",
            title: "New",
            kind: .movie,
            watchlistAliasID: MediaAliasID()
        )

        let stable = HomeViewModel.stabilizedWatchlist(
            current: [first, second],
            authoritative: [new, second, first]
        )

        XCTAssertEqual(stable.map(\.id), ["new", "second", "first"])
    }

    func testAuthoritativeRefreshDeduplicatesStablePresentationIDs() {
        let aliasID = MediaAliasID()
        let stale = MediaItem(
            id: "stale",
            title: "Stale",
            kind: .movie,
            watchlistAliasID: aliasID
        )
        let refreshed = MediaItem(
            id: "refreshed",
            title: "Refreshed",
            kind: .movie,
            watchlistAliasID: aliasID
        )

        let stable = HomeViewModel.stabilizedWatchlist(
            current: [stale, stale],
            authoritative: [refreshed, refreshed]
        )

        XCTAssertEqual(stable.map(\.id), ["refreshed"])
    }

    func testAuthoritativeRefreshWaitsForNavigationToSettle() async {
        let first = MediaItem(
            id: "first",
            title: "First",
            kind: .movie,
            watchlistAliasID: MediaAliasID()
        )
        let second = MediaItem(
            id: "second",
            title: "Second",
            kind: .movie,
            watchlistAliasID: MediaAliasID()
        )
        let handler = UniversalWatchlistHomeHandler(items: [first, second])
        let model = HomeViewModel(
            accounts: [],
            contentStore: UniversalWatchlistHomeStore(
                content: .init(watchlist: [first, second])
            ),
            mediaItemActionHandler: handler
        )

        handler.items = [second, first]
        model.noteHomeNavigationInteraction()
        model.refreshDurableWatchlist()

        guard case .loaded(let browsing) = model.state else {
            return XCTFail("Expected loaded content")
        }
        XCTAssertEqual(browsing.watchlist.map(\.id), ["first", "second"])

        try? await Task.sleep(for: .milliseconds(450))

        guard case .loaded(let settled) = model.state else {
            return XCTFail("Expected loaded content")
        }
        XCTAssertEqual(settled.watchlist.map(\.id), ["second", "first"])
    }

    func testNewDurableChangeInvalidatesDeferredAuthoritativeSnapshot() async {
        let first = MediaItem(
            id: "first",
            title: "First",
            kind: .movie,
            watchlistAliasID: MediaAliasID()
        )
        let second = MediaItem(
            id: "second",
            title: "Second",
            kind: .movie,
            watchlistAliasID: MediaAliasID()
        )
        let handler = UniversalWatchlistHomeHandler(items: [second, first])
        let model = HomeViewModel(
            accounts: [],
            contentStore: UniversalWatchlistHomeStore(
                content: .init(watchlist: [first, second])
            ),
            mediaItemActionHandler: handler
        )

        model.noteHomeNavigationInteraction()
        model.refreshDurableWatchlist()
        handler.items = [first]
        model.scheduleDurableWatchlistRefresh()
        try? await Task.sleep(for: .milliseconds(450))

        guard case .loaded(let settled) = model.state else {
            return XCTFail("Expected loaded content")
        }
        XCTAssertEqual(settled.watchlist.map(\.id), ["first"])
    }

    func testResolvedMembershipShowsSkeletonsWhileOwnershipCatchesUp() {
        let visible = MediaItem(
            id: "visible",
            title: "Visible",
            kind: .movie,
            watchlistAliasID: MediaAliasID()
        )
        let handler = UniversalWatchlistHomeHandler(items: [visible])
        handler.loadingTarget = 3
        let model = HomeViewModel(
            accounts: [],
            contentStore: UniversalWatchlistHomeStore(
                content: .init(watchlist: [visible])
            ),
            mediaItemActionHandler: handler
        )

        XCTAssertEqual(model.watchlistLoadingPlaceholderCount, 2)
    }

    func testReadyDurableWatchlistCanAuthoritativelyClearLastKnownRow() {
        let cached = MediaItem(
            id: "removed",
            title: "Removed title",
            kind: .movie
        )
        let handler = UniversalWatchlistHomeHandler(items: [], ready: true)

        let resolved = HomeViewModel.resolvedWatchlist(
            candidates: [cached],
            fetched: [cached],
            lastKnown: [cached],
            handler: handler
        )

        XCTAssertTrue(resolved.isEmpty)
    }

    func testProvisionalSavePreservesUnresolvedCardsAndUpdatesVisibleCards() async {
        let unresolved = MediaItem(
            id: "unresolved",
            title: "Unresolved",
            kind: .movie,
            availability: .unknown,
            locallyValidatedPlayableSource: false
        )
        let owned = MediaItem(
            id: "owned",
            title: "Owned",
            kind: .movie,
            locallyValidatedPlayableSource: true
        )
        let store = UniversalWatchlistHomeStore(
            content: .init(watchlist: [unresolved, owned]),
            clearsOnRequest: false
        )
        let handler = UniversalWatchlistHomeHandler(
            items: [unresolved, owned],
            ready: false
        )
        let model = HomeViewModel(
            accounts: [],
            contentStore: store,
            mediaItemActionHandler: handler
        )

        model.applyWatchedState(
            MediaItemMutation(itemIDs: [owned.id], played: true)
        )
        for _ in 0..<100 where store.load()?.watchlist.last?.isPlayed != true {
            await Task.yield()
        }

        let saved = store.load()?.watchlist
        XCTAssertEqual(saved?.map(\.id), [unresolved.id, owned.id])
        XCTAssertEqual(saved?.last?.isPlayed, true)
    }

    func testSnapshotPersistenceRunsOffTheMainThread() async {
        let item = MediaItem(
            id: "owned",
            title: "Owned",
            kind: .movie,
            locallyValidatedPlayableSource: true
        )
        let store = ThreadRecordingHomeStore(
            content: .init(watchlist: [item])
        )
        let model = HomeViewModel(
            accounts: [],
            contentStore: store,
            mediaItemActionHandler:
                UniversalWatchlistHomeHandler(items: [item])
        )

        model.applyWatchedState(
            MediaItemMutation(itemIDs: [item.id], played: true)
        )
        for _ in 0..<100 where store.saveThreadWasMain == nil {
            await Task.yield()
        }

        XCTAssertEqual(store.saveThreadWasMain, false)
    }

    func testFirstPaintRehydratesOwnedArtworkBeforePublishing() {
        let saved = MediaItem(
            id: "4407",
            title: "Arcane",
            kind: .series,
            posterURL: URL(
                string: "https://plex.example/photo/:/transcode"
            ),
            locallyValidatedPlayableSource: true,
            sourceAccountID: "plex"
        )
        let signed = URL(
            string:
                "https://plex.example/photo/:/transcode"
                + "?X-Plex-Token=current"
        )!
        let handler = UniversalWatchlistHomeHandler(
            items: [saved],
            ready: false,
            rehydrate: { items in
                items.map { item in
                    var item = item
                    item.posterURL = signed
                    return item
                }
            }
        )
        let model = HomeViewModel(
            accounts: [],
            contentStore: UniversalWatchlistHomeStore(
                content: .init(watchlist: [saved])
            ),
            mediaItemActionHandler: handler
        )

        guard case .loaded(let content) = model.state else {
            return XCTFail("Expected cached content")
        }
        XCTAssertEqual(content.watchlist.first?.posterURL, signed)
    }

    func testNavigationDefersPendingWatchlistFoldUntilInputSettles() async {
        let item = MediaItem(
            id: "one",
            title: "One",
            kind: .movie,
            watchlistAliasID: MediaAliasID()
        )
        let handler = UniversalWatchlistHomeHandler(items: [item])
        let model = HomeViewModel(
            accounts: [],
            contentStore: UniversalWatchlistHomeStore(
                content: .init(watchlist: [item])
            ),
            mediaItemActionHandler: handler
        )
        let initialCalls = handler.resolveCallCount

        model.scheduleDurableWatchlistRefresh()
        try? await Task.sleep(for: .milliseconds(150))
        model.noteHomeNavigationInteraction()
        try? await Task.sleep(for: .milliseconds(250))

        XCTAssertEqual(handler.resolveCallCount, initialCalls)

        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(handler.resolveCallCount, initialCalls + 1)
    }
}

@MainActor
private final class UniversalWatchlistHomeHandler: MediaItemActionHandling {
    var items: [MediaItem]
    var ready: Bool
    var loadingTarget: Int?
    var rehydrate: ([MediaItem]) -> [MediaItem]
    private(set) var resolveCallCount = 0
    init(
        items: [MediaItem],
        ready: Bool = true,
        rehydrate: @escaping ([MediaItem]) -> [MediaItem] = { $0 }
    ) {
        self.items = items
        self.ready = ready
        self.rehydrate = rehydrate
    }
    func actions(
        for item: MediaItem,
        context: MediaItemActionContext
    ) -> [MediaItemAction] { [] }
    func perform(
        _ action: MediaItemAction,
        on item: MediaItem,
        context: MediaItemActionContext
    ) {}
    func durableWatchlistItems(from candidates: [MediaItem]) -> [MediaItem] {
        resolveCallCount += 1
        return items
    }
    func isDurableWatchlistPresentationReady() -> Bool { ready }
    func durableWatchlistLoadingTargetCount() -> Int? { loadingTarget }
    func rehydratePersistedArtwork(_ items: [MediaItem]) -> [MediaItem] {
        rehydrate(items)
    }
}

private final class UniversalWatchlistHomeStore:
    HomeContentStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var content: HomeViewModel.Content?
    private let clearsOnRequest: Bool
    init(
        content: HomeViewModel.Content?,
        clearsOnRequest: Bool = true
    ) {
        self.content = content
        self.clearsOnRequest = clearsOnRequest
    }
    func load() -> HomeViewModel.Content? {
        lock.lock()
        defer { lock.unlock() }
        return content
    }
    func save(_ content: HomeViewModel.Content) {
        lock.lock()
        self.content = content
        lock.unlock()
    }
    func clear() {
        lock.lock()
        if clearsOnRequest { content = nil }
        lock.unlock()
    }
    func loadHero(for key: HeroConfigurationKey) -> [MediaItem]? { nil }
    func saveHero(_ items: [MediaItem], for key: HeroConfigurationKey) {}
    func clearHero() {}
}

private final class ThreadRecordingHomeStore:
    HomeContentStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var content: HomeViewModel.Content?
    private var recordedSaveThreadWasMain: Bool?

    init(content: HomeViewModel.Content?) {
        self.content = content
    }

    var saveThreadWasMain: Bool? {
        lock.withLock { recordedSaveThreadWasMain }
    }

    func load() -> HomeViewModel.Content? {
        lock.withLock { content }
    }

    func save(_ content: HomeViewModel.Content) {
        lock.withLock {
            self.content = content
            recordedSaveThreadWasMain = Thread.isMainThread
        }
    }

    func clear() {
        lock.withLock { content = nil }
    }

    func loadHero(for key: HeroConfigurationKey) -> [MediaItem]? { nil }
    func saveHero(_ items: [MediaItem], for key: HeroConfigurationKey) {}
    func clearHero() {}
}
