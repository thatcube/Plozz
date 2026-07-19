import XCTest
import CoreModels
@testable import MetadataKit

/// A provider that records how many times it actually ran, to prove caching.
private final class CountingProvider: MetadataEnrichmentProvider, @unchecked Sendable {
    let id: MetadataSource
    let capabilities: Set<MetadataCapability> = [.canonicalText]
    let policy: ProviderPolicy
    private let output: MetadataEnrichment
    private let lock = NSLock()
    private var _calls = 0

    init(id: MetadataSource, version: Int, output: MetadataEnrichment) {
        self.id = id
        self.policy = ProviderPolicy(version: version)
        self.output = output
    }

    func enrich(_ query: MetadataQuery, missing: Set<MetadataField>) async -> MetadataEnrichment {
        lock.lock(); _calls += 1; lock.unlock()
        return output
    }

    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
}

final class ProviderResultCacheTests: XCTestCase {
    private func query(title: String = "Item") -> MetadataQuery {
        MetadataQuery(
            contentType: .movie, kind: .movie, title: title, alternateTitle: nil, year: 2020,
            seasonNumber: nil, episodeNumber: nil, animeIDs: AnimeIDs(), providerIDs: [:]
        )
    }

    private func sourced(_ s: String, _ src: MetadataSource) -> MetadataEnrichment {
        MetadataEnrichment(overview: SourcedValue(value: s, source: src))
    }

    func testSecondCallIsServedFromCache() async {
        let counting = CountingProvider(id: .tvdb, version: 1, output: sourced("x", .tvdb))
        let cache = ProviderResultCache()
        let cached = CachedEnrichmentProvider(base: counting, cache: cache)

        _ = await cached.enrich(query(), missing: [.overview])
        _ = await cached.enrich(query(), missing: [.overview])
        XCTAssertEqual(counting.calls, 1, "The second identical request must hit the cache")
    }

    func testNegativeResultIsCached() async {
        let counting = CountingProvider(id: .tvdb, version: 1, output: MetadataEnrichment())
        let cache = ProviderResultCache()
        let cached = CachedEnrichmentProvider(base: counting, cache: cache)

        let first = await cached.enrich(query(), missing: [.overview])
        let second = await cached.enrich(query(), missing: [.overview])
        XCTAssertTrue(first.isEmpty)
        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(counting.calls, 1, "A negative (empty) result is remembered too")
    }

    func testNamespaceIsolationBySource() async {
        let cache = ProviderResultCache()
        await cache.store(sourced("a", .tvdb), source: .tvdb, version: 1, requestKey: "k")
        // A different source with the same request key is a different entry.
        let miss = await cache.cached(source: .tmdb, version: 1, requestKey: "k")
        let hit = await cache.cached(source: .tvdb, version: 1, requestKey: "k")
        XCTAssertNil(miss)
        XCTAssertNotNil(hit)
    }

    func testVersionBumpInvalidatesOnlyThatProvider() async {
        let cache = ProviderResultCache()
        await cache.store(sourced("a", .tvdb), source: .tvdb, version: 1, requestKey: "k")
        await cache.store(sourced("b", .tmdb), source: .tmdb, version: 1, requestKey: "k")
        // Reading TheTVDB at a new version is a miss (policy/version change), while
        // TMDb at its unchanged version still hits.
        let tvdbNewVersion = await cache.cached(source: .tvdb, version: 2, requestKey: "k")
        let tmdbSame = await cache.cached(source: .tmdb, version: 1, requestKey: "k")
        XCTAssertNil(tvdbNewVersion)
        XCTAssertNotNil(tmdbSame)
    }

    func testInvalidateNegativesOnlyDropsNegatives() async {
        let cache = ProviderResultCache()
        await cache.store(sourced("pos", .tvdb), source: .tvdb, version: 1, requestKey: "positive")
        await cache.store(nil, source: .tvdb, version: 1, requestKey: "negative")

        await cache.invalidateNegatives(source: .tvdb, version: 1)

        let positive = await cache.cached(source: .tvdb, version: 1, requestKey: "positive")
        let negative = await cache.cached(source: .tvdb, version: 1, requestKey: "negative")
        XCTAssertNotNil(positive)
        XCTAssertNil(negative, "Recovery clears this provider's negatives immediately")
    }

    func testDifferentMissingSetsAreNotConflated() async {
        let counting = CountingProvider(id: .tvdb, version: 1, output: sourced("x", .tvdb))
        let cache = ProviderResultCache()
        let cached = CachedEnrichmentProvider(base: counting, cache: cache)

        _ = await cached.enrich(query(), missing: [.overview])
        _ = await cached.enrich(query(), missing: [.overview, .posterURL])
        XCTAssertEqual(counting.calls, 2, "A wider request must not be served a narrower cached result")
    }

    func testExpiryIsHonored() async {
        let clock = MutableClock(Date(timeIntervalSince1970: 1000))
        let cache = ProviderResultCache(negativeTTL: 10, now: { clock.value })
        await cache.store(nil, source: .tvdb, version: 1, requestKey: "k")
        let fresh = await cache.cached(source: .tvdb, version: 1, requestKey: "k")
        XCTAssertNotNil(fresh)
        clock.value = Date(timeIntervalSince1970: 1011)
        let expired = await cache.cached(source: .tvdb, version: 1, requestKey: "k")
        XCTAssertNil(expired, "Expired entry is a miss")
    }
}

/// A tiny thread-safe mutable clock for the expiry test.
private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Date
    init(_ value: Date) { _value = value }
    var value: Date {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
