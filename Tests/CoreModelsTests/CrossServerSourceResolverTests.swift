import XCTest
@testable import CoreModels

/// Tests for ``CrossServerSourceResolver`` — the detail-page discovery that finds
/// a title's twins on the household's *other* servers and returns the unified
/// per-server picker sources.
///
/// The regression these guard is "Problem B": a title stored under a **different
/// name** on another server (localised title, edition/year annotation) must still
/// collapse into the picker because it shares a strong external id. Discovery goes
/// through free-text search, so the fix both (a) widens the query with a
/// normalized title and (b) matches the hits back by provider IDs.
final class CrossServerSourceResolverTests: XCTestCase {
    private let plexAccount = "acct-plex"
    private let jellyAccount = "acct-jelly"

    private func serverInfo(_ accountID: String) -> SourceServerInfo? {
        switch accountID {
        case plexAccount: return SourceServerInfo(providerKind: .plex, serverName: "Plex Home", accountName: "Alice")
        case jellyAccount: return SourceServerInfo(providerKind: .jellyfin, serverName: "Jellyfin Home", accountName: "Bob")
        default: return nil
        }
    }

    // MARK: searchQueries

    func testSearchQueriesAddNormalizedTitleWhenItDiffers() {
        let item = MediaItem(id: "x", title: "Spider-Man", kind: .movie, productionYear: 2002)
        XCTAssertEqual(
            CrossServerSourceResolver.searchQueries(for: item),
            ["Spider-Man", "spider man"],
            "Should also search the normalized title to widen recall for annotated/renamed copies"
        )
    }

    func testSearchQueriesDoesNotDuplicatePlainTitle() {
        let item = MediaItem(id: "x", title: "Dune", kind: .movie, productionYear: 2021)
        XCTAssertEqual(
            CrossServerSourceResolver.searchQueries(for: item),
            ["Dune"],
            "A title that normalizes to itself (case-insensitively) must not be searched twice"
        )
    }

    func testSearchQueriesEmptyForBlankTitle() {
        let item = MediaItem(id: "x", title: "   ", kind: .movie)
        XCTAssertTrue(CrossServerSourceResolver.searchQueries(for: item).isEmpty)
    }

    func testSearchQueriesIncludesOriginalTitle() {
        // The foreign-film case: Jellyfin shows the Spanish title, but records the
        // English original. The original must be one of the queries (most-specific
        // first, after the raw display title) so the English-titled copy on another
        // server is actually returned by search.
        let item = MediaItem(
            id: "x", title: "Turbulencia en la oficina",
            originalTitle: "Office Turbulence", kind: .movie, productionYear: 2018
        )
        XCTAssertEqual(
            CrossServerSourceResolver.searchQueries(for: item),
            ["Turbulencia en la oficina", "Office Turbulence"],
            "Raw display title plus the original title; case-only normalized variants are deduped away (servers search case-insensitively)"
        )
    }

    func testSearchQueriesDeduplicatesOriginalEqualToTitle() {
        // When originalTitle matches the display title there's nothing extra to add.
        let item = MediaItem(
            id: "x", title: "Dune", originalTitle: "Dune", kind: .movie, productionYear: 2021
        )
        XCTAssertEqual(
            CrossServerSourceResolver.searchQueries(for: item),
            ["Dune"],
            "An original title equal to the display title must not add duplicate queries"
        )
    }

    // MARK: resolve — differing titles, matched by provider IDs

    func testResolvesDifferentlyTitledMovieAcrossServersByProviderID() async {
        // User opened the Jellyfin movie "Amélie"; Plex stores the same film under
        // its French release title. They share a TMDb id, so the picker must list
        // both servers even though neither raw-title search would find the other.
        let primary = MediaItem(
            id: "jf-amelie", title: "Amélie", kind: .movie, productionYear: 2001,
            providerIDs: ["Tmdb": "194"], sourceAccountID: jellyAccount
        )
        // Plex only matches when searched by the *normalized* title token ("amelie").
        let plexCopy = MediaItem(
            id: "plex-amelie", title: "Le Fabuleux Destin d'Amélie Poulain",
            kind: .movie, productionYear: 2001, providerIDs: ["Tmdb": "194"]
        )

        let sources = await CrossServerSourceResolver.resolve(
            primary: primary,
            otherAccountIDs: [plexAccount],
            search: { accountID, query in
                guard accountID == self.plexAccount else { return [] }
                // Server stores the French title; only the normalized "amelie" hits.
                return query == "amelie" ? [plexCopy] : []
            },
            serverInfo: serverInfo
        )

        XCTAssertEqual(sources.count, 2, "Differently-titled same-TMDb movie must expose a 2-server picker")
        XCTAssertEqual(Set(sources.map(\.accountID)), [jellyAccount, plexAccount])
        XCTAssertEqual(sources.first?.accountID, jellyAccount, "Primary (opened) server leads the picker")
        XCTAssertEqual(sources.first?.providerKind, .jellyfin)
        XCTAssertEqual(sources.last?.providerKind, .plex)
        XCTAssertEqual(sources.map(\.itemID).sorted(), ["jf-amelie", "plex-amelie"])
    }

    func testResolvesSeriesAcrossServersDespiteDifferentTitles() async {
        // Series get NO title identity, so this can only work via the shared id —
        // exactly the provider-ID match the picker depends on.
        let primary = MediaItem(
            id: "plex-op", title: "One Piece", kind: .series, productionYear: 1999,
            providerIDs: ["Tvdb": "81797"], sourceAccountID: plexAccount
        )
        let jellyCopy = MediaItem(
            id: "jf-op", title: "ONE PIECE (Subtitled)", kind: .series, productionYear: 1999,
            providerIDs: ["Tvdb": "81797"]
        )

        let sources = await CrossServerSourceResolver.resolve(
            primary: primary,
            otherAccountIDs: [jellyAccount],
            search: { accountID, _ in accountID == self.jellyAccount ? [jellyCopy] : [] },
            serverInfo: serverInfo
        )

        XCTAssertEqual(sources.count, 2, "Same-Tvdb series on two servers must collapse into the picker")
        XCTAssertEqual(Set(sources.map(\.accountID)), [plexAccount, jellyAccount])
    }

    func testDoesNotAttachUnrelatedSameNameHit() async {
        // Widening the query must not attach a different title that merely shares a
        // name: no shared external id (and series have no title identity) ⇒ no merge.
        let primary = MediaItem(
            id: "plex-op", title: "One Piece", kind: .series, productionYear: 1999,
            providerIDs: ["Tvdb": "81797"], sourceAccountID: plexAccount
        )
        let unrelated = MediaItem(
            id: "jf-op-2023", title: "One Piece", kind: .series, productionYear: 2023,
            providerIDs: ["Tvdb": "452691"]  // live-action remake, different id
        )

        let sources = await CrossServerSourceResolver.resolve(
            primary: primary,
            otherAccountIDs: [jellyAccount],
            search: { accountID, _ in accountID == self.jellyAccount ? [unrelated] : [] },
            serverInfo: serverInfo
        )

        XCTAssertTrue(
            sources.count <= 1,
            "A same-name title with a different external id must never be folded into the picker"
        )
    }

    // MARK: resolve — foreign film discovered via original title

    func testResolvesForeignTitledMovieViaOriginalTitle() async {
        // Problem B's real case: the user opens the Jellyfin movie shown as the
        // Spanish "Turbulencia en la oficina"; Plex stores the same film under its
        // English title. No display-title search would ever cross the language gap —
        // only the *original title* query ("Office Turbulence") returns the Plex
        // copy, which then matches the primary by TMDb id and yields the picker.
        let primary = MediaItem(
            id: "jf-turb", title: "Turbulencia en la oficina",
            originalTitle: "Office Turbulence", kind: .movie, productionYear: 2018,
            providerIDs: ["Tmdb": "55555"], sourceAccountID: jellyAccount
        )
        let plexCopy = MediaItem(
            id: "plex-turb", title: "Office Turbulence", kind: .movie, productionYear: 2018,
            providerIDs: ["Tmdb": "55555"]
        )

        let sources = await CrossServerSourceResolver.resolve(
            primary: primary,
            otherAccountIDs: [plexAccount],
            search: { accountID, query in
                guard accountID == self.plexAccount else { return [] }
                // Plex only knows the English title — reachable solely by the
                // original-title query (raw or normalized form).
                return query.caseInsensitiveCompare("Office Turbulence") == .orderedSame
                    ? [plexCopy] : []
            },
            serverInfo: serverInfo
        )

        XCTAssertEqual(sources.count, 2, "Foreign-titled same-TMDb movie must expose a 2-server picker via its original title")
        XCTAssertEqual(Set(sources.map(\.accountID)), [jellyAccount, plexAccount])
        XCTAssertEqual(sources.first?.accountID, jellyAccount, "Primary (opened) server leads the picker")
        XCTAssertEqual(sources.map(\.itemID).sorted(), ["jf-turb", "plex-turb"])
    }

    func testReturnsEmptyWhenNoOtherServerHasIt() async {
        let primary = MediaItem(
            id: "jf-x", title: "Obscure Film", kind: .movie, productionYear: 2010,
            providerIDs: ["Tmdb": "999999"], sourceAccountID: jellyAccount
        )
        let sources = await CrossServerSourceResolver.resolve(
            primary: primary,
            otherAccountIDs: [plexAccount],
            search: { _, _ in [] },
            serverInfo: serverInfo
        )
        XCTAssertTrue(sources.isEmpty, "Nothing to merge ⇒ no picker (single-server title)")
    }

    func testDedupesRawAndNormalizedHitsWithinAnAccount() async {
        // When raw and normalized queries both return the same hit, the source list
        // must not double-count it.
        let primary = MediaItem(
            id: "jf-m", title: "WALL-E", kind: .movie, productionYear: 2008,
            providerIDs: ["Tmdb": "10681"], sourceAccountID: jellyAccount
        )
        let plexCopy = MediaItem(
            id: "plex-m", title: "WALL-E", kind: .movie, productionYear: 2008,
            providerIDs: ["Tmdb": "10681"]
        )

        let sources = await CrossServerSourceResolver.resolve(
            primary: primary,
            otherAccountIDs: [plexAccount],
            // Returns the hit for every query (raw "WALL-E" and normalized "wall e").
            search: { accountID, _ in accountID == self.plexAccount ? [plexCopy] : [] },
            serverInfo: serverInfo
        )

        XCTAssertEqual(sources.count, 2)
        XCTAssertEqual(sources.filter { $0.accountID == plexAccount }.count, 1,
                       "The same hit returned by both queries must collapse to one source")
    }
}
