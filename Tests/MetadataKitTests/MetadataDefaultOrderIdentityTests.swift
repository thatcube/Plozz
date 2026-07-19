import XCTest
import CoreModels
@testable import MetadataKit

/// The key safety property of the reorder work: an **un-reordered** config
/// (`usesGlobalOrder == false`, nothing disabled) must produce **byte-identical**
/// per-field / per-content-type source ordering to the pre-reorder behavior — the
/// Step-3 policy chain (`ruled + base order`, deduped). This locks it hard by
/// recomputing the expected order from an INDEPENDENT copy of the policy tables (so a
/// change to either the policy or the ordering code is caught here).
final class MetadataDefaultOrderIdentityTests: XCTestCase {
    private let baseOrder = MetadataEnrichmentConfig.defaultBaseOrder

    // An independent transcription of `CurrentMetadataPriority`'s tables. If the real
    // policy changes, this test must be updated deliberately — that is the lock.
    private func ruled(field: MetadataField, type: ContentType) -> [MetadataSource] {
        switch (field, type) {
        // artwork.hero  (backdropURL / homeHero / detailBackdrop)
        case (.backdropURL, .anime), (.homeHero, .anime), (.detailBackdrop, .anime): return [.tmdb, .anilist, .kitsu]
        case (.backdropURL, .tvShow), (.homeHero, .tvShow), (.detailBackdrop, .tvShow): return [.tvdb, .tmdb, .wikidata, .wikipedia]
        case (.backdropURL, .movie), (.homeHero, .movie), (.detailBackdrop, .movie): return [.tvdb, .tmdb, .wikidata, .wikipedia]
        case (.backdropURL, .unknown), (.homeHero, .unknown), (.detailBackdrop, .unknown): return [.tvdb, .tmdb, .wikidata, .wikipedia]
        // artwork.poster
        case (.posterURL, .anime): return [.anilist, .kitsu, .tmdb]
        case (.posterURL, .tvShow): return [.tmdb, .tvmaze, .tvdb, .wikidata, .wikipedia]
        case (.posterURL, .movie): return [.tmdb, .tvdb, .wikidata, .wikipedia]
        case (.posterURL, .unknown): return [.tmdb, .tvdb, .wikidata, .wikipedia]
        // artwork.thumbnail (episodeThumbnail)
        case (.episodeThumbnail, .anime): return [.tmdb]
        case (.episodeThumbnail, .tvShow): return [.tmdb, .tvmaze]
        case (.episodeThumbnail, .movie): return [.tmdb]
        case (.episodeThumbnail, .unknown): return [.tmdb]
        // artwork.logo
        case (.logoURL, .anime): return [.tmdb, .wikidata, .wikipedia]
        case (.logoURL, .tvShow): return [.tmdb, .wikidata, .wikipedia]
        case (.logoURL, .movie): return [.tmdb, .wikidata, .wikipedia]
        case (.logoURL, .unknown): return [.tmdb, .wikidata, .wikipedia]
        // overview
        case (.overview, .anime): return [.wikipedia]
        case (.overview, .movie): return [.wikipedia]
        case (.overview, .tvShow): return [.tvmaze]
        case (.overview, .unknown): return [.wikipedia]
        case (.overview, .music): return []
        // nextAiringEpisode
        case (.nextAiringEpisode, .anime): return [.anilist, .tvdb, .tvmaze]
        case (.nextAiringEpisode, .tvShow): return [.tvdb, .tvmaze]
        case (.nextAiringEpisode, .unknown): return [.tvdb, .tvmaze]
        case (.nextAiringEpisode, .movie): return []
        default: return []
        }
    }

    private func expected(field: MetadataField, type: ContentType) -> [MetadataSource] {
        var seen: Set<MetadataSource> = []
        var out: [MetadataSource] = []
        for s in ruled(field: field, type: type) + baseOrder where seen.insert(s).inserted {
            out.append(s)
        }
        return out
    }

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

    func testDefaultConfigMatchesPolicyForEveryFieldAndKind() {
        let config = MetadataEnrichmentConfig()
        XCTAssertFalse(config.usesGlobalOrder)

        let fields: [MetadataField] = [
            .backdropURL, .homeHero, .detailBackdrop, .posterURL, .episodeThumbnail,
            .logoURL, .overview, .nextAiringEpisode,
            .title, .genres, .taglines, .ratings, .providerID("Imdb"),
        ]
        let types: [ContentType] = [.movie, .tvShow, .anime, .unknown, .music]

        for type in types {
            let query = makeQuery(type)
            for field in fields {
                let actual = config.orderedSources(for: field, query: query)
                XCTAssertEqual(
                    actual, expected(field: field, type: type),
                    "default order changed for \(field.rawValue) / \(type.rawValue)"
                )
            }
        }
    }

    func testResolvedDefaultMergedWithEmptyOverrideIsIdentical() {
        // The runtime path: resolved baseline merged with an empty user override must be
        // byte-identical to the pure default for every field.
        let base = MetadataEnrichmentConfig()
        let merged = base.merged(withUserOverrides: .default)
        let query = makeQuery(.tvShow)
        for field in [MetadataField.backdropURL, .posterURL, .overview, .title] {
            XCTAssertEqual(
                merged.orderedSources(for: field, query: query),
                base.orderedSources(for: field, query: query)
            )
        }
    }

    func testConcreteKnownOrderings() {
        let config = MetadataEnrichmentConfig()
        XCTAssertEqual(
            config.orderedSources(for: .posterURL, query: makeQuery(.movie)),
            [.tmdb, .tvdb, .wikidata, .wikipedia, .anilist, .tvmaze, .kitsu, .omdb, .deezer, .musicbrainz]
        )
        XCTAssertEqual(
            config.orderedSources(for: .backdropURL, query: makeQuery(.tvShow)),
            [.tvdb, .tmdb, .wikidata, .wikipedia, .anilist, .tvmaze, .kitsu, .omdb, .deezer, .musicbrainz]
        )
        XCTAssertEqual(
            config.orderedSources(for: .posterURL, query: makeQuery(.anime)),
            [.anilist, .kitsu, .tmdb, .tvdb, .tvmaze, .wikidata, .wikipedia, .omdb, .deezer, .musicbrainz]
        )
    }
}
