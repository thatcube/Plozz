import XCTest
import CoreModels
@testable import FeatureHome

@MainActor
final class HomeAggregatorTests: XCTestCase {
    func testInterleaveRoundRobinPreservesGroupOrder() {
        let merged = HomeAggregator.interleave([["a1", "a2", "a3"], ["b1"], ["c1", "c2"]])
        XCTAssertEqual(merged, ["a1", "b1", "c1", "a2", "c2", "a3"])
    }

    func testInterleaveEmptyGroups() {
        XCTAssertEqual(HomeAggregator.interleave([[String]]()), [])
        XCTAssertEqual(HomeAggregator.interleave([[], ["x"], []]), ["x"])
    }

    func testContentMergesTagsAndInterleavesAcrossAccounts() async {
        let plex = AggregatorStub(
            libraries: [library("L1", "Movies")],
            continueWatching: [item("p-cw1")],
            latest: [item("p-l1"), item("p-l2")]
        )
        let jelly = AggregatorStub(
            libraries: [library("L9", "Anime")],
            continueWatching: [item("j-cw1")],
            latest: [item("j-l1")]
        )
        let accounts = [
            resolved("acct-plex", user: "Bob", server: "Plex Server", kind: .plex, provider: plex),
            resolved("acct-jelly", user: "Alice", server: "Jelly Server", kind: .jellyfin, provider: jelly)
        ]

        let content = await HomeAggregator().content(from: accounts)

        // Continue Watching: round-robin interleaved and source-tagged.
        XCTAssertEqual(content.continueWatching.map(\.id), ["p-cw1", "j-cw1"])
        XCTAssertEqual(content.continueWatching.first?.sourceAccountID, "acct-plex")
        XCTAssertEqual(content.continueWatching.last?.sourceAccountID, "acct-jelly")

        // Recently Added: p-l1, j-l1, p-l2 (one from each, then the remainder).
        XCTAssertEqual(content.latest.map(\.id), ["p-l1", "j-l1", "p-l2"])

        // Libraries: tagged with account/provider metadata and a stable key.
        XCTAssertEqual(content.libraries.count, 2)
        let first = content.libraries[0]
        XCTAssertEqual(first.accountID, "acct-plex")
        XCTAssertEqual(first.accountName, "Bob")
        XCTAssertEqual(first.serverName, "Plex Server")
        XCTAssertEqual(first.providerKind, .plex)
        XCTAssertEqual(first.key, "acct-plex:L1")
        XCTAssertEqual(first.library.sourceAccountID, "acct-plex")
    }

    func testContentResilientToOneProviderFailing() async {
        let good = AggregatorStub(
            libraries: [library("L1", "Movies")],
            continueWatching: [item("g1")],
            latest: []
        )
        let bad = AggregatorStub.failing()
        let accounts = [
            resolved("acct-good", user: "A", server: "S1", kind: .jellyfin, provider: good),
            resolved("acct-bad", user: "B", server: "S2", kind: .plex, provider: bad)
        ]

        let content = await HomeAggregator().content(from: accounts)

        XCTAssertEqual(content.libraries.map(\.accountID), ["acct-good"])
        XCTAssertEqual(content.continueWatching.map(\.id), ["g1"])
        XCTAssertTrue(content.latest.isEmpty)
    }

    func testLibrariesDiscoveryTagsEveryAccount() async {
        let plex = AggregatorStub(libraries: [library("L1", "Movies"), library("L2", "Shows")])
        let jelly = AggregatorStub(libraries: [library("L1", "Films")])
        let accounts = [
            resolved("acct-plex", user: "Bob", server: "Plex", kind: .plex, provider: plex),
            resolved("acct-jelly", user: "Alice", server: "Jelly", kind: .jellyfin, provider: jelly)
        ]

        let libraries = await HomeAggregator().libraries(from: accounts)

        XCTAssertEqual(libraries.map(\.key), ["acct-plex:L1", "acct-plex:L2", "acct-jelly:L1"])
        // Same underlying library id on two accounts stays distinct via the key.
        XCTAssertEqual(Set(libraries.map(\.key)).count, 3)
    }

    func testContentDedupesSameTitleAcrossServersAndUnifiesState() async {
        // The same movie (shared Tmdb id) on Plex and Jellyfin, watched more
        // recently on Jellyfin.
        let plexCopy = MediaItem(id: "p-dune", title: "Dune", kind: .movie,
                                 productionYear: 2021, providerIDs: ["Tmdb": "438631"])
        let jellyCopy = MediaItem(id: "j-dune", title: "Dune", kind: .movie,
                                  productionYear: 2021, resumePosition: 240,
                                  providerIDs: ["Tmdb": "438631"],
                                  lastPlayedAt: Date(timeIntervalSince1970: 999))
        let plex = AggregatorStub(continueWatching: [plexCopy])
        let jelly = AggregatorStub(continueWatching: [jellyCopy])
        let accounts = [
            resolved("acct-plex", user: "Bob", server: "Plex", kind: .plex, provider: plex),
            resolved("acct-jelly", user: "Alice", server: "Jelly", kind: .jellyfin, provider: jelly)
        ]

        let content = await HomeAggregator().content(from: accounts)

        XCTAssertEqual(content.continueWatching.count, 1, "Same movie on two servers shows once")
        let card = content.continueWatching[0]
        XCTAssertEqual(card.sourceAccountID, "acct-plex", "First server stays primary")
        XCTAssertEqual(Set(card.allSourceAccountIDs), ["acct-plex", "acct-jelly"])
        XCTAssertEqual(card.resumePosition, 240, "Unified watch-state reflects the newer Jellyfin progress")
        XCTAssertEqual(card.sources.first { $0.accountID == "acct-jelly" }?.itemID, "j-dune",
                       "Each server's own item id is retained for playback")
        // Server labels come from the resolved accounts.
        XCTAssertEqual(card.sources.first?.providerKind, .plex)
    }

    func testContentDedupesSeriesAcrossServersWhenExternalIDsPresent() async {
        // Series identity is external-id-only (never title/year), so this must
        // collapse only because both servers carry the same TMDb id.
        let plexCopy = MediaItem(id: "p-op", title: "One Piece", kind: .series,
                                 productionYear: 1999, providerIDs: ["Tmdb": "37854"])
        let jellyCopy = MediaItem(id: "j-op", title: "One Piece", kind: .series,
                                  productionYear: 2023, providerIDs: ["Tmdb": "37854"])
        let plex = AggregatorStub(latest: [plexCopy])
        let jelly = AggregatorStub(latest: [jellyCopy])
        let accounts = [
            resolved("acct-plex", user: "Bob", server: "Plex", kind: .plex, provider: plex),
            resolved("acct-jelly", user: "Alice", server: "Jelly", kind: .jellyfin, provider: jelly)
        ]

        let content = await HomeAggregator().content(from: accounts)

        XCTAssertEqual(content.latest.count, 1)
        let card = content.latest[0]
        XCTAssertEqual(card.id, "p-op")
        XCTAssertEqual(card.sources.count, 2, "Merged card exposes both server sources for the picker")
        XCTAssertEqual(Set(card.allSourceAccountIDs), ["acct-plex", "acct-jelly"])
    }

    // MARK: - Helpers

    private func item(_ id: String) -> MediaItem {
        MediaItem(id: id, title: id, kind: .movie)
    }

    private func library(_ id: String, _ title: String) -> MediaLibrary {
        MediaLibrary(id: id, title: title, kind: .movie)
    }

    private func resolved(
        _ id: String,
        user: String,
        server: String,
        kind: ProviderKind,
        provider: AggregatorStub
    ) -> ResolvedAccount {
        let mediaServer = MediaServer(
            id: "srv-\(id)",
            name: server,
            baseURL: URL(string: "http://host")!,
            provider: kind
        )
        let account = Account(id: id, server: mediaServer, userID: "u-\(id)", userName: user, deviceID: "d-\(id)")
        return ResolvedAccount(account: account, provider: provider)
    }
}

/// Configurable `MediaProvider` stub for aggregation tests.
private final class AggregatorStub: MediaProvider, @unchecked Sendable {
    let kind: ProviderKind = .jellyfin
    let session: UserSession
    private let stubbedLibraries: [MediaLibrary]
    private let stubbedContinueWatching: [MediaItem]
    private let stubbedLatest: [MediaItem]
    private let shouldFail: Bool

    init(
        libraries: [MediaLibrary] = [],
        continueWatching: [MediaItem] = [],
        latest: [MediaItem] = [],
        shouldFail: Bool = false
    ) {
        self.stubbedLibraries = libraries
        self.stubbedContinueWatching = continueWatching
        self.stubbedLatest = latest
        self.shouldFail = shouldFail
        self.session = UserSession(
            server: MediaServer(id: "s", name: "Home", baseURL: URL(string: "http://host")!, provider: .jellyfin),
            userID: "u", userName: "User", deviceID: "d", accessToken: "TOKEN"
        )
    }

    static func failing() -> AggregatorStub { AggregatorStub(shouldFail: true) }

    func libraries() async throws -> [MediaLibrary] {
        if shouldFail { throw AppError.serverUnreachable }
        return stubbedLibraries
    }

    func continueWatching(limit: Int) async throws -> [MediaItem] {
        if shouldFail { throw AppError.serverUnreachable }
        return stubbedContinueWatching
    }

    func latest(limit: Int) async throws -> [MediaItem] {
        if shouldFail { throw AppError.serverUnreachable }
        return stubbedLatest
    }

    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        MediaPage(items: [], startIndex: 0, totalCount: 0)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
