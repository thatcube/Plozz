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

    func testYearBearingSeriesFolderStillAcceptsBareEpisodeNumber() {
        let ep = episode("TV/Show (2024)/Show 01.mkv")
        XCTAssertEqual(ep?.series, "Show")
        XCTAssertEqual(ep?.season, 1)
        XCTAssertEqual(ep?.episode, 1)
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
}
