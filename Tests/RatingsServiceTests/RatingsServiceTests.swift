import XCTest
import CoreModels
import CoreNetworking
@testable import RatingsService

private let omdbBaseURL = URL(string: "https://www.omdbapi.com")!

private func movie(imdbID: String? = "tt0111161", native: [ExternalRating] = []) -> MediaItem {
    var ids: [String: String] = [:]
    if let imdbID { ids["Imdb"] = imdbID }
    return MediaItem(id: "i1", title: "Movie", kind: .movie, ratings: native, providerIDs: ids)
}

final class OMDbRatingsProviderTests: XCTestCase {
    private func omdbJSON() -> String {
        """
        {"Response":"True","imdbRating":"8.8","imdbVotes":"2,345,678",
         "Ratings":[
           {"Source":"Internet Movie Database","Value":"8.8/10"},
           {"Source":"Rotten Tomatoes","Value":"74%"},
           {"Source":"Metacritic","Value":"74/100"}
         ]}
        """
    }

    func testMapsOnlyIMDbFromOMDb() async {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/", json: omdbJSON())
        let provider = OMDbRatingsProvider(apiKey: "KEY", baseURL: omdbBaseURL, http: stub)

        let ratings = await provider.ratings(for: movie())

        // OMDb is not licensed to redistribute Rotten Tomatoes / Metacritic, so
        // the provider maps IMDb only even when OMDb returns all three.
        XCTAssertEqual(Set(ratings.map(\.source)), [.imdb])
        XCTAssertEqual(ratings.first { $0.source == .imdb }?.value, 8.8)
        XCTAssertEqual(ratings.first { $0.source == .imdb }?.scale, .outOfTen)
        XCTAssertEqual(ratings.first { $0.source == .imdb }?.ratingCount, 2_345_678)
    }

    func testReturnsEmptyWithoutIMDbID() async {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/", json: omdbJSON())
        let provider = OMDbRatingsProvider(apiKey: "KEY", baseURL: omdbBaseURL, http: stub)

        let ratings = await provider.ratings(for: movie(imdbID: nil))
        XCTAssertTrue(ratings.isEmpty)
        XCTAssertTrue(stub.sentPaths.isEmpty, "Should not hit the network without an IMDb id")
    }

    func testReturnsEmptyOnOMDbErrorResponse() async {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/", json: #"{"Response":"False","Error":"Movie not found!"}"#)
        let provider = OMDbRatingsProvider(apiKey: "KEY", baseURL: omdbBaseURL, http: stub)

        let ratings = await provider.ratings(for: movie())
        XCTAssertTrue(ratings.isEmpty)
    }

    func testReturnsEmptyOnTransportFailure() async {
        let stub = StubHTTPClient()
        stub.error = .serverUnreachable
        let provider = OMDbRatingsProvider(apiKey: "KEY", baseURL: omdbBaseURL, http: stub)

        let ratings = await provider.ratings(for: movie())
        XCTAssertTrue(ratings.isEmpty)
    }

    func testFallsBackToTopLevelImdbRating() async {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/", json: #"{"Response":"True","imdbRating":"7.5","Ratings":[]}"#)
        let provider = OMDbRatingsProvider(apiKey: "KEY", baseURL: omdbBaseURL, http: stub)

        let ratings = await provider.ratings(for: movie())
        XCTAssertEqual(ratings.first { $0.source == .imdb }?.value, 7.5)
    }
}

final class RatingsServiceConfigTests: XCTestCase {
    func testKeyFromEnvironment() {
        let config = RatingsServiceConfig.resolved(bundle: .main, environment: ["OMDB_API_KEY": "abc123"])
        XCTAssertEqual(config.omdbAPIKey, "abc123")
    }

    func testEmptyOrPlaceholderKeyResolvesToNil() {
        XCTAssertNil(RatingsServiceConfig(omdbAPIKey: "").omdbAPIKey)
        XCTAssertNil(RatingsServiceConfig(omdbAPIKey: "   ").omdbAPIKey)
        XCTAssertNil(RatingsServiceConfig(omdbAPIKey: "$(OMDB_API_KEY)").omdbAPIKey)
    }

    func testFactoryWithoutKeyReturnsDisabledProvider() async {
        let provider = RatingsServiceFactory.make(
            config: RatingsServiceConfig(omdbAPIKey: nil),
            cacheDirectory: nil
        )
        let ratings = await provider.ratings(for: movie())
        XCTAssertTrue(ratings.isEmpty)
    }
}

/// Counts how many times the underlying provider is actually hit.
private final class CountingProvider: ExternalRatingsProviding, @unchecked Sendable {
    private(set) var callCount = 0
    let result: [ExternalRating]
    init(result: [ExternalRating]) { self.result = result }
    func ratings(for item: MediaItem) async -> [ExternalRating] {
        callCount += 1
        return result
    }
}

final class RatingsCacheTests: XCTestCase {
    private let sample = [ExternalRating(source: .imdb, value: 8.8, scale: .outOfTen)]

    func testServesFromCacheWithinTTL() async {
        let cache = RatingsCache(ttl: 1000, now: { Date(timeIntervalSince1970: 0) })
        let base = CountingProvider(result: sample)
        let provider = CachingRatingsProvider(base: base, cache: cache)

        let first = await provider.ratings(for: movie())
        let second = await provider.ratings(for: movie())

        XCTAssertEqual(first, sample)
        XCTAssertEqual(second, sample)
        XCTAssertEqual(base.callCount, 1, "Second lookup should be served from cache")
    }

    func testRefetchesAfterTTLExpiry() async {
        let clock = MutableClock(start: 0)
        let cache = RatingsCache(ttl: 100, now: clock.now)
        let base = CountingProvider(result: sample)
        let provider = CachingRatingsProvider(base: base, cache: cache)

        _ = await provider.ratings(for: movie())
        clock.advance(by: 200) // past TTL
        _ = await provider.ratings(for: movie())

        XCTAssertEqual(base.callCount, 2, "Expired entry should trigger a refetch")
    }

    func testEmptyResultsAreNotCached() async {
        let cache = RatingsCache(ttl: 1000)
        let base = CountingProvider(result: [])
        let provider = CachingRatingsProvider(base: base, cache: cache)

        _ = await provider.ratings(for: movie())
        _ = await provider.ratings(for: movie())

        XCTAssertEqual(base.callCount, 2, "Empty (failed) results should not be cached")
    }

    func testDropsStaleAniListRatingForNonAnimeItem() async {
        // Reproduces the poisoned on-device entry: an AniList score pinned under
        // a live-action movie's IMDb id from an earlier misclassification.
        let cache = RatingsCache(ttl: 1000)
        await cache.store([ExternalRating(source: .anilist, value: 75, scale: .percent)],
                          forKey: "tt2140479")
        let base = CountingProvider(result: [])
        let provider = CachingRatingsProvider(base: base, cache: cache)

        let ratings = await provider.ratings(for: movie(imdbID: "tt2140479"))

        XCTAssertTrue(ratings.isEmpty, "AniList must never surface on a non-anime item")
        XCTAssertEqual(base.callCount, 0, "Served (and filtered) from cache, not refetched")
    }

    func testKeepsAniListRatingForAnimeItem() async {
        let cache = RatingsCache(ttl: 1000)
        await cache.store([ExternalRating(source: .anilist, value: 75, scale: .percent)],
                          forKey: "tt9999999")
        let base = CountingProvider(result: [])
        let provider = CachingRatingsProvider(base: base, cache: cache)

        // An item flagged anime (carries an AniList provider id) keeps its score.
        let animeItem = MediaItem(
            id: "a1", title: "Anime", kind: .movie,
            providerIDs: ["Imdb": "tt9999999", "AniList": "12345"]
        )
        let ratings = await provider.ratings(for: animeItem)

        XCTAssertEqual(ratings.map(\.source), [.anilist])
    }
}

/// A thread-safe mutable clock for TTL tests.
private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: TimeInterval
    init(start: TimeInterval) { seconds = start }
    func advance(by delta: TimeInterval) {
        lock.lock(); seconds += delta; lock.unlock()
    }
    var now: @Sendable () -> Date {
        { [self] in
            lock.lock(); defer { lock.unlock() }
            return Date(timeIntervalSince1970: seconds)
        }
    }
}
