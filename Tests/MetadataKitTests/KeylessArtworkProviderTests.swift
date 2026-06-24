import XCTest
@testable import MetadataKit

final class KeylessArtworkProviderTests: XCTestCase {

    // MARK: - Wikidata: Commons URL building

    func testCommonsFileURLNormalizesSpacesAndEncodes() {
        let url = WikidataArtworkProvider.commonsFileURL("The Matrix poster.jpg", width: 1000)
        XCTAssertEqual(
            url?.absoluteString,
            "https://commons.wikimedia.org/wiki/Special:FilePath/The_Matrix_poster.jpg?width=1000"
        )
    }

    func testCommonsFileURLEncodesReservedCharacters() {
        let url = WikidataArtworkProvider.commonsFileURL("Amélie / poster #2.png", width: 800)
        let string = url?.absoluteString ?? ""
        XCTAssertTrue(string.hasPrefix("https://commons.wikimedia.org/wiki/Special:FilePath/"))
        XCTAssertTrue(string.hasSuffix("?width=800"))
        XCTAssertFalse(string.contains(" "), "spaces must be encoded/normalized")
        XCTAssertTrue(string.contains("%2F"), "slash must be percent-encoded so it can't split the path")
    }

    func testWidthPerKind() {
        XCTAssertEqual(WikidataArtworkProvider.width(for: .hero), 3840)
        XCTAssertEqual(WikidataArtworkProvider.width(for: .poster), 1000)
        XCTAssertEqual(WikidataArtworkProvider.width(for: .logo), 800)
    }

    // MARK: - Wikidata: hero landscape gating

    func testHeroGatingRejectsPortrait() {
        XCTAssertFalse(WikidataArtworkProvider.isUsableHero(width: 1000, height: 1500))
    }

    func testHeroGatingRejectsSmallLandscape() {
        XCTAssertFalse(WikidataArtworkProvider.isUsableHero(width: 800, height: 450))
    }

    func testHeroGatingAcceptsLargeLandscape() {
        XCTAssertTrue(WikidataArtworkProvider.isUsableHero(width: 1920, height: 1080))
    }

    func testHeroGatingRejectsZeroHeight() {
        XCTAssertFalse(WikidataArtworkProvider.isUsableHero(width: 1920, height: 0))
    }

    // MARK: - Wikidata: claim filename extraction

    func testFilenameExtractsImageClaim() throws {
        let json = """
        {"entities":{"Q83495":{"claims":{
          "P18":[{"mainsnak":{"datavalue":{"value":"The Matrix.jpg","type":"string"}}}],
          "P154":[{"mainsnak":{"datavalue":{"value":"The Matrix logo.svg","type":"string"}}}]
        }}}}
        """.data(using: .utf8)!
        let claims = try JSONDecoder().decode(WikidataArtworkProvider.ClaimsResponse.self, from: json)
        XCTAssertEqual(WikidataArtworkProvider.filename(in: claims, qid: "Q83495", property: "P18"), "The Matrix.jpg")
        XCTAssertEqual(WikidataArtworkProvider.filename(in: claims, qid: "Q83495", property: "P154"), "The Matrix logo.svg")
    }

    func testFilenameMissingPropertyReturnsNil() throws {
        let json = """
        {"entities":{"Q1":{"claims":{
          "P18":[{"mainsnak":{"datavalue":{"value":"X.jpg","type":"string"}}}]
        }}}}
        """.data(using: .utf8)!
        let claims = try JSONDecoder().decode(WikidataArtworkProvider.ClaimsResponse.self, from: json)
        XCTAssertNil(WikidataArtworkProvider.filename(in: claims, qid: "Q1", property: "P154"))
        XCTAssertNil(WikidataArtworkProvider.filename(in: claims, qid: "Qmissing", property: "P18"))
    }

    func testFilenameIgnoresNonStringClaimValues() throws {
        // A claim whose datavalue is an object (e.g. a wikibase-entityid) must not
        // crash decoding and must be skipped.
        let json = """
        {"entities":{"Q1":{"claims":{
          "P18":[{"mainsnak":{"datavalue":{"value":{"id":"Q42"},"type":"wikibase-entityid"}}}]
        }}}}
        """.data(using: .utf8)!
        let claims = try JSONDecoder().decode(WikidataArtworkProvider.ClaimsResponse.self, from: json)
        XCTAssertNil(WikidataArtworkProvider.filename(in: claims, qid: "Q1", property: "P18"))
    }

    func testSearchResponseDecodesQID() throws {
        let json = """
        {"query":{"search":[{"title":"Q83495"}]}}
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(WikidataArtworkProvider.SearchResponse.self, from: json)
        XCTAssertEqual(response.query?.search?.first?.title, "Q83495")
    }

    func testImageInfoDecodesSize() throws {
        let json = """
        {"query":{"pages":{"123":{"imageinfo":[{"width":1920,"height":1080}]}}}}
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(WikidataArtworkProvider.ImageInfoResponse.self, from: json)
        let info = response.query?.pages?.values.first?.imageinfo?.first
        XCTAssertEqual(info?.width, 1920)
        XCTAssertEqual(info?.height, 1080)
    }

    // MARK: - Wikipedia: search URL building

    func testWikipediaSearchURLMovieAddsYearAndFilmHint() {
        let url = WikipediaArtworkProvider.searchURL(title: "The Matrix", year: 1999, isTV: false)
        let string = url?.absoluteString ?? ""
        XCTAssertTrue(string.contains("generator=search"))
        XCTAssertTrue(string.contains("piprop=original"))
        XCTAssertTrue(string.contains("1999"))
        XCTAssertTrue(string.lowercased().contains("film"))
    }

    func testWikipediaSearchURLTVAddsSeriesHint() {
        let url = WikipediaArtworkProvider.searchURL(title: "Severance", year: nil, isTV: true)
        let string = (url?.absoluteString ?? "").lowercased()
        XCTAssertTrue(string.contains("television"))
    }

    func testWikipediaSearchURLEmptyTitleReturnsNil() {
        XCTAssertNil(WikipediaArtworkProvider.searchURL(title: "   ", year: nil, isTV: false))
    }

    // MARK: - Wikipedia: original-image parsing

    func testWikipediaParsesOriginalImage() throws {
        let json = """
        {"query":{"pages":{"42":{"original":{"source":"https://upload.wikimedia.org/x.jpg","width":1280,"height":720}}}}}
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(WikipediaArtworkProvider.QueryResponse.self, from: json)
        XCTAssertEqual(response.original?.source, "https://upload.wikimedia.org/x.jpg")
        XCTAssertEqual(response.original?.width, 1280)
        XCTAssertEqual(response.original?.height, 720)
    }

    func testWikipediaMissingOriginalReturnsNil() throws {
        let json = """
        {"query":{"pages":{"42":{}}}}
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(WikipediaArtworkProvider.QueryResponse.self, from: json)
        XCTAssertNil(response.original)
    }

    // MARK: - Wikipedia: QID (logo) resolution

    func testWikipediaQIDSearchURLRequestsWikibaseItem() {
        let url = WikipediaArtworkProvider.qidSearchURL(title: "Spirited Away", year: 2001, isTV: false)
        let string = (url?.absoluteString ?? "")
        XCTAssertTrue(string.contains("prop=pageprops"))
        XCTAssertTrue(string.contains("ppprop=wikibase_item"))
        XCTAssertTrue(string.contains("generator=search"))
        XCTAssertTrue(string.lowercased().contains("film"))
    }

    func testWikipediaSearchTermSharedByImageAndQIDQueries() {
        XCTAssertEqual(
            WikipediaArtworkProvider.searchTerm(title: "Severance", year: nil, isTV: true),
            "Severance television series"
        )
        XCTAssertEqual(
            WikipediaArtworkProvider.searchTerm(title: "The Matrix", year: 1999, isTV: false),
            "The Matrix 1999 film"
        )
        XCTAssertNil(WikipediaArtworkProvider.searchTerm(title: "  ", year: nil, isTV: false))
    }

    func testWikipediaPagePropsDecodesWikibaseItem() throws {
        let json = """
        {"query":{"pages":{"42":{"pageprops":{"wikibase_item":"Q83495"}}}}}
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(WikipediaArtworkProvider.PagePropsResponse.self, from: json)
        XCTAssertEqual(response.wikibaseItem, "Q83495")
    }

    func testWikipediaPagePropsMissingReturnsNil() throws {
        let json = """
        {"query":{"pages":{"42":{}}}}
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(WikipediaArtworkProvider.PagePropsResponse.self, from: json)
        XCTAssertNil(response.wikibaseItem)
    }

    // MARK: - Wikidata: language-aware logo claim parsing

    func testDataValueDecodesEntityID() throws {
        let json = """
        {"entities":{"Q1":{"claims":{
          "P364":[{"mainsnak":{"datavalue":{"value":{"entity-type":"item","numeric-id":1860,"id":"Q1860"},"type":"wikibase-entityid"}}}]
        }}}}
        """.data(using: .utf8)!
        let claims = try JSONDecoder().decode(WikidataArtworkProvider.ClaimsResponse.self, from: json)
        XCTAssertEqual(WikidataArtworkProvider.originalLanguages(in: claims, qid: "Q1"), ["Q1860"])
    }

    func testLogoCandidatesParseLanguageQualifiers() throws {
        let json = """
        {"entities":{"Q1":{"claims":{
          "P154":[
            {"mainsnak":{"datavalue":{"value":"English logo.svg","type":"string"}},
             "qualifiers":{"P407":[{"datavalue":{"value":{"id":"Q1860"},"type":"wikibase-entityid"}}]}},
            {"mainsnak":{"datavalue":{"value":"Japanese logo.svg","type":"string"}},
             "qualifiers":{"P407":[{"datavalue":{"value":{"id":"Q5287"},"type":"wikibase-entityid"}}]}},
            {"mainsnak":{"datavalue":{"value":"Untagged logo.svg","type":"string"}}}
          ]
        }}}}
        """.data(using: .utf8)!
        let claims = try JSONDecoder().decode(WikidataArtworkProvider.ClaimsResponse.self, from: json)
        let candidates = WikidataArtworkProvider.logoCandidates(in: claims, qid: "Q1")
        XCTAssertEqual(candidates.count, 3)
        XCTAssertEqual(candidates[0], .init(file: "English logo.svg", languages: ["Q1860"]))
        XCTAssertEqual(candidates[1], .init(file: "Japanese logo.svg", languages: ["Q5287"]))
        XCTAssertEqual(candidates[2], .init(file: "Untagged logo.svg", languages: []))
    }

    // MARK: - Wikidata: kind-aware logo selection policy

    private typealias Candidate = WikidataArtworkProvider.LogoCandidate

    func testSelectLogoPrefersEnglishForNonAnime() {
        let candidates = [
            Candidate(file: "jp.svg", languages: ["Q5287"]),
            Candidate(file: "en.svg", languages: ["Q1860"])
        ]
        XCTAssertEqual(
            WikidataArtworkProvider.selectLogoFilename(candidates: candidates, originalLanguages: ["Q5287"], isAnime: false),
            "en.svg"
        )
    }

    func testSelectLogoRejectsForeignOnlyForNonAnime() {
        let candidates = [Candidate(file: "jp.svg", languages: ["Q5287"])]
        XCTAssertNil(
            WikidataArtworkProvider.selectLogoFilename(candidates: candidates, originalLanguages: ["Q5287"], isAnime: false),
            "an unreadable foreign logo must fall through to the text title"
        )
    }

    func testSelectLogoAnimeAcceptsAnyLanguage() {
        let candidates = [Candidate(file: "jp.svg", languages: ["Q5287"])]
        XCTAssertEqual(
            WikidataArtworkProvider.selectLogoFilename(candidates: candidates, originalLanguages: ["Q5287"], isAnime: true),
            "jp.svg",
            "for anime, any logo beats no title art"
        )
    }

    func testSelectLogoUntaggedAcceptedForEnglishOriginWork() {
        let candidates = [Candidate(file: "logo.svg", languages: [])]
        XCTAssertEqual(
            WikidataArtworkProvider.selectLogoFilename(candidates: candidates, originalLanguages: ["Q1860"], isAnime: false),
            "logo.svg"
        )
    }

    func testSelectLogoUntaggedAcceptedWhenWorkLanguageUnknown() {
        let candidates = [Candidate(file: "logo.svg", languages: [])]
        XCTAssertEqual(
            WikidataArtworkProvider.selectLogoFilename(candidates: candidates, originalLanguages: [], isAnime: false),
            "logo.svg"
        )
    }

    func testSelectLogoUntaggedRejectedForForeignOriginNonAnime() {
        let candidates = [Candidate(file: "logo.svg", languages: [])]
        XCTAssertNil(
            WikidataArtworkProvider.selectLogoFilename(candidates: candidates, originalLanguages: ["Q150"], isAnime: false),
            "an untagged logo on a foreign-origin work is assumed unreadable"
        )
    }

    func testSelectLogoEmptyCandidatesReturnsNil() {
        XCTAssertNil(
            WikidataArtworkProvider.selectLogoFilename(candidates: [], originalLanguages: [], isAnime: true)
        )
    }
}
