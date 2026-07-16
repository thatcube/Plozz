import XCTest
import CoreModels
@testable import MetadataKit

final class MetadataKitTests: XCTestCase {
    private func item(
        kind: MediaItemKind = .series,
        title: String = "Show",
        parentTitle: String? = nil,
        season: Int? = nil,
        episode: Int? = nil,
        year: Int? = nil,
        genres: [String] = [],
        providerIDs: [String: String] = [:]
    ) -> MediaItem {
        MediaItem(
            id: "1",
            title: title,
            kind: kind,
            parentTitle: parentTitle,
            seasonNumber: season,
            episodeNumber: episode,
            productionYear: year,
            genres: genres,
            providerIDs: providerIDs
        )
    }

    // MARK: - Classification

    func testAnimeDetectedByProviderID() {
        XCTAssertEqual(ContentClassifier.classify(item(providerIDs: ["AniList": "21"])), .anime)
        XCTAssertEqual(ContentClassifier.classify(item(providerIDs: ["AniDB": "999"])), .anime)
        XCTAssertEqual(ContentClassifier.classify(item(providerIDs: ["MAL": "1"])), .anime)
    }

    func testAnimeDetectedByGenre() {
        XCTAssertEqual(ContentClassifier.classify(item(genres: ["Anime", "Action"])), .anime)
    }

    func testMovieAndTVClassification() {
        XCTAssertEqual(ContentClassifier.classify(item(kind: .movie, providerIDs: ["Tmdb": "1"])), .movie)
        XCTAssertEqual(ContentClassifier.classify(item(kind: .series, providerIDs: ["Tmdb": "1"])), .tvShow)
        XCTAssertEqual(ContentClassifier.classify(item(kind: .episode)), .tvShow)
    }

    func testOriginalAudioLanguageHeuristic() {
        // Anime → Japanese original; everything else is unknown (nil) so the
        // prefer-original policy defers to the container default.
        XCTAssertEqual(ContentClassifier.originalAudioLanguage(for: item(providerIDs: ["AniList": "21"])), "ja")
        XCTAssertEqual(ContentClassifier.originalAudioLanguage(for: item(genres: ["Anime"])), "ja")
        XCTAssertNil(ContentClassifier.originalAudioLanguage(for: item(kind: .movie, providerIDs: ["Tmdb": "1"])))
        XCTAssertNil(ContentClassifier.originalAudioLanguage(for: item(kind: .episode)))
    }

    func testContentTypeMapsToSubtitleCategory() {
        XCTAssertEqual(ContentType.anime.subtitleCategory, .anime)
        XCTAssertEqual(ContentType.movie.subtitleCategory, .movie)
        XCTAssertEqual(ContentType.tvShow.subtitleCategory, .tvShow)
        XCTAssertEqual(ContentType.music.subtitleCategory, .other)
        XCTAssertEqual(ContentType.unknown.subtitleCategory, .other)
    }

    func testClassifiedItemResolvesSubtitleCategory() {
        XCTAssertEqual(ContentClassifier.classify(item(providerIDs: ["AniList": "21"])).subtitleCategory, .anime)
        XCTAssertEqual(ContentClassifier.classify(item(kind: .movie)).subtitleCategory, .movie)
        XCTAssertEqual(ContentClassifier.classify(item(kind: .episode)).subtitleCategory, .tvShow)
    }

    func testAnimeIDsExtraction() {
        let ids = AnimeIDs(from: item(providerIDs: ["AniList": "21", "MyAnimeList": "20", "AniDB": "5"]))
        XCTAssertEqual(ids.anilist, 21)
        XCTAssertEqual(ids.mal, 20)
        XCTAssertEqual(ids.anidb, 5)
    }

    func testCurrentArtworkPriorityPreservesEveryExistingChain() {
        let expected: [ContentType: [ArtworkKind: [MetadataSource]]] = [
            .anime: [
                .hero: [.tmdb, .anilist, .kitsu],
                .poster: [.anilist, .kitsu, .tmdb],
                .thumbnail: [.tmdb],
                .logo: [.tmdb, .wikidata, .wikipedia]
            ],
            .tvShow: [
                .hero: [.tvdb, .tmdb, .wikidata, .wikipedia],
                .poster: [.tmdb, .tvmaze, .tvdb, .wikidata, .wikipedia],
                .thumbnail: [.tmdb, .tvmaze],
                .logo: [.tmdb, .wikidata, .wikipedia]
            ],
            .movie: [
                .hero: [.tvdb, .tmdb, .wikidata, .wikipedia],
                .poster: [.tmdb, .tvdb, .wikidata, .wikipedia],
                .thumbnail: [.tmdb],
                .logo: [.tmdb, .wikidata, .wikipedia]
            ],
            .unknown: [
                .hero: [.tvdb, .tmdb, .wikidata, .wikipedia],
                .poster: [.tmdb, .tvdb, .wikidata, .wikipedia],
                .thumbnail: [.tmdb],
                .logo: [.tmdb, .wikidata, .wikipedia]
            ],
            .music: [:]
        ]

        for (type, chains) in expected {
            for kind in [ArtworkKind.hero, .poster, .thumbnail, .logo] {
                XCTAssertEqual(
                    CurrentMetadataPriority.artworkSources(for: type, kind: kind),
                    chains[kind] ?? [],
                    "\(type.rawValue) \(kind.rawValue)"
                )
            }
        }
    }

    func testCurrentOverviewPriorityPreservesExistingRouting() {
        XCTAssertEqual(CurrentMetadataPriority.overviewSources(for: .anime), [.wikipedia])
        XCTAssertEqual(CurrentMetadataPriority.overviewSources(for: .movie), [.wikipedia])
        XCTAssertEqual(CurrentMetadataPriority.overviewSources(for: .tvShow), [.tvmaze])
        XCTAssertEqual(CurrentMetadataPriority.overviewSources(for: .unknown), [.wikipedia])
        XCTAssertEqual(CurrentMetadataPriority.overviewSources(for: .music), [])
    }

    // MARK: - Query normalization

    func testEpisodeQueryUsesSeriesTitleAndNoYear() {
        let q = MetadataQuery(item(kind: .episode, title: "Ep 1", parentTitle: "My Show", season: 1, episode: 1, year: 2020))
        XCTAssertEqual(q.title, "My Show")
        XCTAssertTrue(q.isTV)
        XCTAssertNil(q.year) // TV must not pass an episode air-year into title search
    }

    func testMovieQueryKeepsYear() {
        let q = MetadataQuery(item(kind: .movie, title: "Film", year: 1999, providerIDs: ["Tmdb": "603"]))
        XCTAssertFalse(q.isTV)
        XCTAssertEqual(q.year, 1999)
    }

    // MARK: - Cache keys

    func testCacheKeyPrefersStableID() {
        let anilist = MetadataQuery(item(genres: ["Anime"], providerIDs: ["AniList": "21"]))
        XCTAssertTrue(anilist.cacheKey(for: .hero).contains("anilist:21"))

        let tmdb = MetadataQuery(item(kind: .series, providerIDs: ["Tmdb": "1399"]))
        XCTAssertTrue(tmdb.cacheKey(for: .poster).contains("tmdb:1399"))
    }

    func testThumbnailCacheKeyIncludesEpisode() {
        let q = MetadataQuery(item(kind: .episode, parentTitle: "Show", season: 2, episode: 5, providerIDs: ["SeriesTmdb": "1"]))
        XCTAssertTrue(q.cacheKey(for: .thumbnail).contains("s2e5"))
    }

    // MARK: - TMDb selection

    func testBestImagePrefersNeutralLanguageForHero() {
        let images = [
            TMDbMetadataProvider.Image(file_path: "/en.jpg", iso_639_1: "en", vote_average: 9),
            TMDbMetadataProvider.Image(file_path: "/neutral.jpg", iso_639_1: nil, vote_average: 1)
        ]
        XCTAssertEqual(TMDbMetadataProvider.bestImagePath(images, preferNeutral: true), "/neutral.jpg")
    }

    func testBestLogoSkipsSVGAndPrefersEnglish() {
        let logos = [
            TMDbMetadataProvider.Image(file_path: "/vector.svg", iso_639_1: "en", vote_average: 10),
            TMDbMetadataProvider.Image(file_path: "/logo.png", iso_639_1: "en", vote_average: 5)
        ]
        XCTAssertEqual(TMDbMetadataProvider.bestLogoPath(logos), "/logo.png")
    }

    // MARK: - Config

    func testAccessEnablement() {
        let proxy = TMDbAccess.proxy(baseURL: URL(string: "https://proxy.example")!)
        XCTAssertTrue(proxy.isEnabled)
        XCTAssertTrue(TMDbAccess.directToken("abc").isEnabled)
        XCTAssertFalse(TMDbAccess.disabled.isEnabled)
    }
}
