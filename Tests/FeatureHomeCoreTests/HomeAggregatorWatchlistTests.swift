import XCTest
import CoreModels
@testable import FeatureHomeCore

/// Feature B: the unified Watchlist row merges every `WatchlistProviding`
/// account (cross-provider / cross-server) and degrades gracefully when an
/// account can't express a watchlist.
@MainActor
final class HomeAggregatorWatchlistTests: XCTestCase {
    func testWatchlistMergesAndTagsAcrossWatchlistProviders() async {
        let a = WatchlistStub(watchlist: [item("a-w1"), item("a-w2")])
        let b = WatchlistStub(watchlist: [item("b-w1")])
        let accounts = [
            resolved("acct-a", kind: .jellyfin, provider: a),
            resolved("acct-b", kind: .jellyfin, provider: b)
        ]

        let content = await HomeAggregator().content(from: accounts)

        // Round-robin interleave across servers, each row source-tagged.
        XCTAssertEqual(content.watchlist.map(\.id), ["a-w1", "b-w1", "a-w2"])
        XCTAssertEqual(content.watchlist.first?.sourceAccountID, "acct-a")
        XCTAssertEqual(content.watchlist[1].sourceAccountID, "acct-b")
    }

    func testNonWatchlistProviderContributesNothing() async {
        let withList = WatchlistStub(watchlist: [item("w1")])
        let without = PlainStub()
        let accounts = [
            resolved("acct-list", kind: .jellyfin, provider: withList),
            resolved("acct-plain", kind: .plex, provider: without)
        ]

        let content = await HomeAggregator().content(from: accounts)
        XCTAssertEqual(content.watchlist.map(\.id), ["w1"])
    }

    func testWatchlistEmptyWhenFetchFails() async {
        let failing = WatchlistStub(watchlist: [], shouldFail: true)
        let accounts = [resolved("acct-x", kind: .jellyfin, provider: failing)]
        let content = await HomeAggregator().content(from: accounts)
        XCTAssertTrue(content.watchlist.isEmpty)
    }

    // MARK: - Helpers

    private func item(_ id: String) -> MediaItem { MediaItem(id: id, title: id, kind: .movie) }

    private func resolved(_ id: String, kind: ProviderKind, provider: any MediaProvider) -> ResolvedAccount {
        let server = MediaServer(id: "srv-\(id)", name: id, baseURL: URL(string: "http://host")!, provider: kind)
        let account = Account(id: id, server: server, userID: "u-\(id)", userName: id, deviceID: "d-\(id)")
        return ResolvedAccount(account: account, provider: provider)
    }
}

/// A provider that also conforms to `WatchlistProviding`.
private final class WatchlistStub: MediaProvider, WatchlistProviding, @unchecked Sendable {
    let kind: ProviderKind = .jellyfin
    let session: UserSession
    private let stubbed: [MediaItem]
    private let shouldFail: Bool

    init(watchlist: [MediaItem], shouldFail: Bool = false) {
        self.stubbed = watchlist
        self.shouldFail = shouldFail
        self.session = UserSession(
            server: MediaServer(id: "s", name: "Home", baseURL: URL(string: "http://host")!, provider: .jellyfin),
            userID: "u", userName: "User", deviceID: "d", accessToken: "TOKEN"
        )
    }

    func setWatchlisted(_ on: Bool, item: MediaItem) async throws {}
    func watchlist() async throws -> [MediaItem] {
        if shouldFail { throw AppError.serverUnreachable }
        return stubbed
    }

    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
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

/// A provider with no watchlist capability.
private final class PlainStub: MediaProvider, @unchecked Sendable {
    let kind: ProviderKind = .plex
    let session = UserSession(
        server: MediaServer(id: "s", name: "Home", baseURL: URL(string: "http://host")!, provider: .plex),
        userID: "u", userName: "User", deviceID: "d", accessToken: "TOKEN"
    )
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
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
