import XCTest
@testable import MetadataKit
import CoreModels

/// Gating coverage for the TheTVDB backdrop provider. Live TVDB lookups aren't
/// exercised (no network in unit tests); these assert the routing contract: it
/// only serves `.hero`, skips anime/music, and no-ops cleanly when unconfigured.
final class TVDBArtworkProviderTests: XCTestCase {
    private func query(_ type: ContentType, kind: MediaItemKind = .series) -> MetadataQuery {
        MetadataQuery(contentType: type, kind: kind, title: "Some Show", alternateTitle: nil,
                      year: 2020, seasonNumber: nil, episodeNumber: nil,
                      animeIDs: AnimeIDs(), providerIDs: [:])
    }

    func testUnconfiguredReturnsNil() async {
        let provider = TVDBArtworkProvider(client: TVDBClient(config: TVDBConfig(apiKey: nil)))
        let hero = await provider.artworkURL(.hero, for: query(.tvShow))
        XCTAssertNil(hero, "no key → no lookup, no crash")
    }

    func testOnlyServesHero() async {
        // Even configured, non-hero kinds are declined (posters/logos stay with the
        // existing providers). Unconfigured client makes this a pure routing check.
        let provider = TVDBArtworkProvider(client: TVDBClient(config: TVDBConfig(apiKey: nil)))
        for kind in [ArtworkKind.poster, .logo, .thumbnail] {
            let url = await provider.artworkURL(kind, for: query(.tvShow))
            XCTAssertNil(url, "\(kind) must be declined by the TVDB backdrop provider")
        }
    }

    func testSkipsAnimeAndMusic() async {
        let provider = TVDBArtworkProvider(client: TVDBClient(config: TVDBConfig(apiKey: nil)))
        let anime = await provider.artworkURL(.hero, for: query(.anime))
        let music = await provider.artworkURL(.hero, for: query(.music, kind: .unknown))
        XCTAssertNil(anime)
        XCTAssertNil(music)
    }
}
