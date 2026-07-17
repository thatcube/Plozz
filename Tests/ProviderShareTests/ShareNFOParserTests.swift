import XCTest
@testable import ProviderShare

/// Coverage for `ShareNFOParser`: bounded, tolerant, safe parsing of Kodi/
/// Jellyfin `movie`/`tvshow`/`episodedetails` NFO documents. No storage/
/// transport is involved here — pure in-memory `Data` in, `NFOParseOutcome` out.
final class ShareNFOParserTests: XCTestCase {
    private func parse(_ xml: String) -> NFOParseOutcome {
        ShareNFOParser.parse(Data(xml.utf8))
    }

    private func parsed(_ xml: String, file: StaticString = #filePath, line: UInt = #line) -> ParsedNFO {
        guard case .parsed(let value) = parse(xml) else {
            XCTFail("expected a parsed document", file: file, line: line)
            return ParsedNFO(root: .movie)
        }
        return value
    }

    // MARK: - Roots

    func testParsesMovieRoot() {
        let doc = parsed("<movie><title>Everything Everywhere</title></movie>")
        XCTAssertEqual(doc.root, .movie)
        XCTAssertEqual(doc.title, "Everything Everywhere")
    }

    func testParsesTVShowRoot() {
        let doc = parsed("<tvshow><title>Arcane</title></tvshow>")
        XCTAssertEqual(doc.root, .tvshow)
    }

    func testParsesEpisodeDetailsRoot() {
        let doc = parsed("<episodedetails><title>Pilot</title><season>1</season><episode>1</episode></episodedetails>")
        XCTAssertEqual(doc.root, .episodedetails)
        XCTAssertEqual(doc.season, 1)
        XCTAssertEqual(doc.episode, 1)
    }

    func testUnknownRootIsMalformed() {
        XCTAssertEqual(parse("<musicvideo><title>x</title></musicvideo>"), .malformed)
    }

    // MARK: - Every requested scalar/list field

    func testParsesEveryScalarAndListField() {
        let xml = """
        <movie>
          <title>Arrival</title>
          <originaltitle>Story of Your Life</originaltitle>
          <sorttitle>arrival</sorttitle>
          <year>2016</year>
          <tagline>Why are they here?</tagline>
          <plot>A linguist deciphers alien language.</plot>
          <genre>Drama</genre>
          <genre>Sci-Fi</genre>
          <studio>Paramount</studio>
          <studio>FilmNation</studio>
          <tag>First Contact</tag>
          <runtime>116</runtime>
          <premiered>2016-11-11</premiered>
        </movie>
        """
        let doc = parsed(xml)
        XCTAssertEqual(doc.title, "Arrival")
        XCTAssertEqual(doc.originalTitle, "Story of Your Life")
        XCTAssertEqual(doc.sortTitle, "arrival")
        XCTAssertEqual(doc.year, 2016)
        XCTAssertEqual(doc.taglines, ["Why are they here?"])
        XCTAssertEqual(doc.overview, "A linguist deciphers alien language.")
        XCTAssertEqual(doc.genres, ["Drama", "Sci-Fi"])
        XCTAssertEqual(doc.studios, ["Paramount", "FilmNation"])
        XCTAssertEqual(doc.tags, ["First Contact"])
        XCTAssertEqual(doc.runtimeSeconds, 116 * 60)
        XCTAssertEqual(doc.premiered, "2016-11-11")
    }

    func testAiredAndRuntimeHHMMForm() {
        let doc = parsed("<episodedetails><aired>2011-04-17</aired><runtime>0:55</runtime></episodedetails>")
        XCTAssertEqual(doc.aired, "2011-04-17")
        XCTAssertEqual(doc.runtimeSeconds, 55 * 60)
    }

    func testInvalidDateOmitted() {
        let doc = parsed("<movie><premiered>not-a-date</premiered><aired>2024-13-40</aired></movie>")
        XCTAssertNil(doc.premiered)
        XCTAssertNil(doc.aired)
    }

    func testInvalidRuntimeOmitted() {
        let doc = parsed("<movie><runtime>-5</runtime></movie>")
        XCTAssertNil(doc.runtimeSeconds)
    }

    // MARK: - Plot-over-outline fallback

    func testPlotWinsOverOutline() {
        let doc = parsed("<movie><plot>Full plot.</plot><outline>Short.</outline></movie>")
        XCTAssertEqual(doc.overview, "Full plot.")
    }

    func testOutlineFallsBackWhenPlotAbsent() {
        let doc = parsed("<movie><outline>Short.</outline></movie>")
        XCTAssertEqual(doc.overview, "Short.")
    }

    func testBlankPlotFallsBackToOutline() {
        let doc = parsed("<movie><plot></plot><outline>Short.</outline></movie>")
        XCTAssertEqual(doc.overview, "Short.")
    }

    // MARK: - Repeated genres/studios/tags de-duplication

    func testRepeatedGenresDeduplicateCaseInsensitively() {
        let doc = parsed("<movie><genre>Drama</genre><genre>drama</genre><genre>Comedy</genre></movie>")
        XCTAssertEqual(doc.genres, ["Drama", "Comedy"])
    }

    // MARK: - IDs: uniqueid namespaces, defaults, aliases, invalid, unknown

    func testDirectIDElements() {
        let doc = parsed("<movie><imdbid>tt1234567</imdbid><tmdbid>27205</tmdbid><tvdbid>81797</tvdbid></movie>")
        let byNamespace = Dictionary(uniqueKeysWithValues: doc.ids.map { ($0.rawNamespace, $0.rawValue) })
        XCTAssertEqual(byNamespace["imdb"], "tt1234567")
        XCTAssertEqual(byNamespace["tmdb"], "27205")
        XCTAssertEqual(byNamespace["tvdb"], "81797")
    }

    func testInvalidDirectIDElementsOmitted() {
        let doc = parsed("<movie><imdbid>notanid</imdbid><tmdbid>-5</tmdbid></movie>")
        XCTAssertTrue(doc.ids.isEmpty)
    }

    func testMultipleUniqueIDNamespacesAndDefaultTieBreak() {
        let xml = """
        <tvshow>
          <uniqueid type="tvdb">81797</uniqueid>
          <uniqueid type="imdb" default="true">tt1234567</uniqueid>
          <uniqueid type="anidb">69</uniqueid>
        </tvshow>
        """
        let doc = parsed(xml)
        XCTAssertEqual(doc.ids.count, 3)
        let imdb = doc.ids.first { $0.rawNamespace == "imdb" }
        XCTAssertEqual(imdb?.isDefault, true)
        XCTAssertEqual(doc.ids.first { $0.rawNamespace == "tvdb" }?.rawValue, "81797")
        XCTAssertEqual(doc.ids.first { $0.rawNamespace == "anidb" }?.rawValue, "69")
    }

    func testUnknownForwardCompatibleNamespacePersistsRaw() {
        let doc = parsed("<movie><uniqueid type=\"letterboxd\">abc123</uniqueid></movie>")
        XCTAssertEqual(doc.ids.first?.rawNamespace, "letterboxd")
        XCTAssertEqual(doc.ids.first?.rawValue, "abc123")
    }

    // MARK: - Ratings: scalar + nested, 10/100/5 scales

    func testScalarRatingWithVotesDefaultsToIMDbStyle() {
        let doc = parsed("<movie><rating>8.8</rating><votes>200000</votes></movie>")
        XCTAssertEqual(doc.ratings.count, 1)
        XCTAssertEqual(doc.ratings.first?.source, "imdb")
        XCTAssertEqual(doc.ratings.first?.value, 8.8)
        XCTAssertEqual(doc.ratings.first?.max, 10)
        XCTAssertEqual(doc.ratings.first?.votes, 200_000)
    }

    func testNestedRatingsBlockMultipleScales() {
        let xml = """
        <movie>
          <ratings>
            <rating name="imdb" max="10" default="true">
              <value>8.8</value>
              <votes>200000</votes>
            </rating>
            <rating name="metacritic" max="100">
              <value>82</value>
            </rating>
            <rating name="letterboxd" max="5">
              <value>4.1</value>
            </rating>
          </ratings>
        </movie>
        """
        let doc = parsed(xml)
        XCTAssertEqual(doc.ratings.count, 3)
        let imdb = doc.ratings.first { $0.source == "imdb" }
        XCTAssertEqual(imdb?.value, 8.8)
        XCTAssertEqual(imdb?.max, 10)
        XCTAssertEqual(imdb?.isDefault, true)
        XCTAssertEqual(imdb?.votes, 200_000)
        XCTAssertEqual(doc.ratings.first { $0.source == "metacritic" }?.max, 100)
        XCTAssertEqual(doc.ratings.first { $0.source == "letterboxd" }?.max, 5)
    }

    func testUnknownRatingSourceLosslesslyPersisted() {
        let xml = """
        <movie><ratings><rating name="trakt" max="10"><value>7.2</value><votes>42</votes></rating></ratings></movie>
        """
        let doc = parsed(xml)
        XCTAssertEqual(doc.ratings.first?.source, "trakt")
        XCTAssertEqual(doc.ratings.first?.value, 7.2)
        XCTAssertEqual(doc.ratings.first?.votes, 42)
    }

    func testIncoherentRatingValueAboveMaxOmitted() {
        let xml = "<movie><ratings><rating name=\"imdb\" max=\"10\"><value>99</value></rating></ratings></movie>"
        let doc = parsed(xml)
        XCTAssertTrue(doc.ratings.isEmpty)
    }

    // MARK: - Malformed XML fails safely

    func testMalformedXMLFailsSafely() {
        XCTAssertEqual(parse("<movie><title>Unterminated</movie>"), .malformed)
    }

    func testEmptyDataIsMalformed() {
        XCTAssertEqual(parse(""), .malformed)
    }

    // MARK: - Unknown elements/namespaces/casing tolerance

    func testUnknownElementsIgnoredWithoutFailingDocument() {
        let doc = parsed("<movie><title>Ok</title><unknownelement>junk</unknownelement></movie>")
        XCTAssertEqual(doc.title, "Ok")
    }

    func testCaseInsensitiveElementNames() {
        let doc = parsed("<MOVIE><TITLE>Ok</TITLE></MOVIE>")
        XCTAssertEqual(doc.root, .movie)
        XCTAssertEqual(doc.title, "Ok")
    }

    func testNamespacedElementsTolerated() {
        let doc = parsed("<movie xmlns:kodi=\"urn:kodi\"><kodi:title>Ok</kodi:title></movie>")
        XCTAssertEqual(doc.title, "Ok")
    }

    // MARK: - Security: no external entity/DTD/XXE resolution, no network

    func testExternalEntityPayloadNeverResolvesAndFailsSafely() {
        let xml = """
        <?xml version="1.0"?>
        <!DOCTYPE movie [
          <!ENTITY xxe SYSTEM "file:///etc/passwd">
        ]>
        <movie><title>&xxe;</title></movie>
        """
        // Whether XMLParser accepts or rejects the DTD-bearing document, the
        // external entity must NEVER be resolved into the title.
        if case .parsed(let doc) = parse(xml) {
            XCTAssertNotEqual(doc.title, "&xxe;")
            XCTAssertFalse(doc.title?.contains("root:") ?? false, "must never read /etc/passwd")
        }
    }

    func testRemoteDTDNeverFetched() {
        let xml = """
        <?xml version="1.0"?>
        <!DOCTYPE movie SYSTEM "http://example.invalid/evil.dtd">
        <movie><title>Ok</title></movie>
        """
        // Must not hang or crash attempting network access; any outcome (parsed
        // or malformed) is acceptable as long as it returns promptly.
        _ = parse(xml)
    }

    // MARK: - Size bounds

    func testExactlyMaxBytesAccepted() {
        let prefix = "<movie><plot>"
        let suffix = "</plot></movie>"
        let padLength = ShareNFOParser.maxBytes - prefix.utf8.count - suffix.utf8.count
        let xml = prefix + String(repeating: "a", count: padLength) + suffix
        let data = Data(xml.utf8)
        XCTAssertEqual(data.count, ShareNFOParser.maxBytes)
        if case .oversized = ShareNFOParser.parse(data) {
            XCTFail("exactly maxBytes must be accepted, not rejected as oversized")
        }
    }

    func testMoreThanMaxBytesRejected() {
        let oversized = Data(repeating: 0x61, count: ShareNFOParser.maxBytes + 1)
        XCTAssertEqual(ShareNFOParser.parse(oversized), .oversized)
    }

    func testHugeRuntimeDoesNotOverflow() throws {
        let document = try parsed(
            "<movie><runtime>9223372036854775807:00</runtime></movie>"
        )
        XCTAssertNil(document.runtimeSeconds)
    }

    // MARK: - Bounded text/list behavior

    func testAccumulatedTextIsBounded() {
        let huge = String(repeating: "x", count: ShareNFOParser.maxElementTextLength + 5_000)
        let doc = parsed("<movie><plot>\(huge)</plot></movie>")
        XCTAssertLessThanOrEqual(doc.overview?.count ?? 0, ShareNFOParser.maxElementTextLength)
    }

    func testRepeatedListIsBounded() {
        let genres = (0..<(ShareNFOParser.maxListEntries + 50)).map { "<genre>Genre\($0)</genre>" }.joined()
        let doc = parsed("<movie>\(genres)</movie>")
        XCTAssertLessThanOrEqual(doc.genres.count, ShareNFOParser.maxListEntries)
    }
}
