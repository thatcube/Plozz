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

    // MARK: - Not in Your Library (Seerr discovery) section

    private func discovery(
        _ tmdb: Int,
        _ kind: MediaItemKind,
        availability: MediaAvailabilityStatus = .unknown
    ) -> MediaItem {
        MediaItem(
            id: "seer:\(tmdb)",
            title: "T\(tmdb)",
            kind: kind,
            providerIDs: ["Tmdb": String(tmdb)],
            availability: availability
        )
    }

    func testNotInLibrarySectionCollectsRequestableTitles() {
        let results = [discovery(1, .movie), discovery(2, .series)]
        let section = SearchSection.notInLibrarySection(discoveryResults: results, libraryResults: [])
        XCTAssertEqual(section?.title, "Not in Your Library")
        XCTAssertEqual(section?.items.map(\.id), ["seer:1", "seer:2"], "Seerr relevance order is preserved")
    }

    func testNotInLibrarySectionExcludesTitlesAlreadyInLibrary() {
        let results = [
            discovery(1, .movie, availability: .available),
            discovery(2, .movie, availability: .partiallyAvailable),
            discovery(3, .movie, availability: .unknown),
            discovery(4, .series, availability: .pending)
        ]
        let section = SearchSection.notInLibrarySection(discoveryResults: results, libraryResults: [])
        // available / partiallyAvailable are in the library already and are dropped;
        // unknown (requestable) and pending (already requested) remain.
        XCTAssertEqual(section?.items.map(\.id), ["seer:3", "seer:4"])
    }

    func testNotInLibrarySectionDropsTitlesTheLibrarySearchAlreadyReturned() {
        let libraryMovie = MediaItem(id: "j1", title: "Dune", kind: .movie, providerIDs: ["Tmdb": "100"])
        let results = [discovery(100, .movie), discovery(200, .movie)]
        let section = SearchSection.notInLibrarySection(discoveryResults: results, libraryResults: [libraryMovie])
        XCTAssertEqual(section?.items.map(\.id), ["seer:200"], "A TMDB match with a library hit is de-duped out")
    }

    func testNotInLibrarySectionCapsToLimit() {
        let results = (1...5).map { discovery($0, .movie) }
        let section = SearchSection.notInLibrarySection(discoveryResults: results, libraryResults: [], limit: 2)
        XCTAssertEqual(section?.items.count, 2)
    }

    func testNotInLibrarySectionNilWhenNothingRequestableRemains() {
        let allOwned = [discovery(1, .movie, availability: .available)]
        XCTAssertNil(SearchSection.notInLibrarySection(discoveryResults: allOwned, libraryResults: []))
        XCTAssertNil(SearchSection.notInLibrarySection(discoveryResults: [], libraryResults: []))
    }

    func testPartialDiscoveryStateMergesOntoPlayableSeriesWithoutDuplicate() {
        let library = MediaItem(
            id: "plex:1",
            title: "The Bear",
            kind: .series,
            providerIDs: ["Tmdb": "136315"]
        )
        let discoveryResult = discovery(136315, .series, availability: .partiallyAvailable)

        let merged = SearchSection.mergingDiscoveryAvailability(
            into: [library],
            discoveryResults: [discoveryResult],
            requestableSeriesTmdbIDs: ["136315"]
        )

        XCTAssertEqual(merged.first?.id, "plex:1")
        XCTAssertEqual(merged.first?.availability, .partiallyAvailable)
        XCTAssertEqual(SearchSection.availabilityCue(for: merged[0]), "More Seasons")
        XCTAssertNil(
            SearchSection.notInLibrarySection(
                discoveryResults: [discoveryResult],
                libraryResults: merged
            )
        )
    }

    func testAvailabilityCueDoesNotApplyToMoviesOrOrdinaryLibrarySeries() {
        XCTAssertNil(SearchSection.availabilityCue(for: discovery(1, .movie, availability: .partiallyAvailable)))
        XCTAssertNil(SearchSection.availabilityCue(for: MediaItem(id: "s", title: "Show", kind: .series)))
    }
}

@MainActor
final class SearchViewModelTests: XCTestCase {
    private func makeVM(_ providers: SearchStubProvider..., debounceMilliseconds: Int = 0) -> SearchViewModel {
        let accounts = providers.map { provider in
            ResolvedAccount(account: Account(id: provider.accountID, from: provider.session), provider: provider)
        }
        return SearchViewModel(accounts: accounts, debounceMilliseconds: debounceMilliseconds)
    }

    /// Builds a view model wired to a Seerr discovery search closure.
    private func makeVM(
        providers: [SearchStubProvider],
        seerSearch: @escaping @Sendable (String) async -> [MediaItem],
        seerRequestAvailability: @escaping @Sendable (MediaItem) async -> MediaRequestAvailability? = { _ in nil },
        debounceMilliseconds: Int = 0
    ) -> SearchViewModel {
        let accounts = providers.map { provider in
            ResolvedAccount(account: Account(id: provider.accountID, from: provider.session), provider: provider)
        }
        return SearchViewModel(
            accounts: accounts,
            debounceMilliseconds: debounceMilliseconds,
            seerSearch: seerSearch,
            seerRequestAvailability: seerRequestAvailability
        )
    }

    func testBlankQueryResetsToIdleWithoutSearching() async {
        let provider = SearchStubProvider(results: makeItems(3))
        let vm = makeVM(provider)
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
        let vm = makeVM(provider)
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
        let vm = makeVM(provider)
        vm.query = "zzz"

        await vm.search()

        if case .empty = vm.state {} else { XCTFail("Expected empty, got \(vm.state)") }
    }

    func testFailureSurfacesError() async {
        let provider = SearchStubProvider(results: [], error: .serverUnreachable)
        let vm = makeVM(provider)
        vm.query = "dune"

        await vm.search()

        if case .failed(.serverUnreachable) = vm.state {} else {
            XCTFail("Expected failed(.serverUnreachable), got \(vm.state)")
        }
    }

    func testMergesAndTagsResultsAcrossAccounts() async {
        let plex = SearchStubProvider(
            results: [MediaItem(id: "p1", title: "Dune", kind: .movie)],
            providerKind: .plex,
            accountID: "acct-plex"
        )
        let jellyfin = SearchStubProvider(
            results: [MediaItem(id: "j1", title: "Dune Part Two", kind: .movie)],
            providerKind: .jellyfin,
            accountID: "acct-jelly"
        )
        let vm = makeVM(plex, jellyfin)
        vm.query = "dune"

        await vm.search()

        guard case let .loaded(sections) = vm.state else {
            return XCTFail("Expected loaded, got \(vm.state)")
        }
        let movies = sections.first { $0.title == "Movies" }
        XCTAssertEqual(movies?.items.map(\.id), ["p1", "j1"], "Round-robin interleave keeps account order")
        XCTAssertEqual(movies?.items.first?.sourceAccountID, "acct-plex")
        XCTAssertEqual(movies?.items.last?.sourceAccountID, "acct-jelly")
    }

    func testOneAccountDownStillReturnsTheOtherResults() async {
        let down = SearchStubProvider(results: [], error: .serverUnreachable, accountID: "acct-down")
        let up = SearchStubProvider(
            results: [MediaItem(id: "m1", title: "Dune", kind: .movie)],
            accountID: "acct-up"
        )
        let vm = makeVM(down, up)
        vm.query = "dune"

        await vm.search()

        guard case let .loaded(sections) = vm.state else {
            return XCTFail("Expected loaded despite one account failing, got \(vm.state)")
        }
        XCTAssertEqual(sections.first { $0.title == "Movies" }?.items.map(\.id), ["m1"])
    }

    // MARK: - Seerr "Not in Your Library" section

    func testDiscoveryResultsAppendNotInLibrarySection() async {
        let provider = SearchStubProvider(results: [MediaItem(id: "m1", title: "Dune", kind: .movie)])
        let vm = makeVM(providers: [provider], seerSearch: { _ in
            [discoveryItem(1, "Foundation", .series)]
        })
        vm.query = "d"

        await vm.search()

        guard case let .loaded(sections) = vm.state else {
            return XCTFail("Expected loaded, got \(vm.state)")
        }
        XCTAssertEqual(sections.map(\.title), ["Movies", "Not in Your Library"],
                       "Discovery hits form a trailing section after the library sections")
        XCTAssertEqual(sections.last?.items.map(\.id), ["seer:1"])
    }

    func testAvailableDiscoveryTitlesAreNotShownAsNotInLibrary() async {
        let provider = SearchStubProvider(results: [MediaItem(id: "m1", title: "Dune", kind: .movie)])
        let vm = makeVM(providers: [provider], seerSearch: { _ in
            [discoveryItem(1, "Owned", .movie, availability: .available),
             discoveryItem(2, "Wanted", .movie, availability: .unknown)]
        })
        vm.query = "d"

        await vm.search()

        guard case let .loaded(sections) = vm.state else {
            return XCTFail("Expected loaded, got \(vm.state)")
        }
        XCTAssertEqual(sections.last?.title, "Not in Your Library")
        XCTAssertEqual(sections.last?.items.map(\.id), ["seer:2"], "An already-available title isn't listed")
    }

    func testPartialDiscoveryTitleAnnotatesMatchingLibrarySeriesInPlace() async {
        let library = MediaItem(
            id: "library-show",
            title: "The Bear",
            kind: .series,
            providerIDs: ["Tmdb": "136315"]
        )
        let provider = SearchStubProvider(results: [library])
        let vm = makeVM(
            providers: [provider],
            seerSearch: { _ in
                [discoveryItem(136315, "The Bear", .series, availability: .partiallyAvailable)]
            },
            seerRequestAvailability: { _ in
                MediaRequestAvailability(
                    status: .partiallyAvailable,
                    seasons: [
                        MediaSeasonRequestState(number: 1, title: "Season 1", status: .available),
                        MediaSeasonRequestState(number: 2, title: "Season 2", status: .unknown)
                    ]
                )
            }
        )
        vm.query = "bear"

        await vm.search()

        guard case let .loaded(sections) = vm.state else {
            return XCTFail("Expected loaded, got \(vm.state)")
        }
        XCTAssertEqual(sections.map(\.title), ["TV Shows"])
        XCTAssertEqual(sections[0].items[0].id, "library-show")
        XCTAssertEqual(sections[0].items[0].availability, .partiallyAvailable)
    }

    func testPartialDiscoveryTitleDoesNotAnnotateWhenNoSeasonIsRequestable() async {
        let library = MediaItem(
            id: "library-show",
            title: "The Bear",
            kind: .series,
            providerIDs: ["Tmdb": "136315"]
        )
        let provider = SearchStubProvider(results: [library])
        let vm = makeVM(
            providers: [provider],
            seerSearch: { _ in
                [discoveryItem(136315, "The Bear", .series, availability: .partiallyAvailable)]
            },
            seerRequestAvailability: { _ in
                MediaRequestAvailability(
                    status: .partiallyAvailable,
                    seasons: [
                        MediaSeasonRequestState(number: 1, title: "Season 1", status: .partiallyAvailable)
                    ]
                )
            }
        )
        vm.query = "bear"

        await vm.search()

        guard case let .loaded(sections) = vm.state else {
            return XCTFail("Expected loaded, got \(vm.state)")
        }
        XCTAssertNil(sections[0].items[0].availability)
    }

    func testLibraryDownButDiscoveryStillShows() async {
        let down = SearchStubProvider(results: [], error: .serverUnreachable)
        let vm = makeVM(providers: [down], seerSearch: { _ in
            [discoveryItem(9, "Severance", .series)]
        })
        vm.query = "sev"

        await vm.search()

        guard case let .loaded(sections) = vm.state else {
            return XCTFail("Expected loaded (discovery survives a library outage), got \(vm.state)")
        }
        XCTAssertEqual(sections.map(\.title), ["Not in Your Library"])
    }

    func testDiscoveryOnlyResultsLoadWithNoLibraryAccounts() async {
        let vm = SearchViewModel(accounts: [], debounceMilliseconds: 0, seerSearch: { _ in
            [discoveryItem(5, "Andor", .series, availability: .pending)]
        })
        vm.query = "andor"

        await vm.search()

        guard case let .loaded(sections) = vm.state else {
            return XCTFail("Expected loaded, got \(vm.state)")
        }
        XCTAssertEqual(sections.map(\.title), ["Not in Your Library"])
    }
}

/// Minimal `MediaProvider` stub that only implements `search`.
private final class SearchStubProvider: MediaProvider, @unchecked Sendable {
    let kind: ProviderKind
    let session: UserSession
    /// The app account id this stub stands in for; the test pins it as the
    /// `Account.id` so source-tagging assertions are deterministic.
    let accountID: String
    private let results: [MediaItem]
    private let error: AppError?
    private(set) var callCount = 0
    private(set) var lastQuery: String?

    init(
        results: [MediaItem],
        error: AppError? = nil,
        providerKind: ProviderKind = .jellyfin,
        accountID: String = "acct-1"
    ) {
        self.kind = providerKind
        self.accountID = accountID
        self.results = results
        self.error = error
        self.session = UserSession(
            server: MediaServer(id: "s-\(accountID)", name: "Home", baseURL: URL(string: "http://host:8096")!, provider: providerKind),
            userID: "u-\(accountID)", userName: "Alice", deviceID: "d-\(accountID)", accessToken: "TOKEN"
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

/// A Seerr discovery `MediaItem` (synthetic `seer:<tmdb>` id + TMDB provider id +
/// an availability status), mirroring what `SeerMapper` produces. File-scope so it
/// stays nonisolated and is usable inside `@Sendable` search closures.
private func discoveryItem(_ tmdb: Int, _ title: String, _ kind: MediaItemKind, availability: MediaAvailabilityStatus = .unknown) -> MediaItem {
    MediaItem(id: "seer:\(tmdb)", title: title, kind: kind, providerIDs: ["Tmdb": String(tmdb)], availability: availability)
}

final class SearchDeduplicatorTests: XCTestCase {
    private func movie(
        _ id: String,
        title: String,
        year: Int? = nil,
        account: String,
        providerIDs: [String: String] = [:]
    ) -> MediaItem {
        MediaItem(
            id: id,
            title: title,
            kind: .movie,
            productionYear: year,
            providerIDs: providerIDs,
            sourceAccountID: account
        )
    }

    private func series(
        _ id: String,
        title: String,
        year: Int? = nil,
        account: String,
        providerIDs: [String: String] = [:]
    ) -> MediaItem {
        MediaItem(
            id: id,
            title: title,
            kind: .series,
            productionYear: year,
            providerIDs: providerIDs,
            sourceAccountID: account
        )
    }

    func testCollapsesSameTitleAcrossServersIntoOneCard() {
        // The exact same movie on a Plex account and a Jellyfin account.
        let plex = movie("p1", title: "Dune", year: 2021, account: "acct-plex")
        let jellyfin = movie("j1", title: "Dune", year: 2021, account: "acct-jelly")

        let merged = SearchDeduplicator.deduplicate([plex, jellyfin])

        XCTAssertEqual(merged.count, 1, "Same title/year/kind on two servers must show once")
        let card = merged[0]
        XCTAssertEqual(card.id, "p1", "First occurrence stays primary")
        XCTAssertEqual(card.sourceAccountID, "acct-plex")
        XCTAssertEqual(card.additionalSourceAccountIDs, ["acct-jelly"], "Alternate server retained for playback")
        XCTAssertEqual(card.allSourceAccountIDs, ["acct-plex", "acct-jelly"])
    }

    func testDoesNotMergeDifferentYears() {
        let original = movie("a", title: "Dune", year: 1984, account: "acct-1")
        let remake = movie("b", title: "Dune", year: 2021, account: "acct-2")

        let merged = SearchDeduplicator.deduplicate([original, remake])

        XCTAssertEqual(merged.map(\.id), ["a", "b"], "A reboot with a different year is a different title")
    }

    func testDoesNotMergeSameTitleWhenYearIsNilAndNoExternalIDs() {
        // Series with the same name and no external IDs must never be collapsed —
        // without an external ID there is no safe way to know they're the same show.
        let anime = series("anime", title: "One Piece", account: "acct-jellyfin")
        let liveAction = series("live", title: "One Piece", account: "acct-plex")

        let merged = SearchDeduplicator.deduplicate([anime, liveAction])

        XCTAssertEqual(merged.map(\.id), ["anime", "live"],
                       "Series without external IDs must never be collapsed by title identity")
    }

    func testDoesNotMergeSeriesWithSameYearButDifferentExternalIDs() {
        // The One Piece scenario: bad metadata gives the live action year=1999
        // (matching the anime's real start year). Both are series — title identity
        // must not be emitted for series at all, so different TMDb IDs keep them apart.
        let liveAction = series("live", title: "One Piece", year: 1999, account: "acct-plex",
                                providerIDs: ["Tmdb": "392768"])  // bad year
        let anime = series("anime", title: "One Piece", year: 1999, account: "acct-jf",
                           providerIDs: ["Tmdb": "37854"])

        let merged = SearchDeduplicator.deduplicate([liveAction, anime])

        XCTAssertEqual(merged.map(\.id), ["live", "anime"],
                       "Series with different external IDs must never be merged even when title+year match")
    }

    func testMergesSeriesWithSameExternalIDAcrossServers() {
        // The same show on Plex and Jellyfin — different internal IDs but shared TMDb.
        let plex = series("p1", title: "One Piece", year: 1999, account: "acct-plex",
                          providerIDs: ["Tmdb": "37854"])
        let jellyfin = series("j1", title: "One Piece", year: 1999, account: "acct-jf",
                              providerIDs: ["Tmdb": "37854"])

        let merged = SearchDeduplicator.deduplicate([plex, jellyfin])

        XCTAssertEqual(merged.count, 1, "Same show on two servers (matched by TMDb) must collapse to one card")
        XCTAssertEqual(merged[0].additionalSourceAccountIDs, ["acct-jf"])
    }

    func testMergesOnSharedExternalIDDespiteTitleDifferences() {
        // Different display titles / years but the same IMDb id ⇒ same film.
        let plex = movie("p1", title: "Spider-Man", account: "acct-plex", providerIDs: ["Imdb": "tt0145487"])
        let jellyfin = movie(
            "j1",
            title: "Spider Man",
            year: 2002,
            account: "acct-jelly",
            providerIDs: ["Imdb": "tt0145487", "Tmdb": "557"]
        )

        let merged = SearchDeduplicator.deduplicate([plex, jellyfin])

        XCTAssertEqual(merged.count, 1)
        let card = merged[0]
        XCTAssertEqual(card.id, "p1")
        XCTAssertEqual(card.additionalSourceAccountIDs, ["acct-jelly"])
        XCTAssertEqual(card.providerIDs["Imdb"], "tt0145487")
        XCTAssertEqual(card.providerIDs["Tmdb"], "557", "External ids are unioned across sources")
    }

    func testTransitiveMergeAcrossThreeServers() {
        // a↔b share an IMDb id ⇒ merged. c shares the same IMDb id too ⇒ all three collapse.
        // (Under the new rules, title identity is suppressed when external IDs are present,
        // so the bridge must come from a shared external ID, not title+year.)
        let a = movie("a", title: "The Matrix", account: "acct-a", providerIDs: ["Imdb": "tt0133093"])
        let b = movie("b", title: "The Matrix", year: 1999, account: "acct-b", providerIDs: ["Imdb": "tt0133093"])
        let c = movie("c", title: "the  matrix", year: 1999, account: "acct-c", providerIDs: ["Imdb": "tt0133093"])

        let merged = SearchDeduplicator.deduplicate([a, b, c])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].id, "a")
        XCTAssertEqual(merged[0].additionalSourceAccountIDs, ["acct-b", "acct-c"])
    }


    func testNormalizationIgnoresPunctuationDiacriticsAndCase() {
        let plex = movie("p1", title: "Amélie", year: 2001, account: "acct-plex")
        let jellyfin = movie("j1", title: "amelie", year: 2001, account: "acct-jelly")

        let merged = SearchDeduplicator.deduplicate([plex, jellyfin])

        XCTAssertEqual(merged.count, 1, "Accents and case must not split a duplicate")
    }

    func testPreservesOrderAndLeavesUniqueItemsUntouched() {
        let items = [
            movie("m1", title: "Dune", year: 2021, account: "acct-plex"),
            movie("m2", title: "Arrival", year: 2016, account: "acct-plex"),
            movie("m3", title: "Dune", year: 2021, account: "acct-jelly")
        ]

        let merged = SearchDeduplicator.deduplicate(items)

        XCTAssertEqual(merged.map(\.id), ["m1", "m2"], "Relevance order preserved, duplicate folded into primary")
        XCTAssertEqual(merged[0].additionalSourceAccountIDs, ["acct-jelly"])
        XCTAssertTrue(merged[1].additionalSourceAccountIDs.isEmpty, "Unique item is unchanged")
    }
}

@MainActor
final class SearchViewModelDedupTests: XCTestCase {
    func testSameMovieOnTwoServersShowsSingleCard() async {
        let shared = MediaItem(id: "shared", title: "Blade Runner 2049", kind: .movie, productionYear: 2017)
        let plex = SearchStubProvider(results: [shared], providerKind: .plex, accountID: "acct-plex")
        let jellyfin = SearchStubProvider(results: [shared], providerKind: .jellyfin, accountID: "acct-jelly")
        let accounts = [plex, jellyfin].map {
            ResolvedAccount(account: Account(id: $0.accountID, from: $0.session), provider: $0)
        }
        let vm = SearchViewModel(accounts: accounts, debounceMilliseconds: 0)
        vm.query = "blade"

        await vm.search()

        guard case let .loaded(sections) = vm.state else {
            return XCTFail("Expected loaded, got \(vm.state)")
        }
        let movies = sections.first { $0.title == "Movies" }
        XCTAssertEqual(movies?.items.count, 1, "Duplicate across providers collapses to one card")
        XCTAssertEqual(movies?.items.first?.allSourceAccountIDs, ["acct-plex", "acct-jelly"])
    }

    func testSeriesWithSharedExternalIDShowsOneCardAndTwoSources() async {
        // The SAME series hosted on both a Plex and a Jellyfin server: it shares a
        // strong external id (Tmdb 37854 — the One Piece anime) AND the same debut
        // year, because two copies of one show report the same production year.
        // That pair must collapse to one card carrying both sources for the server
        // picker. (A large production-year gap here — e.g. the 1999 anime vs the
        // 2023 live-action sharing one mis-scraped id — is a *different* scenario
        // the merge split-guard deliberately keeps as two cards; see
        // CrossServerMergeEdgeTests. Keep both years equal so this test exercises
        // the genuine same-show twin, not that false-merge case.)
        let plexSeries = MediaItem(
            id: "plex-one-piece",
            title: "One Piece",
            kind: .series,
            productionYear: 1999,
            providerIDs: ["Tmdb": "37854"]
        )
        let jellySeries = MediaItem(
            id: "jelly-one-piece",
            title: "One Piece",
            kind: .series,
            productionYear: 1999,
            providerIDs: ["Tmdb": "37854"]
        )
        let plex = SearchStubProvider(results: [plexSeries], providerKind: .plex, accountID: "acct-plex")
        let jellyfin = SearchStubProvider(results: [jellySeries], providerKind: .jellyfin, accountID: "acct-jelly")
        let accounts = [plex, jellyfin].map {
            ResolvedAccount(account: Account(id: $0.accountID, from: $0.session), provider: $0)
        }
        let vm = SearchViewModel(accounts: accounts, debounceMilliseconds: 0)
        vm.query = "one piece"

        await vm.search()

        guard case let .loaded(sections) = vm.state else {
            return XCTFail("Expected loaded, got \(vm.state)")
        }
        let shows = sections.first { $0.title == "TV Shows" }
        XCTAssertEqual(shows?.items.count, 1)
        XCTAssertEqual(shows?.items.first?.sources.count, 2, "Merged hit keeps both sources for the server picker")
        XCTAssertEqual(shows?.items.first?.allSourceAccountIDs, ["acct-plex", "acct-jelly"])
    }
}
