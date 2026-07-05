import XCTest
import CoreModels
@testable import FeatureHome

/// Verifies the unmerged Home aggregation: global Continue Watching / Watchlist
/// stay at the top, the full inventory feeds the Libraries tiles, and only the
/// per-library rows the user **opted in** (Recently Added / discovery hubs) build
/// a block — Home stays lean by default.
@MainActor
final class HomeAggregatorUnmergedTests: XCTestCase {

    /// Enables the given per-library row kinds for `libraryKey` on top of a base.
    private func vis(_ rows: [(String, LibraryHomeRowKind)],
                     merge: Bool = false,
                     disabled: Set<String> = [],
                     excluded: Set<String> = []) -> HomeLibraryVisibility {
        var v = HomeLibraryVisibility(mergeLibrariesOnHome: merge, disabledKeys: disabled, excludedKeys: excluded)
        for (key, kind) in rows { v.setLibraryRowEnabled(true, libraryKey: key, kind: kind) }
        return v
    }

    func testBuildsOptedInRowsInOrder() async {
        let stub = UnmergedStub(
            libraries: [lib("L1", "Movies", .movie), lib("L2", "Shows", .series)],
            itemsByContainer: ["L1": [item("m1")], "L2": [item("s1")]],
            hubsByLibrary: ["L1": [LibrarySection(id: "genre", title: "More in Drama", style: .poster, items: [item("h1")])]]
        )
        let accounts = [resolved("acct", provider: stub)]
        // L1 opts into both rows; L2 opts into Recently Added only.
        let visibility = vis([
            ("acct:L1", .recentlyAdded), ("acct:L1", .hubs),
            ("acct:L2", .recentlyAdded)
        ])

        let content = await HomeAggregator().unmergedContent(from: accounts, visibility: visibility)

        XCTAssertEqual(content.librarySections.map(\.library.key), ["acct:L1", "acct:L2"])
        // L1: Recently Added (titled per-library) + the discovery hub. No per-library
        // Continue Watching — that's always the single global row.
        XCTAssertEqual(content.librarySections[0].sections.map(\.title),
                       ["Recently Added in Movies", "More in Drama"])
        // L2: just its opted-in Recently Added row.
        XCTAssertEqual(content.librarySections[1].sections.map(\.title),
                       ["Recently Added in Shows"])
        // Items tagged with the owning account for routing.
        XCTAssertEqual(content.librarySections[0].sections[0].items.first?.sourceAccountID, "acct")
        // Full inventory still available for the Libraries tiles.
        XCTAssertEqual(content.libraries.map(\.library.id), ["L1", "L2"])
    }

    func testNoOptedInRowsYieldsNoSectionsButKeepsTiles() async {
        let stub = UnmergedStub(
            libraries: [lib("L1", "Movies", .movie)],
            itemsByContainer: ["L1": [item("m1")]]
        )
        let accounts = [resolved("acct", provider: stub)]

        // Default: nothing opted in → lean Home (tiles only, no row blocks).
        let content = await HomeAggregator().unmergedContent(from: accounts, visibility: HomeLibraryVisibility(mergeLibrariesOnHome: false))

        XCTAssertTrue(content.librarySections.isEmpty, "No rows opted in → no per-library blocks")
        XCTAssertEqual(content.libraries.map(\.library.id), ["L1"], "Libraries tiles still available")
    }

    func testOnlyEnabledRowsAreFetchedAndShown() async {
        let stub = UnmergedStub(
            libraries: [lib("L1", "Movies", .movie)],
            itemsByContainer: ["L1": [item("m1")]],
            hubsByLibrary: ["L1": [LibrarySection(id: "genre", title: "More in Drama", style: .poster, items: [item("h1")])]]
        )
        let accounts = [resolved("acct", provider: stub)]
        // Opt into hubs ONLY — Recently Added must not appear or be fetched.
        let visibility = vis([("acct:L1", .hubs)])

        let content = await HomeAggregator().unmergedContent(from: accounts, visibility: visibility)

        XCTAssertEqual(content.librarySections.first?.sections.map(\.title), ["More in Drama"])
        XCTAssertFalse(stub.itemsRequested, "Recently Added (items(in:)) must not be fetched when not opted in")
    }

    func testDisabledLibraryContributesNoSection() async {
        let stub = UnmergedStub(
            libraries: [lib("L1", "Movies", .movie)],
            itemsByContainer: ["L1": [item("m1")]]
        )
        let accounts = [resolved("acct", provider: stub)]
        // Row opted in, but the library is disabled app-wide → excluded.
        let visibility = vis([("acct:L1", .recentlyAdded)], disabled: ["acct:L1"])

        let content = await HomeAggregator().unmergedContent(from: accounts, visibility: visibility)

        XCTAssertTrue(content.librarySections.isEmpty, "A disabled library contributes no block")
    }

    // MARK: - Music exclusion

    func testMusicLibraryGetsNoUnmergedSection() async {
        let stub = UnmergedStub(
            libraries: [lib("L1", "Movies", .movie),
                        MediaLibrary(id: "M1", title: "Music", kind: .folder, isMusic: true)],
            itemsByContainer: ["L1": [item("m1")], "M1": [item("album1")]]
        )
        let accounts = [resolved("acct", provider: stub)]
        // Even if the user somehow opted a music row in, music never sections.
        let visibility = vis([("acct:L1", .recentlyAdded), ("acct:M1", .recentlyAdded)])

        let content = await HomeAggregator().unmergedContent(from: accounts, visibility: visibility)

        XCTAssertEqual(content.librarySections.map(\.library.key), ["acct:L1"],
                       "A music library must not get a Home section — it lives in the Music tab")
        XCTAssertEqual(content.libraries.map(\.library.id), ["L1"],
                       "Music library tiles are excluded from Home too")
    }

    func testMergedContentExcludesMusicLibraryTilesAndItems() async {
        let stub = UnmergedStub(
            libraries: [lib("L1", "Movies", .movie),
                        MediaLibrary(id: "M1", title: "Music", kind: .folder, isMusic: true)],
            continueWatching: [cw("cw1", library: "L1")],
            latest: [cw("newMovie", library: "L1"), cw("newAlbum", library: "M1")]
        )
        let accounts = [resolved("acct", provider: stub)]

        let content = await HomeAggregator().content(from: accounts, visibility: .default)

        XCTAssertEqual(content.libraries.map(\.library.id), ["L1"],
                       "Music library tiles are excluded from Home")
        XCTAssertEqual(content.latest.map(\.id), ["newMovie"],
                       "A music item must not leak into the Recently Added row")
    }

    // MARK: - Helpers

    private func item(_ id: String) -> MediaItem { MediaItem(id: id, title: id, kind: .movie) }
    private func cw(_ id: String, library: String) -> MediaItem {
        MediaItem(id: id, title: id, kind: .movie, libraryID: library)
    }
    private func lib(_ id: String, _ title: String, _ kind: MediaItemKind) -> MediaLibrary {
        MediaLibrary(id: id, title: title, kind: kind)
    }
    private func resolved(_ id: String, provider: any MediaProvider) -> ResolvedAccount {
        let server = MediaServer(id: "srv-\(id)", name: "S", baseURL: URL(string: "http://host")!, provider: .jellyfin)
        let account = Account(id: id, server: server, userID: "u-\(id)", userName: "U", deviceID: "d-\(id)")
        return ResolvedAccount(account: account, provider: provider)
    }
}

/// `MediaProvider` stub for the unmerged tests: returns configurable libraries,
/// a global Continue Watching feed, per-container Recently Added items, and
/// per-library discovery hubs. `continueWatchingByLibrary` models a Jellyfin-style
/// provider whose Continue Watching items are attributed to a library **only** on
/// the scoped fetch path; when it's empty the stub behaves Plex-style (the flat
/// `continueWatching` feed already carries `libraryID`).
private final class UnmergedStub: MediaProvider, @unchecked Sendable {
    let kind: ProviderKind = .jellyfin
    let session: UserSession
    private let stubbedLibraries: [MediaLibrary]
    private let stubbedContinueWatching: [MediaItem]
    private let stubbedLatest: [MediaItem]
    private let itemsByContainer: [String: [MediaItem]]
    private let hubsByLibrary: [String: [LibrarySection]]
    /// Whether `items(in:)` (Recently Added) was requested — lets a test prove a
    /// non-opted-in row is never fetched.
    private(set) var itemsRequested = false

    init(
        libraries: [MediaLibrary] = [],
        continueWatching: [MediaItem] = [],
        latest: [MediaItem] = [],
        itemsByContainer: [String: [MediaItem]] = [:],
        hubsByLibrary: [String: [LibrarySection]] = [:]
    ) {
        self.stubbedLibraries = libraries
        self.stubbedContinueWatching = continueWatching
        self.stubbedLatest = latest
        self.itemsByContainer = itemsByContainer
        self.hubsByLibrary = hubsByLibrary
        self.session = UserSession(
            server: MediaServer(id: "s", name: "Home", baseURL: URL(string: "http://host")!, provider: .jellyfin),
            userID: "u", userName: "User", deviceID: "d", accessToken: "TOKEN"
        )
    }

    func libraries() async throws -> [MediaLibrary] { stubbedLibraries }
    func continueWatching(limit: Int) async throws -> [MediaItem] { stubbedContinueWatching }
    func latest(limit: Int) async throws -> [MediaItem] { stubbedLatest }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        itemsRequested = true
        let items = itemsByContainer[containerID] ?? []
        return MediaPage(items: items, startIndex: 0, totalCount: items.count)
    }
    func libraryHubs(libraryID: String, kind: MediaItemKind, limit: Int) async throws -> [LibrarySection] {
        hubsByLibrary[libraryID] ?? []
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
