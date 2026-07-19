import XCTest
import CoreModels
@testable import MetadataKit

final class MetadataEnrichmentConfigTests: XCTestCase {
    private func makeQuery(_ type: ContentType) -> MetadataQuery {
        MetadataQuery(
            contentType: type,
            kind: type == .movie ? .movie : .series,
            title: "Test",
            alternateTitle: nil,
            year: 2020,
            seasonNumber: nil,
            episodeNumber: nil,
            animeIDs: AnimeIDs(),
            providerIDs: [:]
        )
    }

    func testDefaultPolicyOrdersMoviePoster() {
        // The Step 3 movie-poster table leads with tmdb then tvdb.
        let config = MetadataEnrichmentConfig()
        let order = config.orderedSources(for: .posterURL, query: makeQuery(.movie))
        XCTAssertEqual(order.first, .tmdb)
        XCTAssertTrue(order.contains(.tvdb))
    }

    func testDefaultPolicyOrdersAnimePosterAniListFirst() {
        let config = MetadataEnrichmentConfig()
        let order = config.orderedSources(for: .posterURL, query: makeQuery(.anime))
        XCTAssertEqual(order.first, .anilist)
    }

    func testHomeHeroAndDetailBackdropShareTheHeroChain() {
        let config = MetadataEnrichmentConfig()
        let query = makeQuery(.tvShow)
        let hero = config.orderedSources(for: .homeHero, query: query)
        let detail = config.orderedSources(for: .detailBackdrop, query: query)
        let backdrop = config.orderedSources(for: .backdropURL, query: query)
        XCTAssertEqual(hero, detail)
        XCTAssertEqual(hero, backdrop)
        XCTAssertEqual(hero.first, .tvdb, "TV hero chain leads with TheTVDB backdrop")
    }

    func testDisabledRoleRemovesSourceEverywhere() {
        let config = MetadataEnrichmentConfig(roles: [.tmdb: .disabled])
        let order = config.orderedSources(for: .posterURL, query: makeQuery(.movie))
        XCTAssertFalse(order.contains(.tmdb))
    }

    func testUnruledFieldFallsBackToBaseOrder() {
        let config = MetadataEnrichmentConfig()
        // Ids have no per-field table; the base order should drive them.
        let order = config.orderedSources(for: .providerID("Imdb"), query: makeQuery(.tvShow))
        XCTAssertEqual(order.first, MetadataEnrichmentConfig.defaultBaseOrder.first)
    }

    func testParseRolesToleratesWhitespaceAndBadTokens() {
        let roles = MetadataEnrichmentConfig.parseRoles("tmdb:disabled, wikipedia : secondary ,garbage,tvdb:nope")
        XCTAssertEqual(roles[.tmdb], .disabled)
        XCTAssertEqual(roles[.wikipedia], .secondary)
        XCTAssertNil(roles[MetadataSource(rawValue: "garbage")])
        XCTAssertNil(roles[.tvdb], "An unknown role value is skipped")
    }
}
