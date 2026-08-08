import XCTest
@testable import CoreModels
@testable import FeatureHome

/// The combined "All Libraries" browse: many libraries (of different kinds, some
/// on the same account) paged as one sorted, de-duplicated grid.
///
/// These cover the things that only go wrong once there are more than two sources:
/// per-(account, container) paging, per-source kinds, the k-way merge frontier,
/// and not letting one unreachable server freeze the whole grid.
final class AllLibrariesBrowseTests: XCTestCase {

    private func movie(_ id: String, title: String, tmdb: String? = nil) -> MediaItem {
        MediaItem(
            id: id,
            title: title,
            kind: .movie,
            providerIDs: tmdb.map { ["Tmdb": $0] } ?? [:]
        )
    }

    private func series(_ id: String, title: String) -> MediaItem {
        MediaItem(id: id, title: title, kind: .series)
    }

    private func source(
        account: String,
        container: String,
        kind: MediaItemKind,
        provider: FakeMediaProvider
    ) -> AggregatedLibrarySource {
        AggregatedLibrarySource(
            accountID: account,
            containerID: container,
            provider: provider,
            kind: kind
        )
    }

    private func page(
        _ provider: AggregatedLibraryProvider,
        start: Int,
        limit: Int
    ) async throws -> MediaPage {
        try await provider.items(
            in: AllLibrariesBrowse.containerID,
            kind: .unknown,
            page: PageRequest(startIndex: start, limit: limit)
        )
    }

    func testTwoLibrariesOnOneAccountPageIndependently() async throws {
        // Keyed by account alone, the second library would inherit the first's
        // offsets and silently lose pages — the bug this key change prevents.
        let movies = FakeMediaProvider(allItems: [movie("m1", title: "Arrival"), movie("m2", title: "Dune")])
        let shows = FakeMediaProvider(allItems: [series("s1", title: "Better Call Saul")])
        let provider = AggregatedLibraryProvider(sources: [
            source(account: "acct", container: "movies", kind: .movie, provider: movies),
            source(account: "acct", container: "shows", kind: .series, provider: shows)
        ])

        let result = try await page(provider, start: 0, limit: 20)
        XCTAssertEqual(result.items.map(\.title), ["Arrival", "Better Call Saul", "Dune"])
        XCTAssertEqual(result.totalCount, 3)
    }

    func testEachSourcePagesWithItsOwnKind() async throws {
        let movies = FakeMediaProvider(allItems: [movie("m1", title: "Dune")])
        let shows = FakeMediaProvider(allItems: [series("s1", title: "Andor")])
        let provider = AggregatedLibraryProvider(sources: [
            source(account: "a", container: "movies", kind: .movie, provider: movies),
            source(account: "a", container: "shows", kind: .series, provider: shows)
        ])

        _ = try await page(provider, start: 0, limit: 20)
        XCTAssertEqual(movies.requestedKinds, [.movie])
        XCTAssertEqual(shows.requestedKinds, [.series])
    }

    func testResultIsNameSortedAcrossEveryLibrary() async throws {
        let a = FakeMediaProvider(allItems: [
            movie("a1", title: "Alien"),
            movie("a2", title: "Arrival"),
            movie("a3", title: "Avatar")
        ])
        // Each source returns ITS OWN page already sorted — that is the provider
        // contract the k-way merge relies on (a source's head is its smallest
        // remaining item), so the fixtures honour it too.
        let b = FakeMediaProvider(allItems: [
            movie("b3", title: "Aftersun"),
            movie("b1", title: "Amélie"),
            movie("b2", title: "Anatomy of a Fall")
        ])
        let c = FakeMediaProvider(allItems: [movie("c1", title: "The Matrix")])
        let provider = AggregatedLibraryProvider(sources: [
            source(account: "a", container: "1", kind: .movie, provider: a),
            source(account: "b", container: "1", kind: .movie, provider: b),
            source(account: "c", container: "1", kind: .movie, provider: c)
        ])

        let result = try await page(provider, start: 0, limit: 20)
        XCTAssertEqual(
            result.items.map(\.title),
            ["Aftersun", "Alien", "Amélie", "Anatomy of a Fall", "Arrival", "Avatar", "The Matrix"]
        )
    }

    func testDuplicateTitleAcrossLibrariesStillCollapsesToOneCard() async throws {
        let a = FakeMediaProvider(allItems: [movie("a1", title: "Dune", tmdb: "438631")])
        let b = FakeMediaProvider(allItems: [movie("b1", title: "Dune", tmdb: "438631")])
        let provider = AggregatedLibraryProvider(sources: [
            source(account: "a", container: "1", kind: .movie, provider: a),
            source(account: "b", container: "1", kind: .movie, provider: b)
        ])

        let result = try await page(provider, start: 0, limit: 20)
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(Set(result.items[0].sources.map(\.accountID)), ["a", "b"])
    }

    func testOneUnreachableLibraryDoesNotFreezeTheGrid() async throws {
        // The ordered merge cannot normally emit while a live source has nothing
        // buffered — but an unreachable one must be stepped over, or every title
        // already fetched from the healthy libraries would stay invisible.
        let healthy = FakeMediaProvider(allItems: [movie("h1", title: "Alien"), movie("h2", title: "Zodiac")])
        let dead = FakeMediaProvider(allItems: [])
        dead.alwaysFail = true
        let provider = AggregatedLibraryProvider(sources: [
            source(account: "a", container: "1", kind: .movie, provider: healthy),
            source(account: "b", container: "1", kind: .movie, provider: dead)
        ])

        let result = try await page(provider, start: 0, limit: 20)
        XCTAssertEqual(result.items.map(\.title), ["Alien", "Zodiac"])
    }

    func testTotalCountIsHonestWhenAServerIsUnreachable() async throws {
        // Deliberately NOT padded to hold a slot open for the unreachable server:
        // the grid marks a page loaded once served, so a padded total renders as a
        // permanently empty cell that can never ask again. An honest total costs
        // that server's titles until the screen is reopened, which is what the
        // single-library browse has always done.
        let healthy = FakeMediaProvider(allItems: [movie("h1", title: "Alien")])
        let dead = FakeMediaProvider(allItems: [movie("d1", title: "Zodiac")])
        dead.alwaysFail = true
        let provider = AggregatedLibraryProvider(sources: [
            source(account: "a", container: "1", kind: .movie, provider: healthy),
            source(account: "b", container: "1", kind: .movie, provider: dead)
        ])

        let result = try await page(provider, start: 0, limit: 20)
        XCTAssertEqual(result.items.map(\.title), ["Alien"])
        XCTAssertEqual(result.totalCount, 1, "no phantom slot for a server that isn't answering")
        XCTAssertFalse(result.hasMore)
    }

    func testChangingSortDiscardsEveryPageFetchedUnderTheOldOne() async throws {
        // `setSort` reloads from index 0 against the SAME provider instance, so the
        // aggregate has to throw away its buffers, offsets and running merge — or
        // the sort menu appears to do nothing.
        let a = FakeMediaProvider(allItems: [movie("a1", title: "Alien"), movie("a2", title: "Zodiac")])
        let provider = AggregatedLibraryProvider(sources: [
            source(account: "a", container: "1", kind: .movie, provider: a)
        ])

        let ascending = try await provider.items(
            in: AllLibrariesBrowse.containerID,
            kind: .unknown,
            page: PageRequest(startIndex: 0, limit: 20, sort: CoreModels.SortDescriptor(field: .name, direction: .ascending))
        )
        XCTAssertEqual(ascending.items.map(\.title), ["Alien", "Zodiac"])

        // The fake returns its fixed order regardless of sort, so a stale buffer
        // would answer from the OLD merge; a correct reset re-fetches.
        a.allItems = [movie("a2", title: "Zodiac"), movie("a1", title: "Alien")]
        let descending = try await provider.items(
            in: AllLibrariesBrowse.containerID,
            kind: .unknown,
            page: PageRequest(startIndex: 0, limit: 20, sort: CoreModels.SortDescriptor(field: .name, direction: .descending))
        )
        XCTAssertEqual(
            descending.items.map(\.title), ["Zodiac", "Alien"],
            "the new ordering was fetched fresh, not served from the old buffer"
        )
    }

    func testDeepPagingCoversEveryTitleExactlyOnceAndStaysSorted() async throws {
        let providers = (0..<4).map { index in
            FakeMediaProvider(allItems: (0..<25).map { offset in
                movie("s\(index)-\(offset)", title: String(format: "Title %03d", offset * 4 + index))
            })
        }
        let provider = AggregatedLibraryProvider(
            sources: providers.enumerated().map { index, fake in
                source(account: "a\(index)", container: "1", kind: .movie, provider: fake)
            }
        )

        var collected: [String] = []
        var start = 0
        while true {
            let result = try await page(provider, start: start, limit: 10)
            collected.append(contentsOf: result.items.map(\.title))
            if !result.hasMore { break }
            start += 10
            if start > 500 { XCTFail("paging did not terminate"); break }
        }

        XCTAssertEqual(collected.count, 100)
        XCTAssertEqual(Set(collected).count, 100, "no title surfaced twice")
        XCTAssertEqual(collected, collected.sorted(), "the whole grid stayed name-sorted across pages")
    }
}
