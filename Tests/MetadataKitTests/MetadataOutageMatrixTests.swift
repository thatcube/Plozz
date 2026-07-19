import XCTest
import CoreModels
@testable import MetadataKit

/// The dual-provider outage matrix: two providers serving the same field, each with
/// its own circuit breaker over a shared namespaced cache, exercised end-to-end
/// through the pipeline. Proves graceful degradation to cached/last-known and
/// independent per-provider recovery.
final class MetadataOutageMatrixTests: XCTestCase {
    private func flatConfig() -> MetadataEnrichmentConfig {
        MetadataEnrichmentConfig(order: [.tvdb, .tmdb], priority: MetadataPriorityPolicy(rules: []))
    }

    private struct Rig {
        let pipeline: MetadataEnrichmentPipeline
        let a: ProgrammableProvider
        let b: ProgrammableProvider
        let breakerA: ProviderCircuitBreaker
        let breakerB: ProviderCircuitBreaker
        let cache: ProviderResultCache
    }

    private func makeRig(clock: OutageTestClock) -> Rig {
        let cache = ProviderResultCache(now: clock.nowClosure)
        let a = ProgrammableProvider(id: .tvdb, capabilities: [.canonicalText, .poster])
        let b = ProgrammableProvider(id: .tmdb, capabilities: [.canonicalText, .poster])
        let breakerA = ProviderCircuitBreaker(policy: .init(failureThreshold: 1), now: clock.nowClosure)
        let breakerB = ProviderCircuitBreaker(policy: .init(failureThreshold: 1), now: clock.nowClosure)
        let pipeline = MetadataEnrichmentPipeline(
            providers: [
                ResilientEnrichmentProvider(base: a, breaker: breakerA, cache: cache),
                ResilientEnrichmentProvider(base: b, breaker: breakerB, cache: cache),
            ],
            config: flatConfig()
        )
        return Rig(pipeline: pipeline, a: a, b: b, breakerA: breakerA, breakerB: breakerB, cache: cache)
    }

    // 1. Cold cache, both providers down → empty result, no crash.
    func testColdCacheBothDisabled() async {
        let rig = makeRig(clock: OutageTestClock())
        rig.a.program(output: MetadataEnrichment(), health: .failure(.transient))
        rig.b.program(output: MetadataEnrichment(), health: .failure(.transient))
        let out = await rig.pipeline.enrich(testQuery(), requesting: [.overview], tier: .foregroundFill)
        XCTAssertNil(out.overview)
    }

    // 2. Warm cache, both providers down → last-known served from cache.
    func testWarmCacheBothDisabledServesLastKnown() async {
        let rig = makeRig(clock: OutageTestClock())
        rig.a.program(output: overviewEnrichment("A last-known", .tvdb), health: .ok)
        _ = await rig.pipeline.enrich(testQuery(), requesting: [.overview], tier: .foregroundFill)
        XCTAssertEqual(rig.a.calls, 1)

        // Both sources now fail; the warm cache must still answer.
        rig.a.program(output: MetadataEnrichment(), health: .failure(.transient))
        rig.b.program(output: MetadataEnrichment(), health: .failure(.transient))
        let out = await rig.pipeline.enrich(testQuery(), requesting: [.overview], tier: .foregroundFill)
        XCTAssertEqual(out.overview?.value, "A last-known")
        XCTAssertEqual(rig.a.calls, 1, "Served from cache, not a re-hit of the downed provider")
    }

    // 3. Both unauthorized → empty result and both breakers tripped.
    func testBothUnauthorizedTripsBothBreakers() async {
        let rig = makeRig(clock: OutageTestClock())
        rig.a.program(output: MetadataEnrichment(), health: .failure(.unauthorized))
        rig.b.program(output: MetadataEnrichment(), health: .failure(.unauthorized))
        let out = await rig.pipeline.enrich(testQuery(), requesting: [.overview], tier: .foregroundFill)
        XCTAssertNil(out.overview)
        let aTripped = await rig.breakerA.isTripped
        let bTripped = await rig.breakerB.isTripped
        XCTAssertTrue(aTripped)
        XCTAssertTrue(bTripped)
    }

    // 4. Both rate-limited with different Retry-After → independent recovery.
    func testBothRateLimitedRecoverIndependently() async {
        let clock = OutageTestClock()
        let rig = makeRig(clock: clock)
        rig.a.program(output: MetadataEnrichment(), health: .failure(.rateLimited(retryAfter: 10)))
        rig.b.program(output: MetadataEnrichment(), health: .failure(.rateLimited(retryAfter: 100)))
        _ = await rig.pipeline.enrich(testQuery(), requesting: [.overview], tier: .foregroundFill)

        var aTripped = await rig.breakerA.isTripped
        var bTripped = await rig.breakerB.isTripped
        XCTAssertTrue(aTripped)
        XCTAssertTrue(bTripped)

        // Advance past A's 10s window but not B's 100s window; A recovers, B stays down.
        clock.advance(11)
        rig.a.program(output: overviewEnrichment("A recovered", .tvdb), health: .ok)
        let out = await rig.pipeline.enrich(testQuery(), requesting: [.overview], tier: .foregroundFill)
        XCTAssertEqual(out.overview?.value, "A recovered")

        aTripped = await rig.breakerA.isTripped
        bTripped = await rig.breakerB.isTripped
        XCTAssertFalse(aTripped, "A's Retry-After elapsed and it recovered")
        XCTAssertTrue(bTripped, "B's longer Retry-After has not elapsed — cooldowns are independent")
    }

    // 5. Total outage then full recovery → both fill again.
    func testTotalOutageThenRecovery() async {
        let clock = OutageTestClock()
        let rig = makeRig(clock: clock)
        rig.a.program(output: MetadataEnrichment(), health: .failure(.transient))
        rig.b.program(output: MetadataEnrichment(), health: .failure(.transient))
        let down = await rig.pipeline.enrich(testQuery(), requesting: [.overview, .posterURL], tier: .foregroundFill)
        XCTAssertTrue(down.isEmpty)

        clock.advance(61) // default transient cooldown 60s
        rig.a.program(output: overviewEnrichment("A", .tvdb), health: .ok)
        rig.b.program(
            output: MetadataEnrichment(posterURL: SourcedValue(value: URL(string: "https://p/p.jpg")!, source: .tmdb)),
            health: .ok
        )
        let up = await rig.pipeline.enrich(testQuery(), requesting: [.overview, .posterURL], tier: .foregroundFill)
        XCTAssertEqual(up.overview?.value, "A")
        XCTAssertNotNil(up.posterURL)
    }
}
