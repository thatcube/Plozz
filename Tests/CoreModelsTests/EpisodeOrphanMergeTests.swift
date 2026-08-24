import XCTest
@testable import CoreModels

/// Rescuing an episode that carries no external id at all onto its identified
/// twin on another server.
///
/// The regression these exist for: a show held on BOTH a Jellyfin/Plex server and
/// a plain SMB share appeared twice in Continue Watching — the server's card with
/// its progress, and the share's with none. Every episode key in
/// `MediaItemIdentity.identities(for:)` is built from an external id and the title
/// fallback there is movie-only, so a share episode (everything derived from the
/// filename, no ids) produced ZERO merge keys and could never join anything.
final class EpisodeOrphanMergeTests: XCTestCase {

    private func episode(
        _ id: String,
        series: String?,
        season: Int?,
        number: Int?,
        account: String,
        ids: [String: String] = [:],
        title: String = "Ace Degenerate",
        resume: TimeInterval? = nil,
        year: Int? = nil
    ) -> MediaItem {
        MediaItem(
            id: id,
            title: title,
            kind: .episode,
            parentTitle: series,
            seasonNumber: season,
            episodeNumber: number,
            productionYear: year,
            resumePosition: resume,
            providerIDs: ids,
            sourceAccountID: account
        )
    }

    // MARK: - The reported bug

    func testShareEpisodeWithNoIDsMergesOntoServerTwin() {
        let jellyfin = episode(
            "jf-1", series: "Cobra Kai", season: 1, number: 1, account: "jellyfin",
            ids: ["SeriesTvdb": "350665", "Tvdb": "6738production"], resume: 300
        )
        let share = episode("f:TV Shows/Cobra Kai/Season 1/E01.mkv",
                            series: "Cobra Kai", season: 1, number: 1, account: "smb")
        let merged = MediaItemMerger.merge([jellyfin, share])
        XCTAssertEqual(merged.count, 1, "one episode, one card")
        XCTAssertEqual(merged.first?.id, "jf-1", "the identified copy stays primary")
        XCTAssertEqual(
            Set(merged.first?.sources.map(\.accountID) ?? []),
            ["jellyfin", "smb"],
            "the share is kept as a playable source, not discarded"
        )
    }

    func testMergedCardKeepsTheProgressTheServerHad() {
        let jellyfin = episode("jf-1", series: "Cobra Kai", season: 1, number: 1,
                               account: "jellyfin", ids: ["Tvdb": "1"], resume: 300)
        let share = episode("f:x.mkv", series: "Cobra Kai", season: 1, number: 1, account: "smb")
        let merged = MediaItemMerger.merge([share, jellyfin])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.resumePosition, 300,
                       "progress made on any server survives the merge")
    }

    func testTwoIDLessCopiesOfOneEpisodeCollapse() {
        let shareA = episode("f:a.mkv", series: "Cobra Kai", season: 1, number: 1, account: "smb-a")
        let shareB = episode("f:b.mkv", series: "Cobra Kai", season: 1, number: 1, account: "smb-b")
        let merged = MediaItemMerger.merge([shareA, shareB])
        XCTAssertEqual(merged.count, 1, "two shares must not add a third card either")
    }

    // MARK: - Safety

    func testDifferentEpisodesOfOneShowStaySeparate() {
        let one = episode("jf-1", series: "Cobra Kai", season: 1, number: 1,
                          account: "jellyfin", ids: ["Tvdb": "1"])
        let two = episode("f:e02.mkv", series: "Cobra Kai", season: 1, number: 2, account: "smb")
        XCTAssertEqual(MediaItemMerger.merge([one, two]).count, 2)
    }

    func testDifferentSeasonsStaySeparate() {
        let one = episode("jf-1", series: "Cobra Kai", season: 1, number: 1,
                          account: "jellyfin", ids: ["Tvdb": "1"])
        let two = episode("f:s02e01.mkv", series: "Cobra Kai", season: 2, number: 1, account: "smb")
        XCTAssertEqual(MediaItemMerger.merge([one, two]).count, 2)
    }

    func testDifferentShowsStaySeparate() {
        let one = episode("jf-1", series: "Cobra Kai", season: 1, number: 1,
                          account: "jellyfin", ids: ["Tvdb": "1"])
        let two = episode("f:arcane.mkv", series: "Arcane", season: 1, number: 1, account: "smb")
        XCTAssertEqual(MediaItemMerger.merge([one, two]).count, 2)
    }

    func testAmbiguousSameTitledShowsLeaveTheOrphanAlone() {
        // "The Office" UK and US both carry ids, so they sit in two different
        // components. Guessing which one an id-less copy belongs to would put a
        // file under the wrong show, so it is left as its own card instead.
        let uk = episode("jf-uk", series: "The Office", season: 1, number: 1,
                         account: "jellyfin", ids: ["Tvdb": "78107"])
        let us = episode("jf-us", series: "The Office", season: 1, number: 1,
                         account: "jellyfin2", ids: ["Tvdb": "73244"])
        let share = episode("f:office.mkv", series: "The Office", season: 1, number: 1, account: "smb")
        let merged = MediaItemMerger.merge([uk, us, share])
        XCTAssertEqual(merged.count, 3, "an ambiguous rescue must not be guessed")
    }

    func testTwoIdentifiedEpisodesThatDisagreeAreNeverForcedTogether() {
        let uk = episode("jf-uk", series: "The Office", season: 1, number: 1,
                         account: "jellyfin", ids: ["Tvdb": "78107"])
        let us = episode("jf-us", series: "The Office", season: 1, number: 1,
                         account: "jellyfin2", ids: ["Tvdb": "73244"])
        XCTAssertEqual(MediaItemMerger.merge([uk, us]).count, 2,
                       "the rescue only ever moves an id-less episode")
    }

    func testEpisodeWithNoSeriesTitleIsNotRescued() {
        let jellyfin = episode("jf-1", series: "Cobra Kai", season: 1, number: 1,
                               account: "jellyfin", ids: ["Tvdb": "1"])
        let orphan = episode("f:x.mkv", series: nil, season: 1, number: 1, account: "smb")
        XCTAssertEqual(MediaItemMerger.merge([jellyfin, orphan]).count, 2,
                       "no series name is not enough to key on")
    }

    func testEpisodeWithNoSeasonOrNumberIsNotRescued() {
        let jellyfin = episode("jf-1", series: "Cobra Kai", season: 1, number: 1,
                               account: "jellyfin", ids: ["Tvdb": "1"])
        let orphan = episode("f:x.mkv", series: "Cobra Kai", season: nil, number: nil, account: "smb")
        XCTAssertEqual(MediaItemMerger.merge([jellyfin, orphan]).count, 2)
    }

    func testAMovieIsNeverRescuedOntoAnEpisode() {
        let show = episode("jf-1", series: "Cobra Kai", season: 1, number: 1,
                           account: "jellyfin", ids: ["Tvdb": "1"])
        let film = MediaItem(id: "mv", title: "Cobra Kai", kind: .movie,
                             parentTitle: "Cobra Kai", productionYear: 1984,
                             sourceAccountID: "smb")
        XCTAssertEqual(MediaItemMerger.merge([show, film]).count, 2)
    }

    // MARK: - Servers disagreeing about the show's name

    func testSeriesNameWithATrailingYearStillMatches() {
        // Real data: Plex reports "Bodies (2023)" (its folder name) where the
        // share's filename parse says "Bodies". Requiring equal names left this
        // one duplicated while Cobra Kai, spelled identically everywhere,
        // collapsed correctly.
        let plex = episode("plex-1", series: "Bodies (2023)", season: 1, number: 1,
                           account: "plex", ids: ["Imdb": "tt18766898"], resume: 200)
        let share = episode("f:TV Shows/Bodies/Season 1/E01.mkv",
                            series: "Bodies", season: 1, number: 1, account: "smb")
        let merged = MediaItemMerger.merge([plex, share])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.id, "plex-1")
    }

    func testSeriesNameWithASubtitleStillMatches() {
        // Real data: Jellyfin reports "Arcane: League of Legends", the share says
        // "Arcane".
        let jellyfin = episode("jf-1", series: "Arcane: League of Legends",
                               season: 1, number: 9, account: "jellyfin",
                               ids: ["Imdb": "tt15496440"])
        let share = episode("f:arcane.mkv", series: "Arcane", season: 1, number: 9,
                            account: "smb")
        XCTAssertEqual(MediaItemMerger.merge([jellyfin, share]).count, 1)
    }

    func testYearIsStrippedFromTheSeriesName() {
        let withYear = episode("a", series: "Bodies (2023)", season: 1, number: 1, account: "x")
        let without = episode("b", series: "Bodies", season: 1, number: 1, account: "y")
        XCTAssertEqual(MediaItemMerger.normalizedSeriesTitle(for: withYear), "bodies")
        XCTAssertEqual(MediaItemMerger.normalizedSeriesTitle(for: without), "bodies")
    }

    func testATrailingNumberThatIsNotAYearIsKept() {
        let item = episode("a", series: "Stranger Things 4", season: 1, number: 1, account: "x")
        XCTAssertEqual(MediaItemMerger.normalizedSeriesTitle(for: item), "stranger things 4")
    }

    func testAPrefixPairThatBothCarryIDsIsStillNotGuessed() {
        // "Star Trek" and "Star Trek Discovery" are prefix-compatible, so an
        // id-less orphan must not be dropped into one of them at random.
        let trek = episode("jf-1", series: "Star Trek", season: 1, number: 1,
                           account: "jellyfin", ids: ["Imdb": "tt0060028"])
        let disco = episode("jf-2", series: "Star Trek: Discovery", season: 1, number: 1,
                            account: "jellyfin2", ids: ["Imdb": "tt5171438"])
        let share = episode("f:trek.mkv", series: "Star Trek", season: 1, number: 1, account: "smb")
        XCTAssertEqual(MediaItemMerger.merge([trek, disco, share]).count, 3)
    }

    func testAnOrphanJoinsTheOnlyCompatibleShowNotAnUnrelatedOne() {
        let arcane = episode("jf-1", series: "Arcane: League of Legends", season: 1,
                             number: 9, account: "jellyfin", ids: ["Imdb": "tt15496440"])
        let bodies = episode("jf-2", series: "Bodies (2023)", season: 1, number: 9,
                             account: "jellyfin", ids: ["Imdb": "tt18766898"])
        let share = episode("f:arcane.mkv", series: "Arcane", season: 1, number: 9, account: "smb")
        let merged = MediaItemMerger.merge([arcane, bodies, share])
        XCTAssertEqual(merged.count, 2, "the share joins Arcane, leaving Bodies alone")
        let arcaneCard = merged.first { $0.id == "jf-1" }
        XCTAssertEqual(Set(arcaneCard?.sources.map(\.accountID) ?? []), ["jellyfin", "smb"])
    }

    // MARK: - The key itself

    func testKeyFoldsCaseAndPunctuation() {
        let a = episode("a", series: "Cobra-Kai", season: 1, number: 3, account: "x")
        let b = episode("b", series: "  COBRA   kai ", season: 1, number: 3, account: "y")
        XCTAssertEqual(MediaItemMerger.episodeTitleKey(for: a),
                       MediaItemMerger.episodeTitleKey(for: b))
        XCTAssertEqual(MediaItemMerger.merge([a, b]).count, 1)
    }

    func testKeyIsNilWithoutEveryPart() {
        XCTAssertNil(MediaItemMerger.episodeTitleKey(
            for: episode("a", series: "  ", season: 1, number: 1, account: "x")
        ))
        XCTAssertNil(MediaItemMerger.episodeTitleKey(
            for: episode("a", series: "Cobra Kai", season: 1, number: nil, account: "x")
        ))
    }

    func testMergeIsOrderIndependent() {
        let jellyfin = episode("jf-1", series: "Cobra Kai", season: 1, number: 1,
                               account: "jellyfin", ids: ["Tvdb": "1"])
        let share = episode("f:x.mkv", series: "Cobra Kai", season: 1, number: 1, account: "smb")
        let other = episode("jf-2", series: "Arcane", season: 1, number: 9,
                            account: "jellyfin", ids: ["Tvdb": "2"])
        XCTAssertEqual(MediaItemMerger.merge([jellyfin, share, other]).count, 2)
        XCTAssertEqual(MediaItemMerger.merge([other, share, jellyfin]).count, 2)
        XCTAssertEqual(MediaItemMerger.merge([share, other, jellyfin]).count, 2)
    }
}
