import XCTest
@testable import CoreModels

/// Round-2 edge-case coverage for the shared cross-server merge core, on top of
/// `CrossServerIdentityTests`: mixed movie/episode safety, partial/garbage
/// metadata, the same external id carrying *different editions*, and conflicting
/// progress reconciliation. These pin down the harder corners of criteria 1, 4
/// and 5 so the one shared component behaves identically for Home, Library browse
/// and Search.
final class CrossServerMergeEdgeTests: XCTestCase {

    private func item(
        _ id: String,
        title: String,
        kind: MediaItemKind,
        year: Int? = nil,
        account: String,
        ids: [String: String] = [:],
        versions: [MediaVersion] = [],
        resume: TimeInterval? = nil,
        played: Bool = false,
        lastPlayed: Date? = nil
    ) -> MediaItem {
        MediaItem(
            id: id,
            title: title,
            kind: kind,
            productionYear: year,
            resumePosition: resume,
            isPlayed: played,
            providerIDs: ids,
            sourceAccountID: account,
            versions: versions,
            lastPlayedAt: lastPlayed
        )
    }

    // MARK: Mixed movie / episode safety (criterion 6)

    func testMovieAndEpisodeWithSameTitleAndYearDoNotMerge() {
        // A film called "Heat" and an episode happening to be titled "Heat" must
        // never collapse: only movies get a title identity, so the episode (which
        // carries no external id here) stays separate.
        let film = item("m", title: "Heat", kind: .movie, year: 1995, account: "plex")
        let episode = item("e", title: "Heat", kind: .episode, year: 1995, account: "jelly")
        let merged = MediaItemMerger.merge([film, episode])
        XCTAssertEqual(Set(merged.map(\.id)), ["m", "e"])
        XCTAssertTrue(merged.allSatisfy { $0.sources.isEmpty })
    }

    func testEpisodesWithSameExternalIDMergeAcrossServers() {
        // Two servers' copy of the *same* episode (shared external id) is a real
        // duplicate and must merge — external identity is kind-agnostic.
        let a = item("a", title: "Ozymandias", kind: .episode, account: "plex", ids: ["Tvdb": "4877506"])
        let b = item("b", title: "Ozymandias", kind: .episode, account: "jelly", ids: ["Tvdb": "4877506"])
        let merged = MediaItemMerger.merge([a, b])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].sources.map(\.accountID), ["plex", "jelly"])
    }

    // MARK: Partial / garbage metadata (criterion 6)

    func testMovieMissingYearDoesNotMergeWithYearedTwin() {
        // One server omits the production year → it has no title identity, so the
        // conservative rule keeps them apart rather than risk a wrong collapse.
        let yeared = item("a", title: "Dune", kind: .movie, year: 2021, account: "plex")
        let noYear = item("b", title: "Dune", kind: .movie, year: nil, account: "jelly")
        XCTAssertEqual(MediaItemMerger.merge([yeared, noYear]).count, 2)
    }

    func testWhitespaceOnlyExternalIDIsIgnored() {
        // A blank/whitespace external id must not create a bogus shared identity
        // (which would merge two unrelated titles that both have empty ids).
        let a = item("a", title: "A Film", kind: .movie, year: 2000, account: "plex", ids: ["Tmdb": "   "])
        let b = item("b", title: "B Film", kind: .movie, year: 2001, account: "jelly", ids: ["Tmdb": ""])
        let merged = MediaItemMerger.merge([a, b])
        XCTAssertEqual(merged.count, 2, "Blank ids fall back to title identity, which differs here")
        XCTAssertTrue(MediaItemIdentity.identities(for: a).allSatisfy {
            if case .external = $0 { return false }
            return true
        }, "A whitespace external id yields no external identity")
    }

    func testCaseInsensitiveExternalIDsMerge() {
        // Provider id keys/values differ only by case across servers; they must
        // still be recognised as the same catalogue entry.
        let a = item("a", title: "Dune", kind: .movie, year: 2021, account: "plex", ids: ["TMDB": "438631"])
        let b = item("b", title: "Dune", kind: .movie, year: 2021, account: "jelly", ids: ["tmdb": "438631"])
        XCTAssertEqual(MediaItemMerger.merge([a, b]).count, 1)
    }

    // MARK: Same external id, different edition (criterion 4 × 1)

    func testSameExternalIDDifferentEditionMergesButKeepsBothEditions() {
        // The Extended cut lives on one server, the Theatrical on another — same
        // film (same Tmdb), so ONE card, but each source keeps its own edition so
        // the version/edition picker can still distinguish them.
        let extended = MediaVersion(id: "ext", name: "Dune (2021) Extended BluRay-2160p", height: 2160)
        let theatrical = MediaVersion(id: "thr", name: "Dune (2021) Theatrical BluRay-2160p", height: 2160)
        let plex = item("p", title: "Dune", kind: .movie, year: 2021, account: "plex",
                        ids: ["Tmdb": "438631"], versions: [extended])
        let jelly = item("j", title: "Dune", kind: .movie, year: 2021, account: "jelly",
                         ids: ["Tmdb": "438631"], versions: [theatrical])

        let merged = MediaItemMerger.merge([plex, jelly])
        XCTAssertEqual(merged.count, 1)
        let card = merged[0]
        XCTAssertEqual(card.sources.count, 2)
        XCTAssertEqual(card.sources[0].versions.first?.editionLabel, "Extended")
        XCTAssertEqual(card.sources[1].versions.first?.editionLabel, "Theatrical")
    }

    // MARK: Conflicting progress reconciliation (criterion 5)

    func testConflictingProgressEqualTimestampsResolvesDeterministically() {
        // Same lastPlayedAt on two servers with different resume points: the fold
        // must be deterministic (stable across repeated calls), never a crash or
        // flip-flop.
        let when = Date(timeIntervalSince1970: 1_000)
        let a = MediaSourceRef(accountID: "a", itemID: "a1", resumePosition: 120, lastPlayedAt: when)
        let b = MediaSourceRef(accountID: "b", itemID: "b1", resumePosition: 600, lastPlayedAt: when)
        let first = MediaItemMerger.unifiedWatchState(from: [a, b])
        let second = MediaItemMerger.unifiedWatchState(from: [a, b])
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.lastPlayedAt, when)
        XCTAssertTrue([120.0, 600.0].contains(first.resumePosition ?? -1))
    }

    func testNewerProgressOnAlternateBeatsOlderProgressOnPrimary() {
        // Primary watched 1 min long ago; alternate watched 30 min recently. The
        // merged card surfaces the alternate's fresher resume (criterion 5).
        let primary = item("p", title: "Dune", kind: .movie, year: 2021, account: "plex",
                           ids: ["Tmdb": "1"], resume: 60, lastPlayed: Date(timeIntervalSince1970: 10))
        let alternate = item("j", title: "Dune", kind: .movie, year: 2021, account: "jelly",
                             ids: ["Tmdb": "1"], resume: 1_800, lastPlayed: Date(timeIntervalSince1970: 5_000))
        let card = MediaItemMerger.merge([primary, alternate])[0]
        XCTAssertEqual(card.id, "p", "Primary identity is preserved")
        XCTAssertEqual(card.resumePosition, 1_800, "Unified progress reflects the newer alternate play")
        XCTAssertEqual(card.lastPlayedAt, Date(timeIntervalSince1970: 5_000))
    }

    func testMarkWatchedOnAnyServerFoldsToWatchedWhenNewest() {
        // Finished on the alternate most recently → merged card reads watched and
        // drops the stale resume from the older primary.
        let primary = item("p", title: "Dune", kind: .movie, year: 2021, account: "plex",
                           ids: ["Tmdb": "1"], resume: 300, lastPlayed: Date(timeIntervalSince1970: 10))
        let alternate = item("j", title: "Dune", kind: .movie, year: 2021, account: "jelly",
                             ids: ["Tmdb": "1"], played: true, lastPlayed: Date(timeIntervalSince1970: 9_000))
        let card = MediaItemMerger.merge([primary, alternate])[0]
        XCTAssertTrue(card.isPlayed)
        XCTAssertNil(card.resumePosition)
    }

    // MARK: Order / determinism

    func testInterleavedMixOnlyMergesTrueDuplicates() {
        // A realistic interleaved row: two real duplicates plus unique singletons.
        // Exactly the duplicates collapse; everything else and the order survive.
        let dunePlex = item("dp", title: "Dune", kind: .movie, year: 2021, account: "plex", ids: ["Tmdb": "1"])
        let arrival = item("ar", title: "Arrival", kind: .movie, year: 2016, account: "plex", ids: ["Tmdb": "2"])
        let duneJelly = item("dj", title: "Dune", kind: .movie, year: 2021, account: "jelly", ids: ["Tmdb": "1"])
        let show = item("sh", title: "Severance", kind: .series, account: "jelly", ids: ["Tvdb": "9"])

        let merged = MediaItemMerger.merge([dunePlex, arrival, duneJelly, show])
        XCTAssertEqual(merged.map(\.id), ["dp", "ar", "sh"], "First-seen order preserved; only Dune collapses")
        XCTAssertEqual(merged[0].sources.map(\.accountID), ["plex", "jelly"])
    }

    // MARK: ID-less row recovery via the identity index (criterion 2/4)

    /// A Jellyfin twin carrying an IMDb id and a Plex row whose list payload
    /// omitted its `Guid` array share no identity key — rule #1 suppresses the
    /// Jellyfin row's title key — so the pure identity passes leave them as two
    /// cards. When the eager index (enriched by per-item fetch during warm) knows
    /// both belong to one title, `identitySources` must recover the id-less row and
    /// collapse them. This is the r3-idless-no-merge regression.
    func testIdlessRowMergesWithExternalTwinViaIndexMembership() {
        let jelly = item("j1", title: "The Matrix", kind: .movie, year: 1999, account: "jelly", ids: ["Imdb": "tt0133093"])
        // Plex row: correct kind/title but NO external id and no year, so it has no
        // identity key at all on its own.
        let plex = item("p1", title: "The Matrix", kind: .movie, account: "plex")

        let snapshot = IdentityIndexSnapshot(byIdentity: [
            .external(source: "imdb", value: "tt0133093"): [
                IndexedSource(accountID: "jelly", itemID: "j1", kind: .movie),
                IndexedSource(accountID: "plex", itemID: "p1", kind: .movie)
            ]
        ])
        let merged = MediaItemMerger.merge(
            [jelly, plex],
            identitySources: { snapshot.sourceRefs(for: $0) }
        )
        XCTAssertEqual(merged.count, 1, "The index knows both are one title, so the id-less row must collapse into the twin")
        XCTAssertEqual(Set(merged[0].sources.map(\.accountID)), ["jelly", "plex"])
    }

    /// The recovery is index-driven, never a title guess: an id-less row the index
    /// does NOT know stays a separate card even next to a same-title twin, so a
    /// cold/unknown index can never manufacture a false cross-server merge.
    func testIdlessRowStaysSeparateWhenIndexDoesNotKnowIt() {
        let jelly = item("j1", title: "The Matrix", kind: .movie, year: 1999, account: "jelly", ids: ["Imdb": "tt0133093"])
        let plex = item("p1", title: "The Matrix", kind: .movie, account: "plex")

        // Index knows only the Jellyfin copy — nothing ties the id-less Plex row in.
        let snapshot = IdentityIndexSnapshot(byIdentity: [
            .external(source: "imdb", value: "tt0133093"): [
                IndexedSource(accountID: "jelly", itemID: "j1", kind: .movie)
            ]
        ])
        let merged = MediaItemMerger.merge(
            [jelly, plex],
            identitySources: { snapshot.sourceRefs(for: $0) }
        )
        XCTAssertEqual(merged.count, 2, "No index knowledge of the id-less row ⇒ no guess-merge")
    }
}
