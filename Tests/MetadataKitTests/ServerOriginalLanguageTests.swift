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

/// The MULTI-PROVIDER original-language chain: `ArtworkRouter.originalLanguage`
/// no longer depends on TMDb alone. It walks the content-type-specific chain
/// (`CurrentMetadataPriority.originalLanguageSources`: movie `[tmdb, tvdb]`;
/// tvShow/anime `[tmdb, tvdb, tvmaze]`), returns the first AUTHORITATIVE value,
/// falls a transient failure THROUGH to the next provider (never caching it), and
/// caches an authoritative miss only when the WHOLE chain is exhausted — so a
/// disabled/down TMDb no longer pins the container default (TheTVDB resolves it).
final class MultiProviderOriginalLanguageTests: XCTestCase {

    /// Records per-source lookups and returns a scripted outcome so tests can prove
    /// ordering, short-circuiting, transient fall-through, and which providers a
    /// given content type consults — without any network.
    private final class ProviderRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: [MetadataSource] = []
        private var stub: @Sendable (MetadataSource, MetadataQuery) -> OriginalLanguageOutcome?
        init(_ stub: @escaping @Sendable (MetadataSource, MetadataQuery) -> OriginalLanguageOutcome?) {
            self.stub = stub
        }
        func outcome(_ source: MetadataSource, _ query: MetadataQuery) -> OriginalLanguageOutcome? {
            lock.lock(); defer { lock.unlock() }
            let out = stub(source, query)
            if out != nil { calls.append(source) }   // record only sources that participated
            return out
        }
        func count(of source: MetadataSource) -> Int {
            lock.lock(); defer { lock.unlock() }
            return calls.filter { $0 == source }.count
        }
        var total: Int { lock.lock(); defer { lock.unlock() }; return calls.count }
    }

    private func makeRouter(_ recorder: ProviderRecorder) -> ArtworkRouter {
        ArtworkRouter(providerOriginalLanguageOutcomes: { recorder.outcome($0, $1) })
    }

    private func movie(_ ids: [String: String] = ["Tmdb": "557"]) -> MediaItem {
        MediaItem(id: "m", title: "Spider-Man", kind: .movie, providerIDs: ids)
    }
    private func show(_ ids: [String: String] = ["Tmdb": "1399"]) -> MediaItem {
        MediaItem(id: "s", title: "Some Show", kind: .series, providerIDs: ids)
    }

    // MARK: - The exact scenario that just broke: TMDb disabled, TheTVDB fills it

    func testTMDbDisabledButTheTVDBResolvesEnglish() async {
        // TMDb `.authoritative(nil)` mirrors a DISABLED tier (a deterministic no-op);
        // TheTVDB then satisfies the chain — the bug fix.
        let recorder = ProviderRecorder { source, _ in
            switch source {
            case .tmdb: return .authoritative(nil)
            case .tvdb: return .authoritative("en")
            default: return nil
            }
        }
        let router = makeRouter(recorder)

        let language = await router.originalLanguage(for: movie())

        XCTAssertEqual(language, "en", "TheTVDB alone must resolve when TMDb is off")
    }

    // MARK: - Precedence + short-circuit

    func testTMDbWinsWhenBothAuthoritative() async {
        let recorder = ProviderRecorder { source, _ in
            switch source {
            case .tmdb: return .authoritative("ja")
            case .tvdb: return .authoritative("en")
            default: return nil
            }
        }
        let router = makeRouter(recorder)

        let language = await router.originalLanguage(for: movie())

        XCTAssertEqual(language, "ja", "TMDb leads the chain")
        XCTAssertEqual(recorder.count(of: .tvdb), 0, "A TMDb hit short-circuits before TheTVDB")
    }

    // MARK: - Transient fall-through (must NOT cache)

    func testTransientTMDbFallsThroughToTheTVDB() async {
        let recorder = ProviderRecorder { source, _ in
            switch source {
            case .tmdb: return .transient
            case .tvdb: return .authoritative("en")
            default: return nil
            }
        }
        let router = makeRouter(recorder)

        let language = await router.originalLanguage(for: movie())

        XCTAssertEqual(language, "en", "A transient TMDb must fall through to TheTVDB")
    }

    func testTheTVDBTransientIsNotCachedAndLaterPlayRetries() async {
        // Whole chain transient on the first play (TMDb miss, TheTVDB unreachable):
        // returns nil for this play but must NOT be cached, so a later play retries.
        let attempts = TestCounter()
        let recorder = ProviderRecorder { source, _ in
            switch source {
            case .tmdb: return .authoritative(nil)
            case .tvdb: return attempts.increment() == 1 ? .transient : .authoritative("en")
            default: return nil
            }
        }
        let router = makeRouter(recorder)
        let item = movie()

        let first = await router.originalLanguage(for: item)
        let second = await router.originalLanguage(for: item)

        XCTAssertNil(first, "A transient chain yields no value for this play")
        XCTAssertEqual(second, "en", "The transient was not cached, so a later play succeeds")
        XCTAssertEqual(recorder.count(of: .tvdb), 2, "TheTVDB was retried, not served from cache")
    }

    // MARK: - Content-type membership: movies skip TVmaze, TV uses it last

    func testMovieSkipsTVmaze() async {
        let recorder = ProviderRecorder { source, _ in
            switch source {
            case .tmdb, .tvdb: return .authoritative(nil)
            case .tvmaze:
                XCTFail("TVmaze has no movies — it must never be consulted for a movie")
                return .authoritative(nil)
            default: return nil
            }
        }
        let router = makeRouter(recorder)

        let language = await router.originalLanguage(for: movie())

        XCTAssertNil(language)
        XCTAssertEqual(recorder.count(of: .tvmaze), 0)
    }

    func testTVShowUsesTVmazeAsLastResort() async {
        let recorder = ProviderRecorder { source, _ in
            switch source {
            case .tmdb, .tvdb: return .authoritative(nil)
            case .tvmaze: return .authoritative("Japanese")   // English display name
            default: return nil
            }
        }
        let router = makeRouter(recorder)

        let language = await router.originalLanguage(for: show())

        XCTAssertEqual(language, "ja", "TVmaze fills last, normalized from its display name")
        XCTAssertEqual(recorder.count(of: .tvmaze), 1)
    }

    // MARK: - Whole-chain authoritative miss IS cached

    func testWholeChainAuthoritativeMissIsCached() async {
        let recorder = ProviderRecorder { source, _ in
            switch source {
            case .tmdb, .tvdb: return .authoritative(nil)   // movie chain, both reachable misses
            default: return nil
            }
        }
        let router = makeRouter(recorder)
        let item = movie()

        let first = await router.originalLanguage(for: item)
        let second = await router.originalLanguage(for: item)

        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(recorder.total, 2,
                       "An exhausted authoritative miss is cached: only the first play consults providers")
    }

    // MARK: - Normalization applies to whichever provider wins

    func testNormalizationAppliedToWinningProvider() async {
        // TheTVDB's ISO-639-2 `jpn` folds to `ja`.
        let recorder = ProviderRecorder { source, _ in
            switch source {
            case .tmdb: return .authoritative(nil)
            case .tvdb: return .authoritative("jpn")
            default: return nil
            }
        }
        let router = makeRouter(recorder)

        let language = await router.originalLanguage(for: movie())

        XCTAssertEqual(language, "ja")
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
