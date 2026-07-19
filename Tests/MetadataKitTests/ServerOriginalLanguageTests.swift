import XCTest
import CoreModels
@testable import MetadataKit

/// Server-item "prefer original language" resolution: `ArtworkRouter` fills a
/// SERVER-backed item's original language from an EXACT external-id TMDB lookup
/// (no fuzzy title search), normalized and cached, reusing the same provider-id
/// seam artwork already uses — so the audio policy fires for Plex/Jellyfin/Emby
/// items, not just direct shares.
final class ServerOriginalLanguageTests: XCTestCase {

    /// A counting fake exact-ID resolver so tests can prove one-lookup caching and
    /// exactly what query the router asked about.
    private final class CountingResolver: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: [MetadataQuery] = []
        var stub: @Sendable (MetadataQuery) -> String?
        init(_ stub: @escaping @Sendable (MetadataQuery) -> String?) { self.stub = stub }
        func resolve(_ query: MetadataQuery) -> String? {
            lock.lock(); defer { lock.unlock() }
            calls.append(query)
            return stub(query)
        }
        var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls.count }
    }

    private func makeRouter(_ resolver: CountingResolver) -> ArtworkRouter {
        ArtworkRouter(exactOriginalLanguageResolver: { resolver.resolve($0) })
    }

    // MARK: - Resolution + normalization

    func testResolvesEnglishForPlexMovieWithTMDbID() async {
        let resolver = CountingResolver { _ in "en" }
        let router = makeRouter(resolver)
        let item = MediaItem(id: "plex-1", title: "Spider-Man", kind: .movie,
                             providerIDs: ["Tmdb": "557"])

        let language = await router.originalLanguage(for: item)

        XCTAssertEqual(language, "en")
        XCTAssertEqual(resolver.callCount, 1)
    }

    func testNormalizesProviderCodeShapes() async {
        // TheTVDB-style 3-letter code folds to ISO-639-1.
        let resolver = CountingResolver { _ in "jpn" }
        let router = makeRouter(resolver)
        let item = MediaItem(id: "j-1", title: "Show", kind: .series,
                             providerIDs: ["Tmdb": "1"])

        let language = await router.originalLanguage(for: item)

        XCTAssertEqual(language, "ja")
    }

    func testSentinelNoLanguageCodeBecomesNil() async {
        // TMDb "xx" (No Language) must NOT become a bogus track request.
        let resolver = CountingResolver { _ in "xx" }
        let router = makeRouter(resolver)
        let item = MediaItem(id: "m", title: "Silent", kind: .movie,
                             providerIDs: ["Tmdb": "9"])

        let language = await router.originalLanguage(for: item)

        XCTAssertNil(language)
    }

    // MARK: - Caching (one lookup)

    func testResultIsCachedSoRepeatPlaysIssueNoSecondLookup() async {
        let resolver = CountingResolver { _ in "en" }
        let router = makeRouter(resolver)
        let item = MediaItem(id: "plex-1", title: "Spider-Man", kind: .movie,
                             providerIDs: ["Tmdb": "557"])

        _ = await router.originalLanguage(for: item)
        _ = await router.originalLanguage(for: item)
        _ = await router.originalLanguage(for: item)

        XCTAssertEqual(resolver.callCount, 1, "Repeat resolution must be cache hits")
    }

    func testNegativeResultIsCached() async {
        let resolver = CountingResolver { _ in nil }
        let router = makeRouter(resolver)
        let item = MediaItem(id: "m", title: "Unknown", kind: .movie,
                             providerIDs: ["Tmdb": "3"])

        let first = await router.originalLanguage(for: item)
        let second = await router.originalLanguage(for: item)

        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(resolver.callCount, 1, "A miss is cached, never re-fetched")
    }

    func testEpisodesOfSameShowShareOneShowLevelLookup() async {
        let resolver = CountingResolver { _ in "en" }
        let router = makeRouter(resolver)
        let ep1 = MediaItem(id: "e1", title: "Chapter 1", kind: .episode,
                            providerIDs: ["Tmdb": "111", "SeriesTmdb": "999"])
        let ep2 = MediaItem(id: "e2", title: "Chapter 2", kind: .episode,
                            providerIDs: ["Tmdb": "222", "SeriesTmdb": "999"])

        _ = await router.originalLanguage(for: ep1)
        _ = await router.originalLanguage(for: ep2)

        XCTAssertEqual(resolver.callCount, 1,
                       "Both episodes key on the show's SeriesTmdb id → one lookup")
    }

    // MARK: - Cache key identity

    func testCacheKeyPrefersShowLevelIDNotEpisodeID() {
        let episode = MetadataQuery(
            MediaItem(id: "e1", title: "Chapter 1", kind: .episode,
                      providerIDs: ["Tmdb": "111", "SeriesTmdb": "999"]))
        let key = ArtworkRouter.originalLanguageCacheKey(for: episode)
        XCTAssertTrue(key.contains("tmdb:999"), "Keyed on show id, got: \(key)")
        XCTAssertFalse(key.contains("111"), "Must not key on the per-episode id")
    }

    func testCacheKeyFallsBackToIMDbThenTitle() {
        let imdbOnly = MetadataQuery(
            MediaItem(id: "m", title: "Movie", kind: .movie,
                      providerIDs: ["Imdb": "tt1234567"]))
        XCTAssertTrue(ArtworkRouter.originalLanguageCacheKey(for: imdbOnly).contains("imdb:tt1234567"))

        let titleOnly = MetadataQuery(
            MediaItem(id: "m", title: "Bare Title", kind: .movie))
        XCTAssertTrue(ArtworkRouter.originalLanguageCacheKey(for: titleOnly).contains("bare title"))
    }
}

/// The TMDb exact-ID resolver's pure id-selection logic (no network): a movie uses
/// its own `Tmdb`, an episode uses the show's `SeriesTmdb` (never the episode id),
/// and an id-less item yields nothing — so no fuzzy title search is ever attempted.
final class TMDbExactStampedIDTests: XCTestCase {
    private func query(_ item: MediaItem) -> MetadataQuery { MetadataQuery(item) }

    func testMovieUsesOwnTMDbID() {
        let q = query(MediaItem(id: "m", title: "Movie", kind: .movie,
                                providerIDs: ["Tmdb": "557"]))
        XCTAssertEqual(TMDbMetadataProvider.exactStampedTMDbID(for: q, isTV: q.isTV), "557")
    }

    func testEpisodeUsesSeriesTMDbNotEpisodeID() {
        let q = query(MediaItem(id: "e", title: "Ep", kind: .episode,
                                providerIDs: ["Tmdb": "111", "SeriesTmdb": "999"]))
        XCTAssertEqual(TMDbMetadataProvider.exactStampedTMDbID(for: q, isTV: q.isTV), "999")
    }

    func testEpisodeWithoutSeriesIDHasNoExactID() {
        let q = query(MediaItem(id: "e", title: "Ep", kind: .episode,
                                providerIDs: ["Tmdb": "111"]))
        XCTAssertNil(TMDbMetadataProvider.exactStampedTMDbID(for: q, isTV: q.isTV),
                     "An episode's own Tmdb is the episode, not the show")
    }

    func testSeriesUsesOwnTMDbID() {
        let q = query(MediaItem(id: "s", title: "Show", kind: .series,
                                providerIDs: ["Tmdb": "1399"]))
        XCTAssertEqual(TMDbMetadataProvider.exactStampedTMDbID(for: q, isTV: q.isTV), "1399")
    }

    func testNoIDsYieldsNil() {
        let q = query(MediaItem(id: "m", title: "Movie", kind: .movie))
        XCTAssertNil(TMDbMetadataProvider.exactStampedTMDbID(for: q, isTV: q.isTV))
    }

    func testDisabledTMDbResolvesNothingWithoutNetwork() async {
        let provider = TMDbMetadataProvider(access: .disabled)
        let q = query(MediaItem(id: "m", title: "Movie", kind: .movie,
                                providerIDs: ["Tmdb": "557"]))
        let language = await provider.originalLanguage(forExactMatchOf: q)
        XCTAssertNil(language, "Disabled TMDb must never touch the network")
    }
}
