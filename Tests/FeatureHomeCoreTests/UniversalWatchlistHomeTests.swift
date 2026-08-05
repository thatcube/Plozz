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

    func testDurableFrontInsertionRefreshesHomeRowImmediately() {
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
}

@MainActor
private final class UniversalWatchlistHomeHandler: MediaItemActionHandling {
    var items: [MediaItem]
    init(items: [MediaItem]) { self.items = items }
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
        items
    }
}

private final class UniversalWatchlistHomeStore:
    HomeContentStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var content: HomeViewModel.Content?
    init(content: HomeViewModel.Content?) { self.content = content }
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
        content = nil
        lock.unlock()
    }
    func loadHero(for key: HomeHeroCacheKey) -> [MediaItem]? { nil }
    func saveHero(_ items: [MediaItem], for key: HomeHeroCacheKey) {}
}
