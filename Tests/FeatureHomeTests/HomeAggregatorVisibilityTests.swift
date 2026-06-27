import XCTest
import CoreModels
@testable import FeatureHome

/// Verifies the Home aggregator's per-account fetch-scoping decision that powers
/// "hide a library everywhere": when an account has **no** hidden library it keeps
/// the original single unscoped fetch (zero perf regression); when at least one
/// library is hidden it switches to a fetch scoped to only the **visible**
/// libraries, so a provider that can only attribute items by scoping (Jellyfin)
/// both drops hidden content at the source and stamps `libraryID` on the rest.
@MainActor
final class HomeAggregatorVisibilityTests: XCTestCase {

    func testNoHiddenLibraryUsesUnscopedFetch() async {
        let stub = ScopeRecordingStub(
            libraries: [library("L1", "Movies"), library("L2", "Shows")],
            continueWatching: [item("cw1")],
            latest: [item("l1")]
        )
        let accounts = [resolved("acct", provider: stub)]

        _ = await HomeAggregator().content(from: accounts, visibility: .default)

        XCTAssertTrue(stub.unscopedContinueWatchingCalled,
                      "With nothing hidden the aggregator must use the fast unscoped fetch")
        XCTAssertNil(stub.scopedContinueWatchingLibraries,
                     "No scoped fetch should happen when nothing is hidden")
    }

    func testHiddenLibraryScopesFetchToVisibleLibrariesOnly() async {
        let stub = ScopeRecordingStub(
            libraries: [library("L1", "Movies"), library("L2", "Shows")],
            continueWatching: [item("cw1")],
            latest: [item("l1")]
        )
        let accounts = [resolved("acct", provider: stub)]
        let visibility = HomeLibraryVisibility(excludedKeys: ["acct:L2"])

        _ = await HomeAggregator().content(from: accounts, visibility: visibility)

        XCTAssertFalse(stub.unscopedContinueWatchingCalled,
                       "When a library is hidden the aggregator must not use the unscoped fetch")
        XCTAssertEqual(stub.scopedContinueWatchingLibraries, ["L1"],
                       "Scoped fetch must request only the visible libraries")
        XCTAssertEqual(stub.scopedLatestLibraries, ["L1"])
    }

    func testHidingOneAccountDoesNotScopeAnother() async {
        let hidden = ScopeRecordingStub(libraries: [library("L1", "A"), library("L2", "B")])
        let untouched = ScopeRecordingStub(libraries: [library("L1", "C")])
        let accounts = [
            resolved("acct-hidden", provider: hidden),
            resolved("acct-other", provider: untouched)
        ]
        let visibility = HomeLibraryVisibility(excludedKeys: ["acct-hidden:L2"])

        _ = await HomeAggregator().content(from: accounts, visibility: visibility)

        XCTAssertEqual(hidden.scopedContinueWatchingLibraries, ["L1"],
                       "Only the account with a hidden library scopes its fetch")
        XCTAssertTrue(untouched.unscopedContinueWatchingCalled,
                      "An account with nothing hidden keeps the unscoped fetch")
        XCTAssertNil(untouched.scopedContinueWatchingLibraries)
    }

    // MARK: - Helpers

    private func item(_ id: String) -> MediaItem { MediaItem(id: id, title: id, kind: .movie) }
    private func library(_ id: String, _ title: String) -> MediaLibrary {
        MediaLibrary(id: id, title: title, kind: .movie)
    }

    private func resolved(_ id: String, provider: any MediaProvider) -> ResolvedAccount {
        let server = MediaServer(id: "srv-\(id)", name: "S", baseURL: URL(string: "http://host")!, provider: .jellyfin)
        let account = Account(id: id, server: server, userID: "u-\(id)", userName: "U", deviceID: "d-\(id)")
        return ResolvedAccount(account: account, provider: provider)
    }
}

/// `MediaProvider` stub that records whether the unscoped or the library-scoped
/// row methods were called (and with which library ids).
private final class ScopeRecordingStub: MediaProvider, @unchecked Sendable {
    let kind: ProviderKind = .jellyfin
    let session: UserSession
    private let stubbedLibraries: [MediaLibrary]
    private let stubbedContinueWatching: [MediaItem]
    private let stubbedLatest: [MediaItem]

    private(set) var unscopedContinueWatchingCalled = false
    private(set) var scopedContinueWatchingLibraries: [String]?
    private(set) var scopedLatestLibraries: [String]?

    init(
        libraries: [MediaLibrary] = [],
        continueWatching: [MediaItem] = [],
        latest: [MediaItem] = []
    ) {
        self.stubbedLibraries = libraries
        self.stubbedContinueWatching = continueWatching
        self.stubbedLatest = latest
        self.session = UserSession(
            server: MediaServer(id: "s", name: "Home", baseURL: URL(string: "http://host")!, provider: .jellyfin),
            userID: "u", userName: "User", deviceID: "d", accessToken: "TOKEN"
        )
    }

    func libraries() async throws -> [MediaLibrary] { stubbedLibraries }

    func continueWatching(limit: Int) async throws -> [MediaItem] {
        unscopedContinueWatchingCalled = true
        return stubbedContinueWatching
    }

    func latest(limit: Int) async throws -> [MediaItem] { stubbedLatest }

    func continueWatching(limit: Int, inLibraries libraryIDs: [String]?) async throws -> [MediaItem] {
        guard let libraryIDs else { return try await continueWatching(limit: limit) }
        scopedContinueWatchingLibraries = libraryIDs
        return stubbedContinueWatching
    }

    func latest(limit: Int, inLibraries libraryIDs: [String]?) async throws -> [MediaItem] {
        guard let libraryIDs else { return try await latest(limit: limit) }
        scopedLatestLibraries = libraryIDs
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
