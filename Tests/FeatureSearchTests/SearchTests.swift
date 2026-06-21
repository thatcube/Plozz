import XCTest
import CoreModels
@testable import FeatureSearch

final class SearchPolicyTests: XCTestCase {
    func testNormalizedTrimsWhitespace() {
        XCTAssertEqual(SearchPolicy.normalized("  dune \n"), "dune")
        XCTAssertEqual(SearchPolicy.normalized("dune"), "dune")
    }

    func testShouldSearchOnlyForNonEmptyQuery() {
        XCTAssertFalse(SearchPolicy.shouldSearch(""))
        XCTAssertFalse(SearchPolicy.shouldSearch(SearchPolicy.normalized("   ")))
        XCTAssertTrue(SearchPolicy.shouldSearch("dune"))
    }

    func testIsCurrentIgnoresStaleResponses() {
        // Response for "dune" is still current when the live field reads "dune".
        XCTAssertTrue(SearchPolicy.isCurrent(requestedQuery: "dune", liveQuery: "dune"))
        // Whitespace-only differences don't make it stale.
        XCTAssertTrue(SearchPolicy.isCurrent(requestedQuery: "dune", liveQuery: " dune "))
        // The user kept typing: the in-flight "dune" result is now stale.
        XCTAssertFalse(SearchPolicy.isCurrent(requestedQuery: "dune", liveQuery: "dune 2"))
    }
}

final class SearchSectionTests: XCTestCase {
    private func item(_ id: String, _ kind: MediaItemKind) -> MediaItem {
        MediaItem(id: id, title: id, kind: kind)
    }

    func testSectionsGroupByKindInStableOrder() {
        let items = [
            item("e1", .episode),
            item("m1", .movie),
            item("s1", .series),
            item("m2", .movie)
        ]

        let sections = SearchSection.sections(from: items)

        XCTAssertEqual(sections.map(\.title), ["Movies", "TV Shows", "Episodes"])
        XCTAssertEqual(sections[0].items.map(\.id), ["m1", "m2"])
        XCTAssertEqual(sections[1].items.map(\.id), ["s1"])
        XCTAssertEqual(sections[2].items.map(\.id), ["e1"])
    }

    func testSectionsDropEmptyGroupsAndCollectOther() {
        let items = [item("c1", .collection), item("m1", .movie)]

        let sections = SearchSection.sections(from: items)

        XCTAssertEqual(sections.map(\.title), ["Movies", "Other"])
        XCTAssertEqual(sections.last?.items.map(\.id), ["c1"])
    }

    func testEmptyInputYieldsNoSections() {
        XCTAssertTrue(SearchSection.sections(from: []).isEmpty)
    }
}

@MainActor
final class SearchViewModelTests: XCTestCase {
    func testBlankQueryResetsToIdleWithoutSearching() async {
        let provider = SearchStubProvider(results: makeItems(3))
        let vm = SearchViewModel(provider: provider, debounceMilliseconds: 0)
        vm.query = "   "

        await vm.search()

        if case .idle = vm.state {} else { XCTFail("Expected idle, got \(vm.state)") }
        XCTAssertEqual(provider.callCount, 0)
    }

    func testQueryLoadsSectionedResults() async {
        let provider = SearchStubProvider(results: [
            MediaItem(id: "m1", title: "Dune", kind: .movie),
            MediaItem(id: "s1", title: "Dune: Prophecy", kind: .series)
        ])
        let vm = SearchViewModel(provider: provider, debounceMilliseconds: 0)
        vm.query = "dune"

        await vm.search()

        guard case let .loaded(sections) = vm.state else {
            return XCTFail("Expected loaded, got \(vm.state)")
        }
        XCTAssertEqual(sections.map(\.title), ["Movies", "TV Shows"])
        XCTAssertEqual(provider.lastQuery, "dune")
    }

    func testNoResultsYieldsEmptyState() async {
        let provider = SearchStubProvider(results: [])
        let vm = SearchViewModel(provider: provider, debounceMilliseconds: 0)
        vm.query = "zzz"

        await vm.search()

        if case .empty = vm.state {} else { XCTFail("Expected empty, got \(vm.state)") }
    }

    func testFailureSurfacesError() async {
        let provider = SearchStubProvider(results: [], error: .serverUnreachable)
        let vm = SearchViewModel(provider: provider, debounceMilliseconds: 0)
        vm.query = "dune"

        await vm.search()

        if case .failed(.serverUnreachable) = vm.state {} else {
            XCTFail("Expected failed(.serverUnreachable), got \(vm.state)")
        }
    }
}

/// Minimal `MediaProvider` stub that only implements `search`.
private final class SearchStubProvider: MediaProvider, @unchecked Sendable {
    let kind: ProviderKind = .jellyfin
    let session: UserSession
    private let results: [MediaItem]
    private let error: AppError?
    private(set) var callCount = 0
    private(set) var lastQuery: String?

    init(results: [MediaItem], error: AppError? = nil) {
        self.results = results
        self.error = error
        self.session = UserSession(
            server: MediaServer(id: "s", name: "Home", baseURL: URL(string: "http://host:8096")!, provider: .jellyfin),
            userID: "u1", userName: "Alice", deviceID: "d1", accessToken: "TOKEN"
        )
    }

    func search(query: String, limit: Int) async throws -> [MediaItem] {
        callCount += 1
        lastQuery = query
        if let error { throw error }
        return results
    }

    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        MediaPage(items: [], startIndex: 0, totalCount: 0)
    }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}

private func makeItems(_ count: Int) -> [MediaItem] {
    (0..<count).map { MediaItem(id: "i\($0)", title: "Item \($0)", kind: .movie) }
}
