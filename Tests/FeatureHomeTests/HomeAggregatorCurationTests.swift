import XCTest
import CoreModels
@testable import FeatureHome

/// Proves the Continue Watching policy is applied where every backend passes
/// through, rather than per-provider.
///
/// The staleness problem is not Plex's alone. Plex's `/library/onDeck` offers
/// next-up episodes its own hub has retired; Jellyfin's `Shows/NextUp` is bounded
/// by a server setting that defaults to a year; Emby rides the Jellyfin path.
/// Applying the rule in the aggregator means one behaviour for all of them, and a
/// new backend inherits it for free.
@MainActor
final class HomeAggregatorCurationTests: XCTestCase {

    private func resolved(_ id: String, provider: any MediaProvider) -> ResolvedAccount {
        let server = MediaServer(
            id: "srv-\(id)", name: "S", baseURL: URL(string: "http://host")!, provider: .jellyfin
        )
        let account = Account(id: id, server: server, userID: "u-\(id)", userName: "U", deviceID: "d-\(id)")
        return ResolvedAccount(account: account, provider: provider)
    }

    private func suggestion(_ id: String, daysAgo: Double) -> MediaItem {
        var item = MediaItem(id: id, title: id, kind: .episode)
        item.lastPlayedAt = Date().addingTimeInterval(-daysAgo * 86_400)
        return item
    }

    private func inProgress(_ id: String, daysAgo: Double) -> MediaItem {
        var item = MediaItem(id: id, title: id, kind: .movie)
        item.resumePosition = 900
        item.lastPlayedAt = Date().addingTimeInterval(-daysAgo * 86_400)
        return item
    }

    private var merged: HomeLibraryVisibility { HomeLibraryVisibility(mergeLibrariesOnHome: true) }

    func testStaleSuggestionsAreRetiredButHalfWatchedTitlesSurvive() async {
        let stub = ResumeStub(continueWatching: [
            inProgress("halfway-but-ancient", daysAgo: 400),
            suggestion("suggested-recently", daysAgo: 3),
            suggestion("suggested-long-ago", daysAgo: 400)
        ])

        let content = await HomeAggregator().content(
            from: [resolved("acct", provider: stub)],
            policy: ContinueWatchingPolicy(nextUpCutoff: 90 * 86_400),
            visibility: merged
        )

        XCTAssertEqual(
            Set(content.continueWatching.map(\.id)),
            ["halfway-but-ancient", "suggested-recently"],
            "Only the abandoned suggestion goes; a title left halfway is where the viewer stopped"
        )
    }

    /// The row limit was a hardcoded 20 that quietly discarded the rest of a real
    /// library, with no way to reach what fell off.
    func testTheRowCarriesMoreThanTheOldTwentyItemCap() async {
        let many = (1...50).map { inProgress("m\($0)", daysAgo: Double($0) / 24) }
        let stub = ResumeStub(continueWatching: many)

        let content = await HomeAggregator().content(
            from: [resolved("acct", provider: stub)],
            policy: ContinueWatchingPolicy(rowLimit: 60),
            visibility: merged
        )

        XCTAssertEqual(content.continueWatching.count, 50)
    }

    func testTheRowLimitIsStillHonoured() async {
        let many = (1...50).map { inProgress("m\($0)", daysAgo: Double($0) / 24) }
        let stub = ResumeStub(continueWatching: many)

        let content = await HomeAggregator().content(
            from: [resolved("acct", provider: stub)],
            policy: ContinueWatchingPolicy(rowLimit: 10),
            visibility: merged
        )

        XCTAssertEqual(content.continueWatching.count, 10)
    }

    /// A backend that reports no recency must not have its row silently emptied.
    func testABackendThatReportsNoRecencyKeepsItsRow() async {
        let stub = ResumeStub(continueWatching: [
            MediaItem(id: "no-timestamp", title: "Untimed", kind: .movie)
        ])

        let content = await HomeAggregator().content(
            from: [resolved("acct", provider: stub)],
            policy: ContinueWatchingPolicy(nextUpCutoff: 1),
            visibility: merged
        )

        XCTAssertEqual(content.continueWatching.map(\.id), ["no-timestamp"])
    }

    /// Unmerged mode renders the same global row and must curate identically —
    /// otherwise flipping one display switch changes which titles exist.
    func testUnmergedModeCuratesTheSameWay() async {
        let stub = ResumeStub(continueWatching: [
            inProgress("halfway-but-ancient", daysAgo: 400),
            suggestion("suggested-long-ago", daysAgo: 400)
        ])

        let content = await HomeAggregator().unmergedContent(
            from: [resolved("acct", provider: stub)],
            policy: ContinueWatchingPolicy(nextUpCutoff: 90 * 86_400),
            visibility: HomeLibraryVisibility(mergeLibrariesOnHome: false)
        )

        XCTAssertEqual(content.continueWatching.map(\.id), ["halfway-but-ancient"])
    }
}

/// Minimal provider returning a fixed resume feed.
private final class ResumeStub: MediaProvider, @unchecked Sendable {
    let kind: ProviderKind = .jellyfin
    private let stubbedContinueWatching: [MediaItem]

    init(continueWatching: [MediaItem]) {
        self.stubbedContinueWatching = continueWatching
    }

    var session: UserSession {
        UserSession(
            server: MediaServer(
                id: "srv", name: "S", baseURL: URL(string: "http://host")!, provider: .jellyfin
            ),
            userID: "u", userName: "User", deviceID: "d", accessToken: "TOKEN"
        )
    }

    func libraries() async throws -> [MediaLibrary] {
        [MediaLibrary(id: "L1", title: "Movies", kind: .movie)]
    }
    func continueWatching(limit: Int) async throws -> [MediaItem] {
        Array(stubbedContinueWatching.prefix(limit))
    }
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
