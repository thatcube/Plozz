import XCTest
import CoreModels
@testable import MetadataKit

/// Server-item "prefer original language" resolution: `ArtworkRouter` fills a
/// SERVER-backed item's original language from an EXACT external-id TMDB lookup
/// (no fuzzy title search), normalized and cached, reusing the same provider-id
/// seam artwork already uses — so the audio policy fires for Plex/Jellyfin/Emby
/// items, not just direct shares.
final class ServerOriginalLanguageTests: XCTestCase {

    /// A counting fake exact-ID resolver so tests can prove one-lookup caching, the
    /// authoritative-vs-transient caching rule, and exactly what query the router
    /// asked about. The stub returns an ``OriginalLanguageOutcome`` so tests can
    /// model transient failures distinctly from authoritative misses.
    private final class CountingResolver: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: [MetadataQuery] = []
        var stub: @Sendable (MetadataQuery) -> OriginalLanguageOutcome
        init(_ stub: @escaping @Sendable (MetadataQuery) -> OriginalLanguageOutcome) { self.stub = stub }
        func resolve(_ query: MetadataQuery) -> OriginalLanguageOutcome {
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
        let resolver = CountingResolver { _ in .authoritative("en") }
        let router = makeRouter(resolver)
        let item = MediaItem(id: "plex-1", title: "Spider-Man", kind: .movie,
                             providerIDs: ["Tmdb": "557"])

        let language = await router.originalLanguage(for: item)

        XCTAssertEqual(language, "en")
        XCTAssertEqual(resolver.callCount, 1)
    }

    func testNormalizesProviderCodeShapes() async {
        // TheTVDB-style 3-letter code folds to ISO-639-1.
        let resolver = CountingResolver { _ in .authoritative("jpn") }
        let router = makeRouter(resolver)
        let item = MediaItem(id: "j-1", title: "Show", kind: .series,
                             providerIDs: ["Tmdb": "1"])

        let language = await router.originalLanguage(for: item)

        XCTAssertEqual(language, "ja")
    }

    func testSentinelNoLanguageCodeBecomesNil() async {
        // TMDb "xx" (No Language) must NOT become a bogus track request.
        let resolver = CountingResolver { _ in .authoritative("xx") }
        let router = makeRouter(resolver)
        let item = MediaItem(id: "m", title: "Silent", kind: .movie,
                             providerIDs: ["Tmdb": "9"])

        let language = await router.originalLanguage(for: item)

        XCTAssertNil(language)
    }

    // MARK: - Caching (one lookup)

    func testResultIsCachedSoRepeatPlaysIssueNoSecondLookup() async {
        let resolver = CountingResolver { _ in .authoritative("en") }
        let router = makeRouter(resolver)
        let item = MediaItem(id: "plex-1", title: "Spider-Man", kind: .movie,
                             providerIDs: ["Tmdb": "557"])

        _ = await router.originalLanguage(for: item)
        _ = await router.originalLanguage(for: item)
        _ = await router.originalLanguage(for: item)

        XCTAssertEqual(resolver.callCount, 1, "Repeat resolution must be cache hits")
    }

    func testAuthoritativeMissIsCached() async {
        // A decoded 2xx / 404 with no language is a real verdict → cache it.
        let resolver = CountingResolver { _ in .authoritative(nil) }
        let router = makeRouter(resolver)
        let item = MediaItem(id: "m", title: "Unknown", kind: .movie,
                             providerIDs: ["Tmdb": "3"])

        let first = await router.originalLanguage(for: item)
        let second = await router.originalLanguage(for: item)

        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(resolver.callCount, 1, "An authoritative miss is cached, never re-fetched")
    }

    // MARK: - Transient failures must NOT be cached (re-introduces the bug otherwise)

    func testTransientFailureIsNotCachedAndLaterPlayCanSucceed() async {
        // First lookup hits a transient hiccup (offline/429/5xx); the second
        // succeeds. The nil from the transient must NOT be pinned, or every later
        // play would fall back to the container default until app restart.
        let attempts = TestCounter()
        let resolver = CountingResolver { _ in
            attempts.increment() == 1 ? .transient : .authoritative("en")
        }
        let router = makeRouter(resolver)
        let item = MediaItem(id: "plex-1", title: "Spider-Man", kind: .movie,
                             providerIDs: ["Tmdb": "557"])

        let first = await router.originalLanguage(for: item)
        let second = await router.originalLanguage(for: item)

        XCTAssertNil(first, "Transient failure yields no value for this play")
        XCTAssertEqual(second, "en", "A later play retries and can succeed")
        XCTAssertEqual(resolver.callCount, 2, "The transient result was not cached")
    }

    func testTransientFailureThenAuthoritativeMissEventuallyCaches() async {
        let attempts = TestCounter()
        let resolver = CountingResolver { _ in
            attempts.increment() == 1 ? .transient : .authoritative(nil)
        }
        let router = makeRouter(resolver)
        let item = MediaItem(id: "m", title: "Foreign", kind: .movie,
                             providerIDs: ["Tmdb": "42"])

        _ = await router.originalLanguage(for: item)   // transient, not cached
        _ = await router.originalLanguage(for: item)   // authoritative miss, cached
        _ = await router.originalLanguage(for: item)   // cache hit

        XCTAssertEqual(resolver.callCount, 2, "Retry after transient, then the miss sticks")
    }

    func testEpisodesOfSameShowShareOneShowLevelLookup() async {
        let resolver = CountingResolver { _ in .authoritative("en") }
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

    // MARK: - In-flight coalescing

    func testConcurrentFirstPlaysOfSameShowCoalesceToOneLookup() async {
        // Model a slow lookup so the current load and the next-episode prefetch
        // overlap; they must share one request, not fire duplicates.
        let resolver = CountingResolver { _ in .authoritative("en") }
        let router = ArtworkRouter(exactOriginalLanguageResolver: { query in
            try? await Task.sleep(for: .milliseconds(100))
            return resolver.resolve(query)
        })
        let item = MediaItem(id: "plex-1", title: "Spider-Man", kind: .movie,
                             providerIDs: ["Tmdb": "557"])

        async let a = router.originalLanguage(for: item)
        async let b = router.originalLanguage(for: item)
        let (ra, rb) = await (a, b)

        XCTAssertEqual(ra, "en")
        XCTAssertEqual(rb, "en")
        XCTAssertEqual(resolver.callCount, 1, "Concurrent misses coalesce onto one lookup")
    }

    // MARK: - Bounded play-path wait (Fix 2)

    func testBoundedValueReturnsNilOnTimeoutButLetsWorkFinish() async {
        let finished = expectation(description: "work completes despite timeout")
        let start = Date()

        let value = await ArtworkRouter.boundedValue(within: .milliseconds(150)) { () -> String? in
            try? await Task.sleep(for: .milliseconds(600))
            finished.fulfill()
            return "en"
        }

        XCTAssertNil(value, "A slow lookup does not block past the bound")
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5,
                          "Returned near the bound, not the full operation time")
        await fulfillment(of: [finished], timeout: 2)
    }

    func testBoundedValueReturnsValueWhenFastEnough() async {
        let value = await ArtworkRouter.boundedValue(within: .seconds(2)) { () -> String? in "en" }
        XCTAssertEqual(value, "en")
    }
}

/// A tiny thread-safe call counter for modeling "first attempt fails, later
/// attempts succeed" without an actor.
private final class TestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    /// Increments and returns the new (1-based) count.
    @discardableResult func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count
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
