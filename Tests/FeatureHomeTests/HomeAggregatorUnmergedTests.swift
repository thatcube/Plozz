import XCTest
import CoreModels
@testable import FeatureHome

/// Verifies the unmerged Home aggregation: global Continue Watching / Watchlist
/// stay at the top, and every *visible-on-home* library gets its own ordered
/// block (Continue Watching → Recently Added → provider discovery hubs), with
/// empty blocks dropped and disabled/hidden libraries excluded.
@MainActor
final class HomeAggregatorUnmergedTests: XCTestCase {

    func testBuildsPerLibrarySectionsInOrder() async {
        let stub = UnmergedStub(
            libraries: [lib("L1", "Movies", .movie), lib("L2", "Shows", .series)],
            continueWatching: [cw("cw1", library: "L1"), cw("cw2", library: "L2")],
            itemsByContainer: ["L1": [item("m1")], "L2": [item("s1")]],
            hubsByLibrary: ["L1": [LibrarySection(id: "genre", title: "More in Drama", style: .poster, items: [item("h1")])]]
        )
        let accounts = [resolved("acct", provider: stub)]

        let content = await HomeAggregator().unmergedContent(from: accounts, visibility: .default)

        XCTAssertEqual(content.librarySections.map(\.library.key), ["acct:L1", "acct:L2"])
        // L1: Continue Watching + Recently Added + the Plex-style discovery hub.
        XCTAssertEqual(content.librarySections[0].sections.map(\.title),
                       ["Continue Watching", "Recently Added", "More in Drama"])
        // L2: no hubs configured → just the two base rows.
        XCTAssertEqual(content.librarySections[1].sections.map(\.title),
                       ["Continue Watching", "Recently Added"])
        // Section items are tagged with the owning account for routing.
        XCTAssertEqual(content.librarySections[0].sections[1].items.first?.sourceAccountID, "acct")
        // Global Continue Watching row still carries every library's resumes.
        XCTAssertEqual(content.continueWatching.count, 2)
    }

    func testAllLibrariesDisabledYieldsNoSections() async {
        let stub = UnmergedStub(
            libraries: [lib("L1", "Movies", .movie)],
            continueWatching: [cw("cw1", library: "L1")],
            itemsByContainer: ["L1": [item("m1")]]
        )
        let accounts = [resolved("acct", provider: stub)]
        let visibility = HomeLibraryVisibility(disabledKeys: ["acct:L1"])

        let content = await HomeAggregator().unmergedContent(from: accounts, visibility: visibility)

        XCTAssertTrue(content.librarySections.isEmpty, "A disabled library contributes no block")
    }

    func testHomeHiddenLibraryExcludedFromSections() async {
        let stub = UnmergedStub(
            libraries: [lib("L1", "Movies", .movie), lib("L2", "Shows", .series)],
            continueWatching: [],
            itemsByContainer: ["L1": [item("m1")], "L2": [item("s1")]]
        )
        let accounts = [resolved("acct", provider: stub)]
        // L2 hidden from Home only (still enabled elsewhere).
        let visibility = HomeLibraryVisibility(excludedKeys: ["acct:L2"])

        let content = await HomeAggregator().unmergedContent(from: accounts, visibility: visibility)

        XCTAssertEqual(content.librarySections.map(\.library.key), ["acct:L1"])
    }

    func testEmptyLibraryBlockIsDropped() async {
        let stub = UnmergedStub(
            libraries: [lib("L1", "Movies", .movie), lib("L2", "Empty", .movie)],
            continueWatching: [cw("cw1", library: "L1")],
            itemsByContainer: ["L1": [item("m1")]] // L2 has nothing anywhere
        )
        let accounts = [resolved("acct", provider: stub)]

        let content = await HomeAggregator().unmergedContent(from: accounts, visibility: .default)

        XCTAssertEqual(content.librarySections.map(\.library.key), ["acct:L1"],
                       "A library with no Continue Watching / Recently Added / hubs is dropped")
    }

    /// Locks in the fix for the Jellyfin attribution gap: an unscoped Continue
    /// Watching feed carries no `libraryID`, so per-library rows must come from the
    /// forced *scoped* fetch even when nothing is hidden. Here the unscoped feed is
    /// unattributed and only the scoped path tags items.
    func testJellyfinStyleContinueWatchingAttributedViaForcedScoping() async {
        let stub = UnmergedStub(
            libraries: [lib("L1", "Movies", .movie)],
            continueWatching: [item("unattributed")],           // unscoped: no libraryID
            continueWatchingByLibrary: ["L1": [item("cwL1")]],   // scoped: attributed
            itemsByContainer: ["L1": [item("m1")]]
        )
        let accounts = [resolved("acct", provider: stub)]

        let content = await HomeAggregator().unmergedContent(from: accounts, visibility: .default)

        XCTAssertTrue(stub.scopedContinueWatchingCalled,
                      "Unmerged mode must force the library-scoped Continue Watching fetch")
        let l1 = content.librarySections.first { $0.library.key == "acct:L1" }
        let cwRow = l1?.sections.first { $0.title == "Continue Watching" }
        XCTAssertEqual(cwRow?.items.map(\.id), ["cwL1"],
                       "The scoped, attributed resume must populate the library's Continue Watching row")
    }

    // MARK: - Merge Continue Watching

    func testMergeContinueWatchingOnKeepsGlobalStripsPerLibrary() {
        let groups = [
            HomeLibrarySectionGroup(library: aggLib("acct", "L1"), sections: [
                LibrarySection(id: "continueWatching", title: "Continue Watching", style: .landscape, items: [item("cw1")]),
                LibrarySection(id: "recentlyAdded", title: "Recently Added", style: .poster, items: [item("r1")])
            ]),
            HomeLibrarySectionGroup(library: aggLib("acct", "L2"), sections: [
                LibrarySection(id: "continueWatching", title: "Continue Watching", style: .landscape, items: [item("cw2")])
            ])
        ]
        let result = HomeViewModel.applyingContinueWatchingMerge(
            global: [item("g1")], sections: groups, mergeContinueWatching: true
        )
        // Global row kept.
        XCTAssertEqual(result.global.map(\.id), ["g1"])
        // L1 keeps only Recently Added; L2 (CW-only) is dropped entirely.
        XCTAssertEqual(result.sections.map(\.library.key), ["acct:L1"])
        XCTAssertEqual(result.sections.first?.sections.map(\.id), ["recentlyAdded"])
    }

    func testMergeContinueWatchingOffHidesGlobalKeepsPerLibrary() {
        let groups = [
            HomeLibrarySectionGroup(library: aggLib("acct", "L1"), sections: [
                LibrarySection(id: "continueWatching", title: "Continue Watching", style: .landscape, items: [item("cw1")]),
                LibrarySection(id: "recentlyAdded", title: "Recently Added", style: .poster, items: [item("r1")])
            ])
        ]
        let result = HomeViewModel.applyingContinueWatchingMerge(
            global: [item("g1")], sections: groups, mergeContinueWatching: false
        )
        // Global row hidden; per-library CW preserved.
        XCTAssertTrue(result.global.isEmpty)
        XCTAssertEqual(result.sections.first?.sections.map(\.id), ["continueWatching", "recentlyAdded"])
    }

    // MARK: - Music exclusion

    func testMusicLibraryGetsNoUnmergedSection() async {
        let stub = UnmergedStub(
            libraries: [lib("L1", "Movies", .movie),
                        MediaLibrary(id: "M1", title: "Music", kind: .folder, isMusic: true)],
            continueWatching: [cw("cw1", library: "L1")],
            itemsByContainer: ["L1": [item("m1")], "M1": [item("album1")]]
        )
        let accounts = [resolved("acct", provider: stub)]

        let content = await HomeAggregator().unmergedContent(from: accounts, visibility: .default)

        XCTAssertEqual(content.librarySections.map(\.library.key), ["acct:L1"],
                       "A music library must not get a Home section — it lives in the Music tab")
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

    private func aggLib(_ account: String, _ id: String) -> AggregatedLibrary {
        AggregatedLibrary(accountID: account, accountName: "U", serverName: "S", providerKind: .jellyfin,
                          library: MediaLibrary(id: id, title: id, kind: .movie))
    }

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
    private let continueWatchingByLibrary: [String: [MediaItem]]
    private let stubbedLatest: [MediaItem]
    private let itemsByContainer: [String: [MediaItem]]
    private let hubsByLibrary: [String: [LibrarySection]]
    private(set) var scopedContinueWatchingCalled = false

    init(
        libraries: [MediaLibrary] = [],
        continueWatching: [MediaItem] = [],
        continueWatchingByLibrary: [String: [MediaItem]] = [:],
        latest: [MediaItem] = [],
        itemsByContainer: [String: [MediaItem]] = [:],
        hubsByLibrary: [String: [LibrarySection]] = [:]
    ) {
        self.stubbedLibraries = libraries
        self.stubbedContinueWatching = continueWatching
        self.continueWatchingByLibrary = continueWatchingByLibrary
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
    func continueWatching(limit: Int, inLibraries libraryIDs: [String]?) async throws -> [MediaItem] {
        guard let libraryIDs else { return stubbedContinueWatching }
        scopedContinueWatchingCalled = true
        if !continueWatchingByLibrary.isEmpty {
            // Jellyfin-style: attribution only exists once scoped.
            return libraryIDs.flatMap { lib in (continueWatchingByLibrary[lib] ?? []).map { $0.taggingLibrary(lib) } }
        }
        // Plex-style: the flat feed already carries libraryID; scope by filtering.
        return stubbedContinueWatching.filter { item in
            guard let lib = item.libraryID else { return false }
            return libraryIDs.contains(lib)
        }
    }
    func latest(limit: Int) async throws -> [MediaItem] { stubbedLatest }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
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
