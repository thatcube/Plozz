import XCTest
import CoreModels
@testable import MetadataKit

/// Locks the Step 6 shared ``MetadataProviderRuntime`` diagnostics projection and its
/// wiring into the production pipeline.
final class MetadataProviderRuntimeTests: XCTestCase {
    func testMakeDefaultCoversEveryDefaultSource() async {
        let runtime = MetadataProviderRuntime.makeDefault()
        let states = await runtime.breakerStates()
        XCTAssertEqual(states.map(\.source), ProductionMetadataProviders.defaultSources)
        XCTAssertTrue(states.allSatisfy { !$0.isTripped })
    }

    func testBreakerStatesReflectTrippedReason() async {
        let breaker = ProviderCircuitBreaker()
        _ = await breaker.record(.failure(.unauthorized)) // auth trips immediately
        let runtime = MetadataProviderRuntime(
            resultCache: ProviderResultCache(),
            breakers: [.tmdb: breaker]
        )
        let states = await runtime.breakerStates()
        let tmdb = states.first { $0.source == .tmdb }
        XCTAssertEqual(tmdb?.isTripped, true)
        XCTAssertEqual(tmdb?.trippedReason, "unauthorized")
    }

    func testRateLimitedReasonDescription() async {
        let breaker = ProviderCircuitBreaker()
        _ = await breaker.record(.failure(.rateLimited(retryAfter: 30)))
        let runtime = MetadataProviderRuntime(resultCache: ProviderResultCache(), breakers: [.tvdb: breaker])
        let states = await runtime.breakerStates()
        XCTAssertEqual(states.first { $0.source == .tvdb }?.trippedReason, "rate limited")
    }

    func testResultCacheEntryCountReadsSharedCache() async {
        let cache = ProviderResultCache()
        await cache.store(nil, source: .tmdb, version: 1, requestKey: "k")
        let runtime = MetadataProviderRuntime(resultCache: cache, breakers: [:])
        let count = await runtime.resultCacheEntryCount()
        XCTAssertEqual(count, 1)
    }

    func testPipelineUsesRuntimeProviders() async {
        // A pipeline built with the shared runtime registers the default provider set.
        let runtime = MetadataProviderRuntime.makeDefault()
        let pipeline = ProductionMetadataProviders.makePipeline(runtime: runtime)
        let sources = await pipeline.registeredSources
        XCTAssertEqual(sources, Set(ProductionMetadataProviders.defaultSources))
    }
}
