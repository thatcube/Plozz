import XCTest
import CoreModels
@testable import MetadataKit

/// Step 9 — locks the TMDB bring-your-own-key credential dimension: the cache and
/// circuit-breaker keys gain a credential identity so one user's key can't read or
/// poison another credential's cached results / breaker state, while the built-in
/// (credential-less) path stays byte-identical to pre-Step-9.
final class TMDbBYOKTests: XCTestCase {

    // MARK: - Credential identity

    func testUserTokenProducesStableOpaqueCredentialIDNeverTheRawKey() {
        let token = "eyJraWQ.some.secret.v4.read.token"
        let a = TMDbAccess.userToken(token).credentialID
        let b = TMDbAccess.userToken(token).credentialID
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b, "Same key => same credential id (stable)")
        XCTAssertNotEqual(a, token, "The credential id must never be the raw key")
        XCTAssertFalse(a?.contains(token) ?? true, "The raw key must not be embedded")
        XCTAssertNotEqual(TMDbAccess.userToken("other").credentialID, a, "Different keys differ")
    }

    func testBuiltInAccessPathsHaveNoCredentialID() {
        XCTAssertNil(TMDbAccess.directToken("maintainer").credentialID)
        XCTAssertNil(TMDbAccess.proxy(baseURL: URL(string: "https://proxy.example")!).credentialID)
        XCTAssertNil(TMDbAccess.disabled.credentialID)
    }

    func testWithUserTokenOverridesBuiltInAndBlankIsNoOp() {
        let builtIn = MetadataProviderConfig(tmdb: .proxy(baseURL: URL(string: "https://proxy.example")!))
        // Present key wins over the built-in proxy.
        if case .userToken(let t) = builtIn.withUserToken("my-key").tmdb {
            XCTAssertEqual(t, "my-key")
        } else {
            XCTFail("A present BYOK key must override the built-in access")
        }
        // Blank / whitespace / nil => unchanged built-in path.
        XCTAssertEqual(builtIn.withUserToken(nil).tmdb, builtIn.tmdb)
        XCTAssertEqual(builtIn.withUserToken("   ").tmdb, builtIn.tmdb)
    }

    func testProductionCredentialIDOnlyForTMDbUserToken() {
        let byok = MetadataProviderConfig(tmdb: .userToken("k"))
        XCTAssertNotNil(ProductionMetadataProviders.credentialID(for: .tmdb, providerConfig: byok))
        XCTAssertNil(ProductionMetadataProviders.credentialID(for: .tvdb, providerConfig: byok),
                     "Only TMDb is credentialed; other sources stay nil")
        let builtIn = MetadataProviderConfig(tmdb: .disabled)
        XCTAssertNil(ProductionMetadataProviders.credentialID(for: .tmdb, providerConfig: builtIn),
                     "Built-in TMDb path carries no credential")
    }

    // MARK: - Cache key byte-identity + isolation

    func testAbsentCredentialKeyIsByteIdenticalToPreStep9() {
        XCTAssertEqual(ProviderResultCache.key(source: .tvdb, version: 1, requestKey: "k"), "tvdb#1|k")
        XCTAssertEqual(ProviderResultCache.namespacePrefix(source: .tvdb, version: 1), "tvdb#1|")
    }

    func testCredentialedKeyGetsItsOwnNamespace() {
        XCTAssertEqual(
            ProviderResultCache.key(source: .tmdb, version: 2, requestKey: "k", credential: "abcd"),
            "tmdb#2@abcd|k"
        )
    }

    func testNoCrossCredentialCacheBleed() async {
        let cache = ProviderResultCache()
        // A positive for credential A, a remembered negative for credential B.
        await cache.store(overviewEnrichment("A", .tmdb), source: .tmdb, version: 1, requestKey: "k", credential: "A")
        await cache.store(nil, source: .tmdb, version: 1, requestKey: "k", credential: "B")

        // Each credential sees only its own entry.
        let a = await cache.cached(source: .tmdb, version: 1, requestKey: "k", credential: "A")
        let b = await cache.cached(source: .tmdb, version: 1, requestKey: "k", credential: "B")
        XCTAssertEqual(a??.overview?.value, "A")
        XCTAssertEqual(b, .some(nil), "Credential B has its own remembered negative")

        // The built-in (nil) path is a third, separate namespace — a miss.
        let builtIn = await cache.cached(source: .tmdb, version: 1, requestKey: "k")
        XCTAssertNil(builtIn, "The credential-less path must not read a credentialed entry")
    }

    func testInvalidateCredentialDropsOnlyThatCredential() async {
        let cache = ProviderResultCache()
        await cache.store(overviewEnrichment("A", .tmdb), source: .tmdb, version: 1, requestKey: "k", credential: "A")
        await cache.store(overviewEnrichment("B", .tmdb), source: .tmdb, version: 1, requestKey: "k", credential: "B")
        await cache.store(overviewEnrichment("plain", .tvdb), source: .tvdb, version: 1, requestKey: "k")

        await cache.invalidate(credential: "A")

        let a = await cache.cached(source: .tmdb, version: 1, requestKey: "k", credential: "A")
        let b = await cache.cached(source: .tmdb, version: 1, requestKey: "k", credential: "B")
        let plain = await cache.cached(source: .tvdb, version: 1, requestKey: "k")
        XCTAssertNil(a, "Credential A's entries are gone")
        XCTAssertEqual(b??.overview?.value, "B", "Credential B is untouched")
        XCTAssertEqual(plain??.overview?.value, "plain", "The built-in path is untouched")
    }

    // MARK: - Breaker registry isolation

    func testRegistryVendsStableInstancePerKeyAndIsolatesCredentials() {
        let registry = ProviderBreakerRegistry()
        let a1 = registry.breaker(for: ProviderBreakerKey(source: .tmdb, credentialID: "A"))
        let a2 = registry.breaker(for: ProviderBreakerKey(source: .tmdb, credentialID: "A"))
        let b1 = registry.breaker(for: ProviderBreakerKey(source: .tmdb, credentialID: "B"))
        XCTAssertTrue(a1 === a2, "Same key => same stable breaker instance")
        XCTAssertFalse(a1 === b1, "Different credentials => different breakers")
    }

    func testBadKeyTripsOnlyThatCredentialsBreakerAndRemovalClearsIt() async {
        let cache = ProviderResultCache()
        let registry = ProviderBreakerRegistry()
        let credA = TMDbAccess.userToken("bad-key").credentialID!
        let credB = TMDbAccess.userToken("good-key").credentialID!

        let breakerA = registry.breaker(for: ProviderBreakerKey(source: .tmdb, credentialID: credA))
        let providerA = ProgrammableProvider(id: .tmdb, health: .failure(.unauthorized))
        let wrappedA = ResilientEnrichmentProvider(base: providerA, breaker: breakerA, cache: cache, credentialID: credA)

        // A 401 on key A trips its breaker (auth failures open immediately).
        _ = await wrappedA.enrichReporting(testQuery(), missing: [.overview])
        let aTripped = await breakerA.isTripped
        XCTAssertTrue(aTripped, "Key A's bad-credential 401 opens its own breaker")

        // Key B's breaker is untouched.
        let breakerB = registry.breaker(for: ProviderBreakerKey(source: .tmdb, credentialID: credB))
        let bTripped = await breakerB.isTripped
        XCTAssertFalse(bTripped, "A different key's breaker is unaffected by key A's 401")

        // Removing/replacing key A clears its negative state.
        await registry.resetBreakers(credentialID: credA)
        let aAfter = await breakerA.isTripped
        XCTAssertFalse(aAfter, "Removing the bad key clears that credential's breaker trip")
    }

    func testNoCrossCredentialPositiveBleedThroughResilientProvider() async {
        let cache = ProviderResultCache()
        let registry = ProviderBreakerRegistry()
        let credA = "aaaa", credB = "bbbb"
        let query = testQuery()

        // Key A resolves and caches a positive.
        let provA = ProgrammableProvider(id: .tmdb, output: overviewEnrichment("A-art", .tmdb), health: .ok)
        let wrappedA = ResilientEnrichmentProvider(
            base: provA,
            breaker: registry.breaker(for: ProviderBreakerKey(source: .tmdb, credentialID: credA)),
            cache: cache,
            credentialID: credA
        )
        _ = await wrappedA.enrichReporting(query, missing: [.overview])

        // Key B for the SAME item must NOT be served key A's cached positive.
        let provB = ProgrammableProvider(id: .tmdb, output: MetadataEnrichment(), health: .empty)
        let wrappedB = ResilientEnrichmentProvider(
            base: provB,
            breaker: registry.breaker(for: ProviderBreakerKey(source: .tmdb, credentialID: credB)),
            cache: cache,
            credentialID: credB
        )
        let respB = await wrappedB.enrichReporting(query, missing: [.overview])
        XCTAssertTrue(respB.enrichment.isEmpty, "Key B must not read key A's private cached result")
        XCTAssertEqual(provB.calls, 1, "Key B is a cache miss and actually hit its own provider")
    }

    // MARK: - Runtime convenience

    func testRuntimeInvalidateCredentialClearsCacheAndBreaker() async {
        let runtime = MetadataProviderRuntime.makeDefault()
        let cred = TMDbAccess.userToken("k").credentialID!
        // Seed a cached positive and a tripped breaker for this credential.
        await runtime.resultCache.store(overviewEnrichment("x", .tmdb), source: .tmdb, version: 1, requestKey: "k", credential: cred)
        let breaker = runtime.breakerRegistry.breaker(for: ProviderBreakerKey(source: .tmdb, credentialID: cred))
        _ = await breaker.record(.failure(.unauthorized))
        let before = await breaker.isTripped
        XCTAssertTrue(before)

        await runtime.invalidateCredential(cred)

        let cached = await runtime.resultCache.cached(source: .tmdb, version: 1, requestKey: "k", credential: cred)
        let after = await breaker.isTripped
        XCTAssertNil(cached, "Credential cache cleared")
        XCTAssertFalse(after, "Credential breaker reset")
    }

    func testBuiltInBreakerMapUnchangedByRegistry() async {
        // The Step-6 diagnostics projection (source-keyed) is byte-identical: the
        // nil-credential breaker vended by the registry is the same instance exposed
        // via `breakers`.
        let runtime = MetadataProviderRuntime.makeDefault()
        let viaMap = runtime.breakers[.tmdb]
        let viaRegistry = runtime.breakerRegistry.breaker(for: ProviderBreakerKey(source: .tmdb))
        XCTAssertTrue(viaMap === viaRegistry)
    }
}
