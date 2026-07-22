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

    func testTrippedStateReadsAtomically() async {
        let breaker = ProviderCircuitBreaker()
        let closed = await breaker.trippedState
        XCTAssertFalse(closed.isTripped)
        XCTAssertNil(closed.reason)
        _ = await breaker.record(.failure(.unauthorized))
        let open = await breaker.trippedState
        XCTAssertTrue(open.isTripped)
        XCTAssertEqual(open.reason, .unauthorized)
    }

    func testResultCacheEntryCountReadsSharedCache() async {
        let cache = ProviderResultCache()
        await cache.store(nil, source: .tmdb, version: 1, requestKey: "k")
        let runtime = MetadataProviderRuntime(resultCache: cache, breakers: [:])
        let count = await runtime.resultCacheEntryCount()
        XCTAssertEqual(count, 1)
    }

    func testBreakerStatesReflectActiveBYOKCredential() async {
        // A user BYOK key's breaker is tripped; the built-in tmdb breaker stays healthy.
        let runtime = MetadataProviderRuntime.makeDefault()
        let credentialID = "usercred"
        let userBreaker = runtime.breakerRegistry.breaker(
            for: ProviderBreakerKey(source: .tmdb, credentialID: credentialID)
        )
        _ = await userBreaker.record(.failure(.unauthorized))

        // Without the active credential, diagnostics show the (healthy) built-in breaker.
        let builtIn = await runtime.breakerStates()
        XCTAssertEqual(builtIn.first { $0.source == .tmdb }?.isTripped, false)

        // With the active credential, the tmdb row reflects the tripped user-key breaker.
        let active = await runtime.breakerStates(tmdbCredentialID: credentialID)
        XCTAssertEqual(active.first { $0.source == .tmdb }?.isTripped, true)
        XCTAssertEqual(active.first { $0.source == .tmdb }?.trippedReason, "unauthorized")
    }

    func testBreakerStatesFallBackToBuiltInWhenActiveCredentialUnused() async {
        // An active credential that has never been used has no breaker yet — fall back
        // to the built-in row so the panel still lists tmdb.
        let runtime = MetadataProviderRuntime.makeDefault()
        let states = await runtime.breakerStates(tmdbCredentialID: "never-used")
        XCTAssertEqual(states.first { $0.source == .tmdb }?.isTripped, false)
        XCTAssertEqual(states.map(\.source), ProductionMetadataProviders.defaultSources)
    }
}
