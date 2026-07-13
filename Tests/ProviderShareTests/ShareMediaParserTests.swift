import XCTest
@testable import ProviderShare

/// Coverage for the FOLDER-aware classifier (`ShareMediaParser.classify(relPath:)`):
/// bare-numbered anime/TV must read as episodes when the folder tree says "series",
/// while movies whose title ends in a number must stay movies in a movie context.
final class ShareMediaParserTests: XCTestCase {
    private func classify(_ relPath: String) -> ShareMediaParser.Kind {
        ShareMediaParser.classify(relPath: relPath)
    }

    private func episode(_ relPath: String, file: StaticString = #filePath, line: UInt = #line)
        -> ShareMediaParser.Episode? {
        guard case let .episode(ep) = classify(relPath) else {
            XCTFail("expected episode for \(relPath)", file: file, line: line); return nil
        }
        return ep
    }

    private func movie(_ relPath: String, file: StaticString = #filePath, line: UInt = #line)
        -> ShareMediaParser.Movie? {
        guard case let .movie(m) = classify(relPath) else {
            XCTFail("expected movie for \(relPath)", file: file, line: line); return nil
        }
        return m
    }

    // MARK: - Bare-numbered anime/TV become episodes in a series context

    func testBareNumberedAnimeWithDashIsEpisode() {
        let ep = episode("Anime/Sword Art Online II/Sword Art Online II - 18.mkv")
        XCTAssertEqual(ep?.series, "Sword Art Online II")
        XCTAssertEqual(ep?.season, 1)
        XCTAssertEqual(ep?.episode, 18)
    }

    func testBareNumberedAnimeNoDashIsEpisode() {
        let ep = episode("Anime/Sword Art Online 2/Sword Art Online 2 18.mkv")
        XCTAssertEqual(ep?.series, "Sword Art Online 2")
        XCTAssertEqual(ep?.episode, 18)
    }

    func testBareNumberInSeasonFolderTakesSeasonFromFolder() {
        let ep = episode("TV/Show/Season 3/Show 07.mkv")
        XCTAssertEqual(ep?.series, "Show")
        XCTAssertEqual(ep?.season, 3)
        XCTAssertEqual(ep?.episode, 7)
    }

    func testEMarkerBareEpisode() {
        let ep = episode("TV Shows/Show/Show E18.mkv")
        XCTAssertEqual(ep?.episode, 18)
        XCTAssertEqual(ep?.season, 1)
    }

    func testHashMarkerBareEpisode() {
        XCTAssertEqual(episode("TV/Show/Show #18.mkv")?.episode, 18)
    }

    func testBracketedBareEpisode() {
        let ep = episode("Anime/Show/Show [18].mkv")
        XCTAssertEqual(ep?.series, "Show")
        XCTAssertEqual(ep?.episode, 18)
    }

    func testSpecialsFolderIsSeasonZero() {
        let ep = episode("TV/Show/Specials/Show 02.mkv")
        XCTAssertEqual(ep?.season, 0)
        XCTAssertEqual(ep?.episode, 2)
    }

    func testStaffelFolderIsSeason() {
        let ep = episode("TV/Show/Staffel 2/Show 03.mkv")
        XCTAssertEqual(ep?.season, 2)
        XCTAssertEqual(ep?.episode, 3)
    }

    func testExplicitMarkerStillWinsInSeasonFolder() {
        let ep = episode("TV Shows/Breaking Bad/Season 02/Breaking Bad - S02E05.mkv")
        XCTAssertEqual(ep?.season, 2)
        XCTAssertEqual(ep?.episode, 5)
    }

    func testExplicitMarkerWorksWithoutFolderContext() {
        // A strong SxxEyy marker classifies as an episode from any folder.
        XCTAssertNotNil(episode("Downloads/Breaking Bad S01E01.mkv"))
    }

    // MARK: - Series anchored to the show folder (not filename/nested folders)

    func testShowFolderOverridesFilenameVariantPrefix() {
        // Netflix "Remix" re-cut of Arrested Development S4: the files carry a
        // variant prefix in the name, but they live in the show's Season 4 folder
        // and must group under the show, not a separate "…Remix" series.
        let ep = episode(
            "TV Shows/Arrested Development/Season 4/Arrested.Development.Remix.S04E01.The.Fall.1080p.mkv"
        )
        XCTAssertEqual(ep?.series, "Arrested Development")
        XCTAssertEqual(ep?.season, 4)
        XCTAssertEqual(ep?.episode, 1)
    }

    func testShowFolderOverridesRedundantNestedSubfolder() {
        // A redundant nested folder below the season folder must not fork a
        // separate series; the show folder above the season wins.
        let ep = episode(
            "TV Shows/Arrested Development/Season 1/Arrested Development S01/S01E01 - Pilot.mkv"
        )
        XCTAssertEqual(ep?.series, "Arrested Development")
        XCTAssertEqual(ep?.season, 1)
        XCTAssertEqual(ep?.episode, 1)
    }

    func testVariantPrefixAndCleanNameGroupToSameSeriesKey() {
        // The real fix: the two forms must land on the SAME grouping key so they
        // fold into one card.
        let remix = episode(
            "TV Shows/Arrested Development/Season 4/Arrested.Development.Remix.S04E01.x.mkv"
        )
        let plain = episode(
            "TV Shows/Arrested Development/Season 1/S01E09 - Storming the Castle.mkv"
        )
        XCTAssertEqual(
            ShareCatalogID.seriesKey(fromTitle: remix?.series ?? ""),
            ShareCatalogID.seriesKey(fromTitle: plain?.series ?? "")
        )
    }

    func testShowFolderAnchorHopsStackedSeasonFolders() {
        // A season folder directly under the show, with the show under a TV root.
        let ep = episode("TV/Better Call Saul/Season 3/Better.Call.Saul.S03E05.mkv")
        XCTAssertEqual(ep?.series, "Better Call Saul")
    }

    func testLooseFileKeepsFilenameSeriesWithoutShowFolder() {
        // No season folder and no recognized library root → the junk container
        // must NOT override the filename-derived series.
        let ep = episode("Downloads/Breaking Bad S01E01.mkv")
        XCTAssertEqual(ep?.series, "Breaking Bad")
    }

    func testBareNumberStripsResolutionBeforePickingEpisode() {
        // The 1080p must not be mistaken for the episode number.
        let ep = episode("Anime/Show/Show - 09 [1080p].mkv")
        XCTAssertEqual(ep?.episode, 9)
    }

    // MARK: - Movie guards (trailing numbers must NOT read as episodes)

    func testMovieWithTrailingNumberInMoviesFolderStaysMovie() {
        let m = movie("Movies/Rocky 2 (2006).mkv")
        XCTAssertEqual(m?.title, "Rocky 2")
        XCTAssertEqual(m?.year, 2006)
    }

    func testOceansElevenStaysMovie() {
        XCTAssertEqual(movie("Movies/Ocean's 11 (2001).mkv")?.year, 2001)
    }

    func testBladeRunner2049UsesReleaseYearNotTitleNumber() {
        let m = movie("Movies/Blade Runner 2049 (2017).mkv")
        XCTAssertEqual(m?.title, "Blade Runner 2049")
        XCTAssertEqual(m?.year, 2017)
    }

    func testMovieInDedicatedFolderVersion() {
        let m = movie("Movies/Star Wars (1977)/Star Wars (1977) Bluray-1080p.mkv")
        XCTAssertEqual(m?.title, "Star Wars")
        XCTAssertEqual(m?.year, 1977)
    }

    func testYearOnlyFolderDoesNotBecomeMovieIdentity() {
        let grouping = ShareMediaParser.movieGrouping(
            relPath: "Movies/2024/Actual Movie (2019).mkv",
            parsedTitle: "Actual Movie",
            parsedYear: 2019
        )
        XCTAssertEqual(grouping.title, "Actual Movie")
        XCTAssertEqual(grouping.year, 2019)
    }

    func testAnimeMovieIsMovieNotEpisode() {
        let m = movie("Anime Movies/Your Name (2016).mkv")
        XCTAssertEqual(m?.title, "Your Name")
        XCTAssertEqual(m?.year, 2016)
    }

    func testNumberedAnimeFilmInsideMixedAnimeRootIsMovie() {
        let ghost = movie("Anime/Ghost in the Shell 2 (2004)/Ghost in the Shell 2 (2004).mkv")
        XCTAssertEqual(ghost?.title, "Ghost in the Shell 2")
        XCTAssertEqual(ghost?.year, 2004)

        let bladeRunner = movie("Anime/Blade Runner 2049 (2017)/Blade Runner 2049 (2017).mkv")
        XCTAssertEqual(bladeRunner?.title, "Blade Runner 2049")
        XCTAssertEqual(bladeRunner?.year, 2017)
    }

    func testNumberedFilmDirectlyInsideSeriesRootIsMovie() {
        let bladeRunner = movie("Anime/Blade Runner 2049 (2017).mkv")
        XCTAssertEqual(bladeRunner?.title, "Blade Runner 2049")
        XCTAssertEqual(bladeRunner?.year, 2017)

        let oceans = movie("TV/Ocean's 13 (2007).mkv")
        XCTAssertEqual(oceans?.title, "Ocean's 13")
        XCTAssertEqual(oceans?.year, 2007)
    }

    func testYearBearingSeriesFolderStillAcceptsBareEpisodeNumber() {
        let ep = episode("TV/Show (2024)/Show 01.mkv")
        XCTAssertEqual(ep?.series, "Show")
        XCTAssertEqual(ep?.season, 1)
        XCTAssertEqual(ep?.episode, 1)
    }

    func testYearBearingSeriesFilenameStillAcceptsNewTrailingEpisodeNumber() {
        let ep = episode("TV/Show (2024)/Show (2024) 01.mkv")
        XCTAssertEqual(ep?.series, "Show")
        XCTAssertEqual(ep?.episode, 1)
    }

    func testNumericSeriesTitleStillAcceptsBareEpisodeNumber() {
        let ep = episode("TV/1923/1923 - 05.mkv")
        XCTAssertEqual(ep?.series, "1923")
        XCTAssertEqual(ep?.season, 1)
        XCTAssertEqual(ep?.episode, 5)
    }

    // MARK: - No TV context ⇒ conservative (bare numbers stay movies)

    func testBareNumberWithoutSeriesContextStaysMovie() {
        // A loose, non-library folder gives no "series" signal, so we don't invent
        // an episode from a trailing number — it stays a movie.
        guard case .movie = classify("Downloads/Show 05.mkv") else {
            return XCTFail("expected movie without a series folder context")
        }
    }

    // MARK: - Context + season helpers

    func testLibraryContext() {
        XCTAssertEqual(ShareMediaParser.libraryContext(["Movies"]), .movieLibrary)
        XCTAssertEqual(ShareMediaParser.libraryContext(["Anime Movies"]), .movieLibrary)
        XCTAssertEqual(ShareMediaParser.libraryContext(["Anime"]), .seriesLibrary)
        XCTAssertEqual(ShareMediaParser.libraryContext(["TV Shows"]), .seriesLibrary)
        XCTAssertEqual(ShareMediaParser.libraryContext(["Downloads"]), .unknown)
    }

    func testSeasonNumberFromFolder() {
        XCTAssertEqual(ShareMediaParser.seasonNumber(fromFolder: "Season 03"), 3)
        XCTAssertEqual(ShareMediaParser.seasonNumber(fromFolder: "S3"), 3)
        XCTAssertEqual(ShareMediaParser.seasonNumber(fromFolder: "Staffel 2"), 2)
        XCTAssertEqual(ShareMediaParser.seasonNumber(fromFolder: "Specials"), 0)
        XCTAssertNil(ShareMediaParser.seasonNumber(fromFolder: "Anime"))
        XCTAssertNil(ShareMediaParser.seasonNumber(fromFolder: "Series"))
    }

    // MARK: - Real-library series-title normalization (junky folder → clean title)

    private func seriesKey(_ title: String) -> String {
        ShareCatalogID.seriesKey(fromTitle: title)
    }

    func testJunkFolderTokensAreStrippedFromSeriesTitle() {
        // Folders carrying release/season junk resolve to a clean show title, so a
        // no-match becomes a confident match. (Ground-truth cases from a real share.)
        XCTAssertEqual(episode("TV/Deadloch.cc/Deadloch.S01E01.mkv")?.series, "Deadloch")
        XCTAssertEqual(episode("TV/Sharp Objects cc/Sharp.Objects.S01E01.mkv")?.series, "Sharp Objects")
        XCTAssertEqual(episode("TV/Yellowjackets cc/Yellowjackets.S02E01.mkv")?.series, "Yellowjackets")
        XCTAssertEqual(episode("TV/Barry Season 02/Barry.S02E01.mkv")?.series, "Barry")
    }

    func testLastOfUsJunkyFolderNormalizes() {
        // Folder carries season/release junk and no inline year; the title still
        // resolves cleanly (year comes from enrichment). A year BEFORE the marker
        // is captured — see the live-action Avatar case below.
        let ep = episode("TV/The Last of Us Season 01 LVL7T7/The.Last.of.Us.S01E01.mkv")
        XCTAssertEqual(ep?.series, "The Last of Us")
        let withYear = episode("TV/The Last of Us/The.Last.of.Us.2023.S01E01.mkv")
        XCTAssertEqual(withYear?.series, "The Last of Us")
        XCTAssertEqual(withYear?.year, 2023)
    }

    func testHouseOfTheDragonSplitFoldersMergeToOneSeries() {
        // The same show in two differently-named folders must collapse to ONE card:
        // grouping keys off the NORMALIZED folder title, so both resolve equal.
        let plain = episode("TV/House of the Dragon/House.of.the.Dragon.S01E01.mkv")
        let junky = episode(
            "TV/House of the Dragon (2022) Season 1 S01 (1080p BluRay x265)/House.of.the.Dragon.S01E02.mkv"
        )
        XCTAssertEqual(plain?.series, "House of the Dragon")
        XCTAssertEqual(junky?.series, "House of the Dragon")
        XCTAssertEqual(seriesKey(plain?.series ?? "a"), seriesKey(junky?.series ?? "b"))
    }

    func testAvatarAnimatedAndLiveActionStaySeparateSeries() {
        // Distinctly-named folders for genuinely different shows must NOT merge.
        let animated = episode("TV/Avatar the Last Airbender/Avatar.the.Last.Airbender.S01E01.mkv")
        let liveAction = episode("TV/Avatar (2024)/Avatar.The.Last.Airbender.2024.S01E01.mkv")
        // Live-action groups by its generic folder ("Avatar") + carries its year.
        XCTAssertEqual(liveAction?.series, "Avatar")
        XCTAssertEqual(liveAction?.year, 2024)
        XCTAssertNotEqual(
            seriesKey(animated?.series ?? "a"),
            seriesKey(liveAction?.series ?? "b")
        )
    }

    func testGenericFolderRecoversRicherFilenameTitleAsSearchAlternate() {
        // The Avatar (2024) fix: a generic folder groups as "Avatar", but the files
        // carry the richer "Avatar The Last Airbender" used as an extra search title.
        XCTAssertEqual(
            ShareMediaParser.filenameSeriesTitle(
                relPath: "TV/Avatar (2024)/Avatar.The.Last.Airbender.2024.S01E01.mkv"
            ),
            "Avatar The Last Airbender"
        )
        // A file that already matches its folder yields the same title (dedup-able).
        XCTAssertEqual(
            ShareMediaParser.filenameSeriesTitle(relPath: "TV/Barry Season 02/Barry.S02E01.mkv"),
            "Barry"
        )
    }

    func testNumericAndShortTitlesSurviveNormalization() {
        // Guard: the "cut at first junk token" logic always keeps the first token, so
        // legitimately numeric/short show titles are never emptied.
        XCTAssertEqual(episode("TV/1883/1883.S01E01.mkv")?.series, "1883")
        XCTAssertEqual(episode("TV/1923/1923.S01E02.mkv")?.series, "1923")
        XCTAssertEqual(episode("TV/Max Headroom/Max.Headroom.S01E01.mkv")?.series, "Max Headroom")
    }

    func testReleaseTagIsNotMistakenForEpisodeTitle() {
        // Trailing HDR/DV/resolution tags after the SxxEyy marker are release junk,
        // not an episode title.
        XCTAssertNil(episode("TV/Show/Show.S01E01.HDR.mkv")?.title)
        XCTAssertNil(episode("TV/Show/Show.S01E02.2160p.DV.mkv")?.title)
        // A genuine trailing title is still kept.
        XCTAssertEqual(episode("TV/Show/Show.S01E03.The Reveal.mkv")?.title, "The Reveal")
    }

    // MARK: - Robust series keys (same show under inconsistent folder names merges)

    func testLeadingArticleFoldedInSeriesKey() {
        // "The Mandalorian" folder vs a bare "mandalorian" folder must be ONE series.
        XCTAssertEqual(seriesKey("The Mandalorian"), seriesKey("mandalorian"))
        XCTAssertEqual(seriesKey("mandalorian"), "mandalorian")
        // An internal "the" is preserved (only a LEADING article is dropped).
        XCTAssertEqual(seriesKey("House of the Dragon"), "house-of-the-dragon")
        // A one-word title that IS an article keeps its token (never emptied).
        XCTAssertEqual(seriesKey("The"), "the")
    }

    func testPossessiveApostropheFoldedInSeriesKey() {
        // "The Handmaid's Tale" and "The Handmaids Tale" are the same show.
        XCTAssertEqual(seriesKey("The Handmaid's Tale"), seriesKey("The Handmaids Tale"))
        XCTAssertEqual(seriesKey("The Handmaid's Tale"), "handmaids-tale")
    }

    func testDifferentTitlesStillGetDifferentKeys() {
        // Guard against over-merging: distinct shows keep distinct keys.
        XCTAssertNotEqual(seriesKey("Avatar"), seriesKey("Avatar The Last Airbender"))
    }

    // MARK: - Embedded provider ids split a same-named different show

    func testEmbeddedProviderTagExtraction() {
        XCTAssertEqual(
            ShareMediaParser.embeddedProviderTag(relPath: "TV/One Piece (1999) [tvdb-81797]/One Piece - 009.mkv"),
            "tvdb-81797"
        )
        XCTAssertEqual(
            ShareMediaParser.embeddedProviderTag(relPath: "TV/Show {tmdb-1399}/Show.S01E01.mkv"),
            "tmdb-1399"
        )
        XCTAssertEqual(
            ShareMediaParser.embeddedProviderTag(relPath: "TV/Show [imdb-tt0944947]/Show.S01E01.mkv"),
            "imdb-tt0944947"
        )
        XCTAssertNil(ShareMediaParser.embeddedProviderTag(relPath: "TV/Plain Show/Plain.Show.S01E01.mkv"))
    }

    func testOnePieceAnimeAndLiveActionSplitByEmbeddedTvdbId() {
        // The anime folder carries an explicit [tvdb-81797]; the live-action reboot
        // does not. They must resolve to DIFFERENT series keys even though both
        // normalize to "One Piece".
        let anime = episode("Anime/One Piece (1999) [tvdb-81797]/One Piece - 009 - The Liar.mkv")
        let live = episode("TV/One Piece (2023)/One.Piece.2023.S01E01.mkv")
        XCTAssertEqual(anime?.series, "One Piece")
        XCTAssertEqual(anime?.providerTag, "tvdb-81797")
        XCTAssertNil(live?.providerTag)
        XCTAssertNotEqual(
            ShareCatalogID.seriesKey(fromTitle: anime?.series ?? "a", providerTag: anime?.providerTag),
            ShareCatalogID.seriesKey(fromTitle: live?.series ?? "b", providerTag: live?.providerTag)
        )
    }

    func testProviderTagKeyMatchesPlainKeyWhenAbsent() {
        // No tag → identical to the plain key, so ordinary shows are unaffected.
        XCTAssertEqual(
            ShareCatalogID.seriesKey(fromTitle: "Breaking Bad", providerTag: nil),
            ShareCatalogID.seriesKey(fromTitle: "Breaking Bad")
        )
    }
}
