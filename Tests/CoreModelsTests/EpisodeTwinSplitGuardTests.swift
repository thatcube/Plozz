import XCTest
@testable import CoreModels

/// Regression coverage for the cross-server **episode** split-guard.
///
/// Two related correctness bugs live in the same family (a bad shared external id
/// folding two *different* works into one card, then cross-linking their sources so
/// best-source playback / the version picker / the watch fan-out retarget the wrong
/// title):
///  * episode↔MOVIE — already closed at the identity layer (episodes are never
///    indexed, keys are kind-scoped, carried sources are sanitized). Locked here so
///    it can never regress.
///  * episode↔EPISODE — one server mis-tagging show Y's SxEy with show X's series
///    id makes both share the `series-<ns>:sXeY` merge key and collapse into one
///    card. The split-guard now ejects the impostor, keyed on **show identity +
///    season/episode**, never the per-episode title (which can differ across servers
///    for a legitimate twin).
final class EpisodeTwinSplitGuardTests: XCTestCase {

    private func ep(
        _ id: String,
        account: String,
        title: String,
        season: Int?,
        episode: Int?,
        seriesIDs: [String: String] = [:],
        sources: [MediaSourceRef] = []
    ) -> MediaItem {
        var providerIDs: [String: String] = [:]
        for (canonical, value) in seriesIDs {
            providerIDs["Series\(canonical.capitalized)"] = value
        }
        var m = MediaItem(
            id: id, title: title, kind: .episode,
            seasonNumber: season, episodeNumber: episode,
            providerIDs: providerIDs, sourceAccountID: account
        )
        m.sources = sources
        return m
    }

    private func movie(_ id: String, account: String, title: String, year: Int?, tmdb: String) -> MediaItem {
        var m = MediaItem(id: id, title: title, kind: .movie, productionYear: year, providerIDs: ["Tmdb": tmdb])
        m.sourceAccountID = account
        return m
    }

    // MARK: - episode↔movie can never merge (locks the existing fix)

    func testEpisodeAndMovieNeverMergeEvenSharingTitle() {
        // A movie whose title collides with an episode's title must NOT cross-link:
        // episode keys are season/episode-scoped and kind-scoped, a movie's are not.
        let episode = ep("11564", account: "A", title: "Hell or High Water",
                         season: 3, episode: 10, seriesIDs: ["tvdb": "74852"])
        let film = movie("4171", account: "B", title: "Hell or High Water", year: 2016, tmdb: "307663")
        let merged = MediaItemMerger.merge([episode, film])
        XCTAssertEqual(merged.count, 2, "A same-titled movie and episode must stay separate cards")
        let epCard = merged.first { $0.kind == .episode }
        XCTAssertNotNil(epCard)
        XCTAssertFalse(
            epCard!.sources.contains { $0.itemID == "4171" },
            "The episode's sources must never contain the movie's id (best-source can't target it)"
        )
    }

    func testIndexNeverLinksEpisodeToMovie() async {
        // Construction root: the eager index ingests only movies/series, so an
        // episode can never recover a movie source from it.
        let index = IdentityIndex()
        await index.ingest([movie("4171", account: "29B27180", title: "Hell or High Water", year: 2016, tmdb: "307663")],
                           accountID: "29B27180")
        let snapshot = await index.snapshot()
        let episode = ep("11564", account: "4413A6FB", title: "The Day of Black Sun",
                         season: 3, episode: 10, seriesIDs: ["tvdb": "74852"])
        let refs = snapshot.sourceRefs(for: episode).map(\.id)
        XCTAssertFalse(refs.contains("29B27180:4171"), "The index must not link an episode to a movie")
    }

    // MARK: - episode↔episode: different shows sharing a bad series id are split

    func testDifferentShowsEpisodesSharingBadSeriesIDAreSplit() {
        // Show Y S3E10 is mis-tagged with Show X's series TVDb id, same S/E, so both
        // share the `series-tvdb:s3e10` merge key. Their OTHER series id (imdb)
        // proves they're different shows: the guard must split them.
        let showX = ep("epX", account: "A", title: "The Day of Black Sun",
                       season: 3, episode: 10, seriesIDs: ["tvdb": "111", "imdb": "tt0417299"],
                       sources: [MediaSourceRef(accountID: "A", itemID: "epX", kind: .episode)])
        let showY = ep("epY", account: "B", title: "Caballo Sin Nombre",
                       season: 3, episode: 10, seriesIDs: ["tvdb": "111", "imdb": "tt0903747"],
                       sources: [MediaSourceRef(accountID: "B", itemID: "epY", kind: .episode)])
        let merged = MediaItemMerger.merge([showX, showY])
        XCTAssertEqual(merged.count, 2, "Different shows' episodes on a bad shared series id must NOT merge")
        for card in merged {
            XCTAssertEqual(card.sources.count, 1, "Each split episode keeps only its own source")
        }
        let xCard = merged.first { $0.id == "epX" }
        XCTAssertNotNil(xCard)
        XCTAssertFalse(
            xCard!.sources.contains { $0.accountID == "B" },
            "Show X's episode must never carry Show Y's server as a source"
        )
    }

    func testMismatchedSeasonEpisodeNumbersSplit() {
        // If a shared episode-level id ever unions two different slots in a run, the
        // differing S/E is itself a positive contradiction.
        let a = ep("a", account: "A", title: "Ep A", season: 1, episode: 2, seriesIDs: ["tvdb": "500"])
        let b = ep("b", account: "B", title: "Ep B", season: 1, episode: 3, seriesIDs: ["tvdb": "500"])
        XCTAssertTrue(MediaItemMerger.plausiblyContradicts(a, b))
    }

    // MARK: - legitimate cross-server episode twins must STILL merge

    func testLegitEpisodeTwinMergesEvenWithDifferentPerEpisodeTitles() {
        // Same show, same S03E15, on two accounts — but each server scraped a
        // slightly different per-episode title. Keying on show identity + S/E (not
        // title) keeps the real duplicate merged with BOTH sources.
        let a = ep("epA", account: "A", title: "The Boiling Rock, Part 1",
                   season: 3, episode: 15, seriesIDs: ["tvdb": "111", "imdb": "tt0417299"])
        let b = ep("epB", account: "B", title: "The Boiling Rock",
                   season: 3, episode: 15, seriesIDs: ["tvdb": "111", "imdb": "tt0417299"])
        let merged = MediaItemMerger.merge([a, b])
        XCTAssertEqual(merged.count, 1, "The same episode on two servers must merge")
        XCTAssertEqual(Set(merged[0].sources.map(\.id)), ["A:epA", "B:epB"],
                       "Both legitimate twin sources survive")
    }

    func testLegitTwinMergesWhenOneServerOmitsSomeSeriesIDs() {
        // A sparse twin (one server exposes only the tvdb id, the other adds imdb)
        // has no *conflicting* namespace, so it must never split.
        let a = ep("epA", account: "A", title: "The Boiling Rock",
                   season: 3, episode: 15, seriesIDs: ["tvdb": "111"])
        let b = ep("epB", account: "B", title: "The Boiling Rock",
                   season: 3, episode: 15, seriesIDs: ["tvdb": "111", "imdb": "tt0417299"])
        let merged = MediaItemMerger.merge([a, b])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(Set(merged[0].sources.map(\.id)), ["A:epA", "B:epB"])
    }

    func testMergedGroupDropsPoisonContributedByOneEpisodeMember() {
        // A legit twin pair where ONE member also carries a frozen movie ref: the
        // twins still merge, but the cross-kind poison is stripped from the result so
        // best-source playback can't retarget onto the movie.
        let a = ep("epA", account: "A", title: "The Boiling Rock",
                   season: 3, episode: 15, seriesIDs: ["tvdb": "111"],
                   sources: [
                        MediaSourceRef(accountID: "A", itemID: "epA", kind: .episode),
                        MediaSourceRef(accountID: "X", itemID: "4171", kind: .movie)
                   ])
        let b = ep("epB", account: "B", title: "The Boiling Rock",
                   season: 3, episode: 15, seriesIDs: ["tvdb": "111"],
                   sources: [MediaSourceRef(accountID: "B", itemID: "epB", kind: .episode)])
        let merged = MediaItemMerger.merge([a, b])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(Set(merged[0].sources.map(\.id)), ["A:epA", "B:epB"],
                       "Legit twins kept; the cross-kind movie ref dropped")
    }

    // MARK: - episodesPlausiblyContradict primitive

    func testPrimitiveContradictsOnConflictingSeriesID() {
        XCTAssertTrue(MediaItemIdentity.episodesPlausiblyContradict(
            seasonA: 3, episodeA: 10, seriesIDsA: ["tvdb": "111", "imdb": "aaa"],
            seasonB: 3, episodeB: 10, seriesIDsB: ["tvdb": "111", "imdb": "bbb"]
        ))
    }

    func testPrimitiveDoesNotContradictOnMatchingSeriesID() {
        XCTAssertFalse(MediaItemIdentity.episodesPlausiblyContradict(
            seasonA: 3, episodeA: 15, seriesIDsA: ["tvdb": "111"],
            seasonB: 3, episodeB: 15, seriesIDsB: ["tvdb": "111", "imdb": "tt0417299"]
        ))
    }

    func testPrimitiveDoesNotContradictOnAbsentSignal() {
        // No overlapping series id and no S/E signal ⇒ never a positive contradiction.
        XCTAssertFalse(MediaItemIdentity.episodesPlausiblyContradict(
            seasonA: nil, episodeA: nil, seriesIDsA: [:],
            seasonB: nil, episodeB: nil, seriesIDsB: [:]
        ))
        XCTAssertFalse(MediaItemIdentity.episodesPlausiblyContradict(
            seasonA: 3, episodeA: 15, seriesIDsA: ["tvdb": "111"],
            seasonB: 3, episodeB: 15, seriesIDsB: ["imdb": "tt0417299"]
        ))
    }

    func testPrimitiveDoesNotContradictWhenOneSideMissingSeasonEpisode() {
        // Partial signal: one side exposes no season/episode number but shares a
        // legit series id. A missing S/E is ABSENT signal, not a conflict, so the
        // guard must not fire — the real twin stays merged (no over-eager split).
        XCTAssertFalse(MediaItemIdentity.episodesPlausiblyContradict(
            seasonA: 3, episodeA: 15, seriesIDsA: ["tvdb": "111"],
            seasonB: nil, episodeB: nil, seriesIDsB: ["tvdb": "111"]
        ))
    }

    func testRefineComponentDoesNotSplitPartialSignalTwin() {
        // The same partial-signal twin, exercised through the actual split path: if a
        // union folds these two together (one side missing S/E, shared legit series
        // id), the split-guard must keep them in ONE group rather than eject either.
        let full = ep("epA", account: "A", title: "The Boiling Rock",
                      season: 3, episode: 15, seriesIDs: ["tvdb": "111"])
        let partial = ep("epB", account: "B", title: "The Boiling Rock",
                         season: nil, episode: nil, seriesIDs: ["tvdb": "111"])
        let groups = MediaItemMerger.refineComponent([full, partial])
        XCTAssertEqual(groups.count, 1, "A partial-signal legit twin must not be split")
        XCTAssertEqual(Set(groups[0].map(\.id)), ["epA", "epB"])
    }

    func testSeriesExternalIDsExtractsShowLevelIds() {
        let episode = ep("e", account: "A", title: "x", season: 1, episode: 1,
                         seriesIDs: ["tvdb": "111", "imdb": "tt0417299"])
        let ids = MediaItemIdentity.seriesExternalIDs(for: episode)
        XCTAssertEqual(ids["tvdb"], "111")
        XCTAssertEqual(ids["imdb"], "tt0417299")
    }
}
