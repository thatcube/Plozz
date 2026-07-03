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

    // MARK: Split-guard: contradicting external-id false merge (Scream 6/7)

    func testDifferentMoviesSharingBadExternalIDAreSplit() {
        // Scream 7 (unreleased, sparsely scraped) is mis-tagged on one server with
        // Scream 6's TMDb id. The shared id would otherwise collapse them into one
        // card; the split-guard keeps them as two, since titles disagree AND the
        // years don't corroborate.
        let scream6 = item("s6", title: "Scream 6", kind: .movie, year: 2023, account: "plex", ids: ["Tmdb": "934433"])
        let scream7 = item("s7", title: "Scream 7", kind: .movie, year: 2026, account: "jelly", ids: ["Tmdb": "934433"])
        let merged = MediaItemMerger.merge([scream6, scream7])
        XCTAssertEqual(merged.count, 2, "Two distinct films must not collapse via a single bad shared id")
        XCTAssertEqual(Set(merged.map(\.id)), ["s6", "s7"])
        XCTAssertTrue(merged.allSatisfy { $0.sources.isEmpty }, "Neither should absorb the other as a version")
    }

    func testContradictingMovieSplitEvenWhenImpostorIsPrimary() {
        // Two legit copies of Scream 6 (real twins) plus a mis-tagged Scream 7, with
        // the impostor listed first. The two Scream 6 copies still merge together and
        // Scream 7 is ejected into its own card.
        let scream7 = item("s7", title: "Scream 7", kind: .movie, year: 2026, account: "a", ids: ["Tmdb": "934433"])
        let scream6a = item("s6a", title: "Scream 6", kind: .movie, year: 2023, account: "b", ids: ["Tmdb": "934433"])
        let scream6b = item("s6b", title: "Scream 6", kind: .movie, year: 2023, account: "c", ids: ["Tmdb": "934433"])
        let merged = MediaItemMerger.merge([scream7, scream6a, scream6b])
        XCTAssertEqual(merged.count, 2)
        let byIsScream7 = Dictionary(grouping: merged) { $0.title == "Scream 7" }
        XCTAssertEqual(byIsScream7[true]?.first?.sources.isEmpty, true, "Scream 7 stands alone")
        let scream6Card = byIsScream7[false]?.first
        XCTAssertEqual(scream6Card?.sources.map(\.accountID).sorted(), ["b", "c"], "Both real Scream 6 copies merge")
    }

    func testMatchingYearRescuesSharedIDDespiteDifferentTitles() {
        // Localized title on one server ("Panico") vs "Scream", same TMDb, SAME year.
        // A corroborating year means the shared id is trusted — they stay merged.
        let a = item("a", title: "Scream", kind: .movie, year: 2022, account: "plex", ids: ["Tmdb": "646385"])
        let b = item("b", title: "Panico", kind: .movie, year: 2022, account: "jelly", ids: ["Tmdb": "646385"])
        XCTAssertEqual(MediaItemMerger.merge([a, b]).count, 1, "A matching year rescues a shared id even when titles differ")
    }

    func testTitleSubtitleVariantStaysMerged() {
        // "Dune" vs "Dune: Part Two" is a prefix at a word boundary — not a clash —
        // so an intentional shared id (or same year) keeps them together.
        let a = item("a", title: "Dune", kind: .movie, year: 2021, account: "plex", ids: ["Tmdb": "438631"])
        let b = item("b", title: "Dune Part Two", kind: .movie, year: 2021, account: "jelly", ids: ["Tmdb": "438631"])
        XCTAssertEqual(MediaItemMerger.merge([a, b]).count, 1)
    }

    func testSparseMetadataTwinIsNotSplit() {
        // An id-less / yearless row recovered as a twin carries no positive
        // contradiction, so it must NOT be ejected — protects membership-recovery
        // merges. Here both share a TMDb id; one has no year and a bare title.
        let full = item("a", title: "The Batman", kind: .movie, year: 2022, account: "plex", ids: ["Tmdb": "414906"])
        let sparse = item("b", title: "The Batman", kind: .movie, year: nil, account: "jelly", ids: ["Tmdb": "414906"])
        XCTAssertEqual(MediaItemMerger.merge([full, sparse]).count, 1, "A sparse-metadata twin is not split")
    }

    func testBaseTitleVsNumberedSequelSharingBadIDSplitsOnYearConflict() {
        // The original "Scream" (1996) mis-tagged with "Scream 6"'s (2023) id.
        // "scream" is a word-boundary prefix of "scream 6", so a naive prefix
        // allowance would keep them merged — but the 27-year gap is a hard year
        // conflict, so they must split.
        let original = item("a", title: "Scream", kind: .movie, year: 1996, account: "plex", ids: ["Tmdb": "934433"])
        let sixth = item("b", title: "Scream 6", kind: .movie, year: 2023, account: "jelly", ids: ["Tmdb": "934433"])
        XCTAssertEqual(MediaItemMerger.merge([original, sixth]).count, 2, "A base title and its numbered sequel with a hard year conflict must not merge")
    }

    func testIdenticalTitleNeverSplitsEvenWithYearGap() {
        // Deliberately conservative: two rows with the *identical* title sharing an
        // id are never split on a year gap alone (a same-title remake sharing a bad
        // id is far rarer than a single film whose year merely slips between
        // servers, and a false split shows the user duplicate cards).
        let a = item("a", title: "Halloween", kind: .movie, year: 1978, account: "plex", ids: ["Tmdb": "948"])
        let b = item("b", title: "Halloween", kind: .movie, year: 2018, account: "jelly", ids: ["Tmdb": "948"])
        XCTAssertEqual(MediaItemMerger.merge([a, b]).count, 1, "Identical titles stay merged; year slips must not false-split")
    }

    // MARK: Split-guard: series false merge (One Piece anime vs live-action)

    func testSeriesSharingBadExternalIDWithLargeYearGapAreSplit() {
        // A server emits ONE TVDb id for both the 1999 anime and the 2023
        // live-action "One Piece". The shared id would otherwise collapse them into
        // one card (hiding one show from Home/Search); the 24-year production gap
        // splits them back into two.
        let anime = item("a", title: "One Piece", kind: .series, year: 1999, account: "plex", ids: ["Tvdb": "81797"])
        let live = item("l", title: "One Piece", kind: .series, year: 2023, account: "jelly", ids: ["Tvdb": "81797"])
        let merged = MediaItemMerger.merge([anime, live])
        XCTAssertEqual(merged.count, 2, "Anime and live-action must not collapse via a single bad shared id")
        XCTAssertEqual(Set(merged.map(\.id)), ["a", "l"])
        XCTAssertTrue(merged.allSatisfy { $0.sources.isEmpty }, "Neither should absorb the other as a source")
    }

    func testSameShowSeriesWithMatchingYearStaysMerged() {
        // The decisive regression guard for the split-guard: a genuinely-shared
        // series stored under a *different title* on each server (localized /
        // "(Subtitled)") but the SAME debut year must still merge — the large-gap
        // rule keys off the year, not the title, so gap 0 keeps them together.
        let a = item("a", title: "One Piece", kind: .series, year: 1999, account: "plex", ids: ["Tvdb": "81797"])
        let b = item("b", title: "ONE PIECE (Subtitled)", kind: .series, year: 1999, account: "jelly", ids: ["Tvdb": "81797"])
        let merged = MediaItemMerger.merge([a, b])
        XCTAssertEqual(merged.count, 1, "A same-year same-show series must stay merged across differing titles")
        XCTAssertEqual(merged[0].sources.map(\.accountID).sorted(), ["jelly", "plex"])
    }

    func testTransitiveSeriesFalseMergeAcrossThreeServersIsSplit() {
        // Brandon's real setup: local Plex + local Jellyfin each hold BOTH shows,
        // and one Jellyfin item bridges anime↔live-action by carrying the anime's
        // TVDb id on the live-action entry. The two anime copies (gap 0) merge into
        // one card; both live-action entries eject — anime stays visible, live-action
        // is its own card, nothing disappears.
        let animePlex = item("ap", title: "One Piece", kind: .series, year: 1999, account: "plex", ids: ["Tvdb": "81797"])
        let liveJelly = item("lj", title: "One Piece", kind: .series, year: 2023, account: "jelly", ids: ["Tvdb": "81797"])
        let animeJelly = item("aj", title: "One Piece", kind: .series, year: 1999, account: "jelly", ids: ["Tvdb": "81797"])
        let merged = MediaItemMerger.merge([animePlex, liveJelly, animeJelly])
        let byYear = Dictionary(grouping: merged) { $0.productionYear }
        XCTAssertEqual(merged.count, 2, "Exactly two cards: the merged anime and the live-action")
        XCTAssertEqual(byYear[1999]?.first?.sources.map(\.accountID).sorted(), ["jelly", "plex"],
                       "Both 1999 anime copies merge across servers")
        XCTAssertEqual(byYear[2023]?.first?.sources.isEmpty, true, "The 2023 live-action stands alone")
    }

    func testSeriesWithoutYearsNeverSplitOnSharedID() {
        // A yearless series pair sharing a TVDb id carries no positive contradiction
        // (year is the series signal), so it must stay merged — never false-split a
        // sparsely-scraped legitimate twin.
        let a = item("a", title: "One Piece", kind: .series, year: nil, account: "plex", ids: ["Tvdb": "81797"])
        let b = item("b", title: "One Piece", kind: .series, year: nil, account: "jelly", ids: ["Tvdb": "81797"])
        XCTAssertEqual(MediaItemMerger.merge([a, b]).count, 1, "A yearless series twin is not split")
    }

    // MARK: - refineComponent / plausiblyContradicts unit edges

    func testSeriesContradictOnlyOnLargeProductionYearGap() {
        // Two same-named series a few years apart (Scream 6 '23 vs Scream 7 '26,
        // gap 3) are a normal sequel window, not a remake — must NOT contradict.
        let near6 = item("a", title: "Scream", kind: .series, year: 2023, account: "x")
        let near7 = item("b", title: "Scream", kind: .series, year: 2026, account: "y")
        XCTAssertFalse(MediaItemMerger.plausiblyContradicts(near6, near7),
                       "A small year gap between same-named series is not a contradiction")

        // A large production-year gap (anime 1999 vs live-action 2023, gap 24) IS a
        // contradiction — different works riding one bad shared id.
        let anime = item("c", title: "One Piece", kind: .series, year: 1999, account: "x")
        let live = item("d", title: "One Piece", kind: .series, year: 2023, account: "y")
        XCTAssertTrue(MediaItemMerger.plausiblyContradicts(anime, live),
                      "A large production-year gap between same-named series contradicts")

        // Missing a year on either side leaves the pair merged (no signal).
        let yearless = item("e", title: "One Piece", kind: .series, year: nil, account: "z")
        XCTAssertFalse(MediaItemMerger.plausiblyContradicts(anime, yearless),
                       "A series with no year never contradicts")
    }

    func testRefineComponentKeepsSingleMemberUntouched() {
        let only = item("a", title: "Scream 6", kind: .movie, year: 2023, account: "x")
        XCTAssertEqual(MediaItemMerger.refineComponent([only]).count, 1)
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
