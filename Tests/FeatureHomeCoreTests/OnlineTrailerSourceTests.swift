import XCTest
import CoreModels
@testable import FeatureHomeCore

final class OnlineTrailerSourceTests: XCTestCase {

    // MARK: - Query selection

    func testQueryForMovieIncludesYear() {
        let movie = MediaItem(id: "m", title: "Dune", kind: .movie, productionYear: 2021)
        let q = OnlineTrailerSource.query(for: movie)
        XCTAssertEqual(q?.title, "Dune")
        XCTAssertEqual(q?.year, 2021)
        XCTAssertEqual(q?.isTV, false)
    }

    func testQueryForSeriesDropsYear() {
        let series = MediaItem(id: "s", title: "Severance", kind: .series, productionYear: 2022)
        let q = OnlineTrailerSource.query(for: series)
        XCTAssertEqual(q?.isTV, true)
        XCTAssertNil(q?.year)
    }

    func testQueryNilForSeasonsAndEpisodes() {
        XCTAssertNil(OnlineTrailerSource.query(for: MediaItem(id: "x", title: "S1", kind: .season)))
        XCTAssertNil(OnlineTrailerSource.query(for: MediaItem(id: "x", title: "E1", kind: .episode)))
    }

    func testSearchQueryStrings() {
        XCTAssertEqual(
            OnlineTrailerSource.searchQuery(title: "Dune", year: 2021, isTV: false),
            "Dune 2021 official trailer"
        )
        XCTAssertEqual(
            OnlineTrailerSource.searchQuery(title: "Severance", year: nil, isTV: true),
            "Severance official trailer"
        )
    }

    // MARK: - Ranking

    private func r(_ id: String, _ title: String, author: String = "") -> OnlineTrailerSource.SearchResult {
        OnlineTrailerSource.SearchResult(videoID: id, title: title, author: author)
    }

    func testPrefersOfficialTrailer() {
        let results = [
            r("teaser", "Dune | Official Teaser"),
            r("clip", "Dune trailer scene breakdown"),
            r("official", "Dune | Official Trailer")
        ]
        XCTAssertEqual(OnlineTrailerSource.bestVideoID(from: results, title: "Dune", year: 2021), "official")
    }

    func testRejectsReactionsAndReviews() {
        let results = [
            r("react", "Dune Official Trailer REACTION"),
            r("review", "Dune trailer review and breakdown")
        ]
        XCTAssertNil(OnlineTrailerSource.bestVideoID(from: results, title: "Dune", year: 2021))
    }

    func testRequiresTrailerWord() {
        let results = [r("scene", "Dune best scene")]
        XCTAssertNil(OnlineTrailerSource.bestVideoID(from: results, title: "Dune", year: 2021))
    }

    func testRequiresTitleOverlap() {
        // A trailer for a different movie shouldn't be surfaced.
        let results = [r("other", "Oppenheimer | Official Trailer")]
        XCTAssertNil(OnlineTrailerSource.bestVideoID(from: results, title: "Dune", year: 2021))
    }

    func testYearBoostsTie() {
        let results = [
            r("noyear", "Dune Official Trailer"),
            r("withyear", "Dune Official Trailer (2021)")
        ]
        XCTAssertEqual(OnlineTrailerSource.bestVideoID(from: results, title: "Dune", year: 2021), "withyear")
    }

    func testTokenizeDropsStopwordsAndPunctuation() {
        XCTAssertEqual(
            OnlineTrailerSource.tokenize("The Lord of the Rings: Official Trailer!"),
            ["lord", "rings"]
        )
    }

    // MARK: - Parsing

    func testParseInvidiousFiltersToVideos() {
        let json = """
        [
          {"type":"video","videoId":"aaaaaaaaaaa","title":"Dune Trailer","author":"Warner"},
          {"type":"channel","title":"Some Channel"},
          {"type":"video","videoId":"","title":"empty id"}
        ]
        """.data(using: .utf8)!
        let parsed = OnlineTrailerSource.parseInvidious(json)
        XCTAssertEqual(parsed?.count, 1)
        XCTAssertEqual(parsed?.first?.videoID, "aaaaaaaaaaa")
    }

    func testParsePipedExtractsVideoID() {
        let json = """
        {"items":[
          {"url":"/watch?v=dQw4w9WgXcQ","title":"Dune Official Trailer","uploaderName":"Warner Bros."}
        ]}
        """.data(using: .utf8)!
        let parsed = OnlineTrailerSource.parsePiped(json)
        XCTAssertEqual(parsed?.first?.videoID, "dQw4w9WgXcQ")
        XCTAssertEqual(parsed?.first?.author, "Warner Bros.")
    }

    // MARK: - End-to-end with injected fetcher

    func testTrailersReturnsMarkedYouTubeItem() async {
        let payload = """
        [{"type":"video","videoId":"dQw4w9WgXcQ","title":"Dune | Official Trailer","author":"Warner"}]
        """.data(using: .utf8)!
        let fetch: OnlineTrailerSource.Fetcher = { _ in payload }
        let movie = MediaItem(id: "m", title: "Dune", kind: .movie, productionYear: 2021)

        // youtubeFetch returns nil so the chain falls through to the injected
        // Invidious fetcher.
        let trailers = await OnlineTrailerSource.trailers(
            for: movie, fetch: fetch, youtubeFetch: { _ in nil }
        )
        XCTAssertEqual(trailers.count, 1)
        XCTAssertEqual(trailers.first?.youTubeTrailerVideoID, "dQw4w9WgXcQ")
        XCTAssertEqual(trailers.first?.parentTitle, "Dune")
    }

    func testTrailersEmptyWhenNothingFound() async {
        let fetch: OnlineTrailerSource.Fetcher = { _ in "[]".data(using: .utf8) }
        let movie = MediaItem(id: "m", title: "Dune", kind: .movie, productionYear: 2021)
        let trailers = await OnlineTrailerSource.trailers(
            for: movie, fetch: fetch, youtubeFetch: { _ in nil }
        )
        XCTAssertTrue(trailers.isEmpty)
    }

    func testTrailersPrefersYouTubeSourceFirst() async {
        // YouTube HTML yields a match → the Invidious fetcher must never be used.
        let youtubeHTML = """
        var ytInitialData = {"videoRenderer":{"videoId":"ytaaaaaaaaa","title":{"runs":[{"text":"Dune | Official Trailer"}]}}};
        """.data(using: .utf8)!
        let invidious = """
        [{"type":"video","videoId":"invaaaaaaaa","title":"Dune | Official Trailer","author":"Warner"}]
        """.data(using: .utf8)!
        let movie = MediaItem(id: "m", title: "Dune", kind: .movie, productionYear: 2021)

        let trailers = await OnlineTrailerSource.trailers(
            for: movie,
            fetch: { _ in invidious },
            youtubeFetch: { _ in youtubeHTML }
        )
        XCTAssertEqual(trailers.first?.youTubeTrailerVideoID, "ytaaaaaaaaa")
    }

    func testTrailersReturnsMultipleRankedCandidates() async {
        // Two valid trailer candidates → both surface, best first, capped by limit.
        let youtubeHTML = """
        {"videoRenderer":{"videoId":"officialaaa","title":{"runs":[{"text":"Dune | Official Trailer"}]}}}
        {"videoRenderer":{"videoId":"teaseraaaaa","title":{"runs":[{"text":"Dune | Official Teaser"}]}}}
        """.data(using: .utf8)!
        let movie = MediaItem(id: "m", title: "Dune", kind: .movie, productionYear: 2021)

        let trailers = await OnlineTrailerSource.trailers(
            for: movie, limit: 5,
            fetch: { _ in nil }, youtubeFetch: { _ in youtubeHTML }
        )
        XCTAssertEqual(trailers.map(\.youTubeTrailerVideoID), ["officialaaa", "teaseraaaaa"])
    }

    // MARK: - YouTube HTML parsing

    func testParseYouTubeExtractsOrderedVideoIDs() {
        let html = """
        garbage {"videoRenderer":{"videoId":"aaaaaaaaaaa","title":{"runs":[{"text":"Dune | Official Trailer"}]}}}
        more {"videoRenderer":{"videoId":"bbbbbbbbbbb","title":{"runs":[{"text":"Dune Teaser"}]}}}
        """.data(using: .utf8)!
        let parsed = OnlineTrailerSource.parseYouTube(html)
        XCTAssertEqual(parsed?.map(\.videoID), ["aaaaaaaaaaa", "bbbbbbbbbbb"])
        XCTAssertEqual(parsed?.first?.title, "Dune | Official Trailer")
    }

    func testParseYouTubeDecodesEscapesAndDedupes() {
        let html = """
        {"videoRenderer":{"videoId":"ccccccccccc","title":{"runs":[{"text":"Spider-Man: \\u0026 Friends"}]}}}
        {"videoRenderer":{"videoId":"ccccccccccc","title":{"runs":[{"text":"dup"}]}}}
        """.data(using: .utf8)!
        let parsed = OnlineTrailerSource.parseYouTube(html)
        XCTAssertEqual(parsed?.count, 1)
        XCTAssertEqual(parsed?.first?.title, "Spider-Man: & Friends")
    }

    func testParseYouTubeReturnsNilWhenNoRenderers() {
        let html = "<html>consent interstitial, no data</html>".data(using: .utf8)!
        XCTAssertNil(OnlineTrailerSource.parseYouTube(html))
    }

    func testBestVideoIDsRanksAndCaps() {
        let results = [
            r("teaser", "Dune | Official Teaser"),
            r("junk", "random unrelated clip"),
            r("official", "Dune | Official Trailer")
        ]
        let ids = OnlineTrailerSource.bestVideoIDs(from: results, title: "Dune", year: 2021, limit: 2)
        XCTAssertEqual(ids, ["official", "teaser"])
    }
}
