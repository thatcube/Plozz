import XCTest
import CoreModels
@testable import MetadataKit

/// Coverage for picking the right title out of a TMDb search.
///
/// Worth pinning because the failure is silent: TMDb ranks by popularity, so a
/// modest title returns a more famous one containing the same words, and the
/// app then shows one film under another's name with nothing marking it a guess.
final class TMDbSearchMatchTests: XCTestCase {
    private func result(_ title: String, _ year: Int?) -> TMDbMetadataProvider.SearchResult {
        TMDbMetadataProvider.SearchResult(
            id: 1,
            poster_path: nil,
            title: title,
            name: nil,
            release_date: year.map { "\($0)-01-01" },
            first_air_date: nil,
            original_language: "en"
        )
    }

    private func query(_ title: String, year: Int?) -> MetadataQuery {
        MetadataQuery(
            contentType: .movie,
            kind: .movie,
            title: title,
            alternateTitle: nil,
            year: year,
            seasonNumber: nil,
            episodeNumber: nil,
            animeIDs: AnimeIDs(),
            providerIDs: [:]
        )
    }

    /// The case that shipped wrong: Emma Watson's The Circle opened Kingsman.
    func testExactTitleBeatsMorePopularSubstringMatch() {
        let results = [result("Kingsman: The Golden Circle", 2017), result("The Circle", 2017)]
        let best = TMDbMetadataProvider.bestMatch(
            for: query("The Circle", year: 2017), among: results
        )
        XCTAssertEqual(best?.displayTitle, "The Circle")
    }

    /// Two films of the same name: the year decides.
    func testYearDisambiguatesIdenticalTitles() {
        let results = [result("The Circle", 1939), result("The Circle", 2017)]
        let best = TMDbMetadataProvider.bestMatch(
            for: query("The Circle", year: 2017), among: results
        )
        XCTAssertEqual(best?.year, 2017)
    }

    /// No exact match is not a reason to return nothing — a server spelling a
    /// title differently is still usually asking for the popular one.
    func testFallsBackToProviderOrderWhenNothingMatchesExactly() {
        let results = [result("Kingsman: The Golden Circle", 2017)]
        let best = TMDbMetadataProvider.bestMatch(
            for: query("The Circle", year: 2017), among: results
        )
        XCTAssertEqual(best?.displayTitle, "Kingsman: The Golden Circle")
    }

    /// An exact match with a disagreeing year still beats a fuzzy one: sources
    /// disagree about years far more often than about titles.
    func testExactTitleWinsEvenWhenYearDisagrees() {
        let results = [result("Kingsman: The Golden Circle", 2017), result("The Circle", 2016)]
        let best = TMDbMetadataProvider.bestMatch(
            for: query("The Circle", year: 2017), among: results
        )
        XCTAssertEqual(best?.displayTitle, "The Circle")
    }

    func testOriginalLanguageIsNormalizedForPlayback() {
        XCTAssertEqual(
            TMDbMetadataProvider.normalizedLanguage(" EN "),
            "en"
        )
    }

    func testBlankOriginalLanguageIsUnknown() {
        XCTAssertNil(TMDbMetadataProvider.normalizedLanguage("  "))
        XCTAssertNil(TMDbMetadataProvider.normalizedLanguage(nil))
    }
}
