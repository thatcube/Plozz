import XCTest
@testable import CoreModels

final class ExternalRatingTests: XCTestCase {
    // MARK: Normalization

    func testNormalizedOutOfTen() {
        let rating = ExternalRating(source: .imdb, value: 8.8, scale: .outOfTen)
        XCTAssertEqual(rating.normalized, 0.88, accuracy: 0.0001)
    }

    func testNormalizedPercent() {
        let rating = ExternalRating(source: .rottenTomatoes, value: 74, scale: .percent)
        XCTAssertEqual(rating.normalized, 0.74, accuracy: 0.0001)
    }

    func testNormalizedOutOfHundred() {
        let rating = ExternalRating(source: .metacritic, value: 74, scale: .outOfHundred)
        XCTAssertEqual(rating.normalized, 0.74, accuracy: 0.0001)
    }

    func testNormalizedOutOfFive() {
        let rating = ExternalRating(source: .letterboxd, value: 4.1, scale: .outOfFive)
        XCTAssertEqual(rating.normalized, 0.82, accuracy: 0.0001)
    }

    func testNormalizedClampsAboveMaximum() {
        let rating = ExternalRating(source: .imdb, value: 12, scale: .outOfTen)
        XCTAssertEqual(rating.normalized, 1.0, accuracy: 0.0001)
    }

    // MARK: Display formatting

    func testDisplayValueOutOfTenTrimsWholeNumbers() {
        XCTAssertEqual(ExternalRating(source: .imdb, value: 8.0, scale: .outOfTen).displayValue, "8")
        XCTAssertEqual(ExternalRating(source: .imdb, value: 8.8, scale: .outOfTen).displayValue, "8.8")
    }

    func testDisplayValuePercent() {
        XCTAssertEqual(ExternalRating(source: .rottenTomatoes, value: 74, scale: .percent).displayValue, "74%")
    }

    func testDisplayValueOutOfHundred() {
        XCTAssertEqual(ExternalRating(source: .metacritic, value: 74, scale: .outOfHundred).displayValue, "74/100")
    }

    func testDisplayValueOutOfFive() {
        XCTAssertEqual(ExternalRating(source: .letterboxd, value: 4.1, scale: .outOfFive).displayValue, "4.1/5")
    }

    // MARK: Iconography & freshness

    func testIcons() {
        XCTAssertEqual(RatingSource.rottenTomatoes.icon, .tomato)
        XCTAssertEqual(RatingSource.critic.icon, .tomato)
        XCTAssertEqual(RatingSource.rottenTomatoesAudience.icon, .popcorn)
        XCTAssertEqual(RatingSource.imdb.icon, .star)
        XCTAssertEqual(RatingSource.tmdb.icon, .tmdb)
        XCTAssertEqual(RatingSource.community.icon, .star)
        XCTAssertEqual(RatingSource.metacritic.icon, .metacritic)
    }

    func testFreshnessFreshAtThreshold() {
        XCTAssertEqual(ExternalRating(source: .rottenTomatoes, value: 60, scale: .percent).freshness, .fresh)
        XCTAssertEqual(ExternalRating(source: .rottenTomatoes, value: 89, scale: .percent).freshness, .fresh)
    }

    func testFreshnessRottenBelowThreshold() {
        XCTAssertEqual(ExternalRating(source: .rottenTomatoes, value: 42, scale: .percent).freshness, .rotten)
    }

    func testFreshnessNoneForNonFreshnessSources() {
        XCTAssertEqual(ExternalRating(source: .imdb, value: 9, scale: .outOfTen).freshness, .none)
        XCTAssertEqual(ExternalRating(source: .metacritic, value: 90, scale: .outOfHundred).freshness, .none)
    }

    // MARK: OMDb value parsing

    func testParseOMDbOutOfTen() {
        let rating = ExternalRating.parseOMDb(source: .imdb, value: "8.8/10")
        XCTAssertEqual(rating?.value, 8.8)
        XCTAssertEqual(rating?.scale, .outOfTen)
    }

    func testParseOMDbPercent() {
        let rating = ExternalRating.parseOMDb(source: .rottenTomatoes, value: "74%")
        XCTAssertEqual(rating?.value, 74)
        XCTAssertEqual(rating?.scale, .percent)
    }

    func testParseOMDbOutOfHundred() {
        let rating = ExternalRating.parseOMDb(source: .metacritic, value: "74/100")
        XCTAssertEqual(rating?.value, 74)
        XCTAssertEqual(rating?.scale, .outOfHundred)
    }

    func testParseOMDbBarePlainNumberAssumesOutOfTen() {
        let rating = ExternalRating.parseOMDb(source: .imdb, value: "8.8")
        XCTAssertEqual(rating?.value, 8.8)
        XCTAssertEqual(rating?.scale, .outOfTen)
    }

    func testParseOMDbRejectsGarbage() {
        XCTAssertNil(ExternalRating.parseOMDb(source: .imdb, value: "N/A"))
        XCTAssertNil(ExternalRating.parseOMDb(source: .imdb, value: ""))
    }

    // MARK: Merge

    func testMergeAuthoritativeReplacesSameSourceAndSorts() {
        let native = [
            ExternalRating(source: .community, value: 7.2, scale: .outOfTen),
            ExternalRating(source: .rottenTomatoes, value: 50, scale: .percent)
        ]
        let authoritative = [
            ExternalRating(source: .imdb, value: 8.8, scale: .outOfTen),
            ExternalRating(source: .rottenTomatoes, value: 74, scale: .percent),
            ExternalRating(source: .metacritic, value: 74, scale: .outOfHundred)
        ]
        let merged = native.mergedWithAuthoritative(authoritative)

        // Authoritative RT overrides the native one.
        let rt = merged.first { $0.source == .rottenTomatoes }
        XCTAssertEqual(rt?.value, 74)
        // Native-only source is preserved.
        XCTAssertTrue(merged.contains { $0.source == .community })
        // Ordered by sortRank: imdb, rottenTomatoes, metacritic, community.
        XCTAssertEqual(merged.map(\.source), [.imdb, .rottenTomatoes, .metacritic, .community])
    }
}
