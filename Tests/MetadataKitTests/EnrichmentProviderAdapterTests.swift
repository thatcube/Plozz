import XCTest
import CoreModels
@testable import MetadataKit

// MARK: - Fake client seams (no network)

private struct FakeTVDB: TVDBEnriching {
    var byID: TVDBMetadata?
    var byTitle: TVDBMetadata?
    var backdrop: URL?
    let log = CallLog()

    func resolve(byTVDBID id: String, isMovie: Bool) async -> TVDBMetadata? {
        log.record("byID:\(id)")
        return byID
    }
    func resolve(titles: [String], year: Int?, isMovie: Bool, episodeHints: [SeriesEpisodeHint]) async -> TVDBMetadata? {
        log.record("byTitle:\(titles.joined(separator: "|"))")
        return byTitle
    }
    func backdropURL(title: String, year: Int?, isMovie: Bool, tvdbID: String?) async -> URL? {
        backdrop
    }
}

private struct FakeTMDb: TMDbEnriching {
    var enabled = true
    var backdrops: [URL] = []
    var poster: URL?
    var logo: URL?
    var still: URL?
    var isEnabled: Bool { enabled }
    func backdropURLs(for query: MetadataQuery, limit: Int) async -> [URL] { Array(backdrops.prefix(limit)) }
    func artworkURL(_ kind: ArtworkKind, for query: MetadataQuery) async -> URL? {
        switch kind {
        case .poster: return poster
        case .logo: return logo
        case .thumbnail: return still
        case .hero: return backdrops.first
        }
    }
}

private struct FakeAniList: AniListEnriching {
    var media: AniListArtworkProvider.Media?
    func fetchMedia(for query: MetadataQuery) async -> AniListArtworkProvider.Media? { media }
}

private struct FakeTVmaze: TVmazeEnriching {
    var resolved: TVmazeResolved?
    func resolve(_ query: MetadataQuery, wantEpisodeStill: Bool, wantOverview: Bool) async -> TVmazeResolved? {
        resolved
    }
}

private struct FakeArtwork: ArtworkProvider {
    let id = "fake"
    var urls: [ArtworkKind: URL] = [:]
    func artworkURL(_ kind: ArtworkKind, for query: MetadataQuery) async -> URL? { urls[kind] }
}

final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func record(_ s: String) { lock.lock(); entries.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return entries }
}

final class EnrichmentProviderAdapterTests: XCTestCase {
    private func query(
        _ type: ContentType,
        kind: MediaItemKind = .movie,
        season: Int? = nil,
        episode: Int? = nil,
        ids: [String: String] = [:]
    ) -> MetadataQuery {
        MetadataQuery(
            contentType: type, kind: kind, title: "Show", alternateTitle: nil, year: 2020,
            seasonNumber: season, episodeNumber: episode, animeIDs: AnimeIDs(), providerIDs: ids
        )
    }

    // MARK: TheTVDB

    func testTVDBPrefersExactIDLookupOverTitleSearch() async {
        let fake = FakeTVDB(
            byID: TVDBMetadata(tvdbID: "555", imdbID: "tt9", overview: "Plot", posterURL: URL(string: "https://p/p.jpg"), genres: ["Drama"], title: "Real Title"),
            byTitle: nil,
            backdrop: URL(string: "https://b/b.jpg")
        )
        let provider = TVDBEnrichmentProvider(client: fake)
        let out = await provider.enrich(
            query(.movie, ids: ["Tvdb": "555"]),
            missing: [.overview, .posterURL, .backdropURL, .genres, .title]
        )

        XCTAssertEqual(out.externalIDs["Tvdb"]?.value, "555")
        XCTAssertEqual(out.externalIDs["Imdb"]?.value, "tt9")
        XCTAssertEqual(out.overview?.value, "Plot")
        XCTAssertEqual(out.genres?.value, ["Drama"])
        XCTAssertEqual(out.posterURL?.source, .tvdb)
        XCTAssertEqual(out.backdropCandidates.count, 1)
        XCTAssertEqual(fake.log.all, ["byID:555"], "A known id must skip the title search")
    }

    func testTVDBFallsBackToTitleSearchWithoutID() async {
        let fake = FakeTVDB(byID: nil, byTitle: TVDBMetadata(tvdbID: "77", title: "By Title"), backdrop: nil)
        let provider = TVDBEnrichmentProvider(client: fake)
        let out = await provider.enrich(query(.movie), missing: [.title])
        XCTAssertEqual(out.externalIDs["Tvdb"]?.value, "77")
        XCTAssertEqual(fake.log.all.first, "byTitle:Show")
    }

    // MARK: TMDb candidate set

    func testTMDbReturnsOrderedBackdropCandidateSet() async {
        let urls = [URL(string: "https://b/1.jpg")!, URL(string: "https://b/2.jpg")!, URL(string: "https://b/3.jpg")!]
        let provider = TMDbEnrichmentProvider(provider: FakeTMDb(backdrops: urls, poster: URL(string: "https://p/p.jpg")))
        let out = await provider.enrich(query(.movie), missing: [.homeHero, .detailBackdrop, .posterURL])
        XCTAssertEqual(out.backdropCandidates.map(\.value), urls)
        XCTAssertEqual(out.homeHero?.value, urls[0])
        XCTAssertEqual(out.detailBackdrop?.value, urls[1])
        XCTAssertEqual(out.posterURL?.source, .tmdb)
    }

    func testTMDbInertWhenDisabled() async {
        let provider = TMDbEnrichmentProvider(provider: FakeTMDb(enabled: false, backdrops: [URL(string: "https://b/1.jpg")!]))
        let out = await provider.enrich(query(.movie), missing: [.backdropURL])
        XCTAssertTrue(out.isEmpty)
    }

    // MARK: AniList

    func testAniListMapsIdentityScoreAndArt() async {
        let media = AniListArtworkProvider.Media(
            id: 21,
            averageScore: 88,
            bannerImage: "https://a/banner.jpg",
            coverImage: AniListArtworkProvider.Media.CoverImage(extraLarge: "https://a/cover.jpg", large: nil)
        )
        let provider = AniListEnrichmentProvider(client: FakeAniList(media: media))
        let out = await provider.enrich(query(.anime, kind: .series), missing: [.posterURL, .backdropURL])
        XCTAssertEqual(out.externalIDs["AniList"]?.value, "21")
        XCTAssertEqual(out.score?.value ?? 0, 8.8, accuracy: 0.001)
        XCTAssertEqual(out.posterURL?.value, URL(string: "https://a/cover.jpg"))
        XCTAssertEqual(out.bannerURL?.value, URL(string: "https://a/banner.jpg"))
        XCTAssertEqual(out.homeHero?.value, URL(string: "https://a/banner.jpg"))
    }

    func testAniListInertForNonAnime() async {
        let media = AniListArtworkProvider.Media(id: 1, averageScore: nil, bannerImage: nil, coverImage: nil)
        let provider = AniListEnrichmentProvider(client: FakeAniList(media: media))
        let out = await provider.enrich(query(.movie), missing: [.posterURL])
        XCTAssertTrue(out.isEmpty)
    }

    // MARK: TVmaze

    func testTVmazeMapsEpisodeStillAndOverview() async {
        let resolved = TVmazeResolved(
            showID: 42, imdbID: "tt42", tvdbID: "4242",
            posterURL: URL(string: "https://tv/poster.jpg"),
            episodeStillURL: URL(string: "https://tv/still.jpg"),
            overview: "Episode summary"
        )
        let provider = TVmazeEnrichmentProvider(client: FakeTVmaze(resolved: resolved))
        let out = await provider.enrich(
            query(.tvShow, kind: .episode, season: 1, episode: 3),
            missing: [.overview, .episodeThumbnail, .posterURL]
        )
        XCTAssertEqual(out.externalIDs["Imdb"]?.value, "tt42")
        XCTAssertEqual(out.externalIDs["Tvdb"]?.value, "4242")
        XCTAssertEqual(out.overview?.value, "Episode summary")
        XCTAssertEqual(out.episodeStillURL?.value, URL(string: "https://tv/still.jpg"))
        XCTAssertEqual(out.posterURL?.source, .tvmaze)
    }

    // MARK: Generic artwork adapter

    func testGenericArtworkAdapterMapsKinds() async {
        let art = FakeArtwork(urls: [
            .poster: URL(string: "https://g/p.jpg")!,
            .hero: URL(string: "https://g/h.jpg")!,
            .logo: URL(string: "https://g/l.jpg")!,
        ])
        let provider = ArtworkEnrichmentAdapter(
            id: .wikidata, capabilities: [.poster, .backdrop, .logo], provider: art
        )
        let out = await provider.enrich(query(.movie), missing: [.posterURL, .homeHero, .logoURL])
        XCTAssertEqual(out.posterURL?.value, URL(string: "https://g/p.jpg"))
        XCTAssertEqual(out.homeHero?.value, URL(string: "https://g/h.jpg"))
        XCTAssertEqual(out.logoURL?.value, URL(string: "https://g/l.jpg"))
        XCTAssertEqual(out.posterURL?.source, .wikidata)
    }

    // MARK: - Acceptance scenarios through the pipeline

    func testBareMovieGetsTheTVDBMetadata() async {
        let tvdb = TVDBEnrichmentProvider(client: FakeTVDB(
            byID: nil,
            byTitle: TVDBMetadata(tvdbID: "555", imdbID: "tt9", overview: "A movie", posterURL: URL(string: "https://p/p.jpg"), genres: ["Action"], title: "Movie"),
            backdrop: URL(string: "https://b/b.jpg")
        ))
        let pipeline = MetadataEnrichmentPipeline(providers: [tvdb])
        let out = await pipeline.enrich(
            query(.movie),
            requesting: [.overview, .posterURL, .backdropURL, .genres, .providerID("Tvdb"), .providerID("Imdb")],
            tier: .foregroundFill
        )
        XCTAssertEqual(out.overview?.value, "A movie")
        XCTAssertEqual(out.externalIDs["Tvdb"]?.value, "555")
        XCTAssertEqual(out.externalIDs["Imdb"]?.value, "tt9")
        XCTAssertNotNil(out.posterURL)
        XCTAssertFalse(out.backdropCandidates.isEmpty)
    }

    func testBareTVGetsTheTVDBPlusTVmazeEpisode() async {
        let tvdb = TVDBEnrichmentProvider(client: FakeTVDB(
            byID: nil,
            byTitle: TVDBMetadata(tvdbID: "900", overview: "Show plot", genres: ["Crime"], title: "Show"),
            backdrop: URL(string: "https://b/show.jpg")
        ))
        let tvmaze = TVmazeEnrichmentProvider(client: FakeTVmaze(resolved: TVmazeResolved(
            showID: 7, imdbID: "tt7",
            episodeStillURL: URL(string: "https://tv/still.jpg"),
            overview: "Episode summary"
        )))
        let pipeline = MetadataEnrichmentPipeline(providers: [tvdb, tvmaze])
        let out = await pipeline.enrich(
            query(.tvShow, kind: .episode, season: 2, episode: 4),
            requesting: [.overview, .genres, .episodeThumbnail, .providerID("Tvdb"), .providerID("Imdb")],
            tier: .foregroundFill
        )
        // TheTVDB supplies canonical ids + genres; TVmaze is the only source of the
        // per-episode still, and both id sources contribute (TheTVDB Tvdb, TVmaze
        // Imdb). Overview comes from a canonical source (present either way).
        XCTAssertEqual(out.externalIDs["Tvdb"]?.value, "900")
        XCTAssertEqual(out.externalIDs["Imdb"]?.value, "tt7")
        XCTAssertEqual(out.genres?.value, ["Crime"])
        XCTAssertEqual(out.episodeStillURL?.value, URL(string: "https://tv/still.jpg"))
        XCTAssertEqual(out.episodeStillURL?.source, .tvmaze)
        XCTAssertNotNil(out.overview)
    }

    func testAnimeGetsTheTVDBIdentityAndAniListArt() async {
        let tvdb = TVDBEnrichmentProvider(client: FakeTVDB(
            byID: nil,
            byTitle: TVDBMetadata(tvdbID: "111", title: "Anime Show"),
            backdrop: nil
        ))
        let anilist = AniListEnrichmentProvider(client: FakeAniList(media: AniListArtworkProvider.Media(
            id: 21, averageScore: 90, bannerImage: "https://a/banner.jpg",
            coverImage: AniListArtworkProvider.Media.CoverImage(extraLarge: "https://a/cover.jpg", large: nil)
        )))
        let pipeline = MetadataEnrichmentPipeline(providers: [tvdb, anilist])
        let out = await pipeline.enrich(
            query(.anime, kind: .series),
            requesting: [.posterURL, .backdropURL, .providerID("Tvdb"), .providerID("AniList")],
            tier: .foregroundFill
        )
        XCTAssertEqual(out.externalIDs["Tvdb"]?.value, "111", "TheTVDB supplies identity")
        XCTAssertEqual(out.externalIDs["AniList"]?.value, "21")
        XCTAssertEqual(out.score?.value ?? 0, 9.0, accuracy: 0.001)
        XCTAssertEqual(out.posterURL?.source, .anilist, "AniList supplies anime art")
        XCTAssertEqual(out.homeHero?.value, URL(string: "https://a/banner.jpg"))
    }
}
