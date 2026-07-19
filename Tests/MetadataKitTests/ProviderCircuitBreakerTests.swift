import XCTest
import CoreModels
@testable import MetadataKit

final class ProviderCircuitBreakerTests: XCTestCase {
    // MARK: Breaker state machine

    func testAuthFailureTripsImmediatelyWithAuthCooldown() async {
        let clock = OutageTestClock()
        let breaker = ProviderCircuitBreaker(
            policy: .init(authCooldown: 300), now: clock.nowClosure
        )
        _ = await breaker.record(.failure(.unauthorized))
        var allowed = await breaker.allow()
        XCTAssertFalse(allowed, "401/403 opens immediately")
        clock.advance(299)
        allowed = await breaker.allow()
        XCTAssertFalse(allowed)
        clock.advance(2)
        allowed = await breaker.allow()
        XCTAssertTrue(allowed, "Auth cooldown elapsed → half-open")
    }

    func testTransientOpensOnlyAfterThreshold() async {
        let clock = OutageTestClock()
        let breaker = ProviderCircuitBreaker(policy: .init(failureThreshold: 3), now: clock.nowClosure)
        _ = await breaker.record(.failure(.transient))
        _ = await breaker.record(.failure(.transient))
        var tripped = await breaker.isTripped
        XCTAssertFalse(tripped, "Two transient failures below threshold")
        _ = await breaker.record(.failure(.transient))
        tripped = await breaker.isTripped
        XCTAssertTrue(tripped, "Third consecutive transient trips")
    }

    func testRateLimitHonorsRetryAfter() async {
        let clock = OutageTestClock()
        let breaker = ProviderCircuitBreaker(now: clock.nowClosure)
        _ = await breaker.record(.failure(.rateLimited(retryAfter: 30)))
        clock.advance(29)
        var allowed = await breaker.allow()
        XCTAssertFalse(allowed)
        clock.advance(2)
        allowed = await breaker.allow()
        XCTAssertTrue(allowed, "Retry-After window elapsed")
    }

    func testSuccessAfterCooldownReportsRecovery() async {
        let clock = OutageTestClock()
        let breaker = ProviderCircuitBreaker(policy: .init(failureThreshold: 1, transientCooldown: 60), now: clock.nowClosure)
        _ = await breaker.record(.failure(.transient))
        clock.advance(61)
        let recovered = await breaker.record(.ok)
        XCTAssertTrue(recovered, "Closing a tripped breaker reports recovery")
        let tripped = await breaker.isTripped
        XCTAssertFalse(tripped)
    }

    func testResetClosesImmediately() async {
        let clock = OutageTestClock()
        let breaker = ProviderCircuitBreaker(policy: .init(authCooldown: 10_000), now: clock.nowClosure)
        _ = await breaker.record(.failure(.unauthorized))
        await breaker.reset()
        let allowed = await breaker.allow()
        XCTAssertTrue(allowed, "Credential change resets the breaker despite the auth cooldown")
    }

    func testAuthAndRateHaveIndependentCooldowns() async {
        let clock = OutageTestClock()
        let auth = ProviderCircuitBreaker(policy: .init(authCooldown: 300), now: clock.nowClosure)
        let rate = ProviderCircuitBreaker(now: clock.nowClosure)
        _ = await auth.record(.failure(.unauthorized))
        _ = await rate.record(.failure(.rateLimited(retryAfter: 30)))
        clock.advance(31)
        let rateAllowed = await rate.allow()
        let authAllowed = await auth.allow()
        XCTAssertTrue(rateAllowed, "The 30s rate cooldown elapsed")
        XCTAssertFalse(authAllowed, "The 300s auth cooldown has not — cooldowns are independent")
    }

    // MARK: Resilient decorator

    func testWarmCacheServedDuringOutage() async {
        let cache = ProviderResultCache()
        let base = ProgrammableProvider(id: .tvdb, output: overviewEnrichment("cached", .tvdb), health: .ok)
        let clock = OutageTestClock()
        let resilient = ResilientEnrichmentProvider(
            base: base, breaker: ProviderCircuitBreaker(now: clock.nowClosure), cache: cache
        )
        // Warm the cache.
        _ = await resilient.enrich(testQuery(), missing: [.overview])
        XCTAssertEqual(base.calls, 1)
        // Now the provider "goes down" — a warm hit must still serve last-known.
        base.program(output: MetadataEnrichment(), health: .failure(.transient))
        let out = await resilient.enrich(testQuery(), missing: [.overview])
        XCTAssertEqual(out.overview?.value, "cached")
        XCTAssertEqual(base.calls, 1, "A warm hit must not re-hit a downed provider")
    }

    func testTransientFailureIsNotCachedAsNegative() async {
        let cache = ProviderResultCache()
        let base = ProgrammableProvider(id: .tvdb, output: MetadataEnrichment(), health: .failure(.transient))
        let clock = OutageTestClock()
        let resilient = ResilientEnrichmentProvider(
            base: base, breaker: ProviderCircuitBreaker(policy: .init(failureThreshold: 5), now: clock.nowClosure), cache: cache
        )
        _ = await resilient.enrich(testQuery(), missing: [.overview])
        // A failure must not persist a negative; the next attempt calls the provider again.
        base.program(output: overviewEnrichment("recovered", .tvdb), health: .ok)
        let out = await resilient.enrich(testQuery(), missing: [.overview])
        XCTAssertEqual(out.overview?.value, "recovered")
        XCTAssertEqual(base.calls, 2, "A transient failure is retried, not cached as a negative")
    }

    func testTrippedBreakerSkipsProviderOnColdMiss() async {
        let cache = ProviderResultCache()
        let base = ProgrammableProvider(id: .tvdb, output: MetadataEnrichment(), health: .failure(.unauthorized))
        let clock = OutageTestClock()
        let resilient = ResilientEnrichmentProvider(
            base: base, breaker: ProviderCircuitBreaker(policy: .init(authCooldown: 300), now: clock.nowClosure), cache: cache
        )
        _ = await resilient.enrich(testQuery(), missing: [.overview]) // trips (auth)
        XCTAssertEqual(base.calls, 1)
        _ = await resilient.enrich(testQuery(title: "Other"), missing: [.overview]) // cold miss, breaker open
        XCTAssertEqual(base.calls, 1, "A tripped breaker skips the provider on a cold miss")
    }

    func testRecoveryClearsCachedNegatives() async {
        let cache = ProviderResultCache()
        // Seed a negative for a different item under the same provider namespace.
        let negKey = CachedEnrichmentProvider.requestKey(query: testQuery(title: "Gap"), missing: [.overview])
        await cache.store(nil, source: .tvdb, version: 1, requestKey: negKey)

        let base = ProgrammableProvider(id: .tvdb, output: MetadataEnrichment(), health: .failure(.transient))
        let clock = OutageTestClock()
        let resilient = ResilientEnrichmentProvider(
            base: base, breaker: ProviderCircuitBreaker(policy: .init(failureThreshold: 1, transientCooldown: 60), now: clock.nowClosure), cache: cache
        )
        _ = await resilient.enrich(testQuery(), missing: [.overview]) // trips
        clock.advance(61)
        base.program(output: overviewEnrichment("back", .tvdb), health: .ok)
        _ = await resilient.enrich(testQuery(), missing: [.overview]) // recovers

        let gap = await cache.cached(source: .tvdb, version: 1, requestKey: negKey)
        XCTAssertNil(gap, "Recovery drops the provider's stale negatives so gaps refill")
    }

    // MARK: Retry-After parsing

    func testRetryAfterSecondsParsing() {
        let url = URL(string: "https://x")!
        let withSeconds = HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "42"])!
        XCTAssertEqual(MetadataHTTP.retryAfterSeconds(withSeconds), 42)
        let withoutHeader = HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: [:])!
        XCTAssertNil(MetadataHTTP.retryAfterSeconds(withoutHeader))
        let httpDate = HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "Wed, 21 Oct 2026 07:28:00 GMT"])!
        XCTAssertNil(MetadataHTTP.retryAfterSeconds(httpDate), "An HTTP-date falls back to the breaker's default cooldown")
    }
}
