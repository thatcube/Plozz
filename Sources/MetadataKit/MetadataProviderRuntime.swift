import Foundation
import CoreModels

/// Composite identity for a per-source circuit breaker: the ``MetadataSource`` plus an
/// optional **credential** identity.
///
/// A `nil` `credentialID` is the built-in / app-global credential — byte-identical to
/// the pre-Step-9 source-only key, so every bundled provider's breaker is unchanged. A
/// non-`nil` value (e.g. a hash of a user's BYOK TMDB key — never the raw key) scopes
/// the breaker to exactly that credential, so one key's 401/credential failure trips
/// only its own breaker and can never open (or be masked by) another key's — or the
/// built-in path's — breaker.
public struct ProviderBreakerKey: Hashable, Sendable {
    public let source: MetadataSource
    public let credentialID: String?

    public init(source: MetadataSource, credentialID: String? = nil) {
        self.source = source
        self.credentialID = credentialID
    }
}

/// A thread-safe registry that vends a **stable** ``ProviderCircuitBreaker`` per
/// ``ProviderBreakerKey``, creating one lazily on first use and caching it thereafter.
///
/// The pipeline is rebuilt per share, but the breaker for a given (source, credential)
/// must be the *same* instance across those rebuilds so a source's — or a specific
/// BYOK key's — health persists. Seeded with the built-in (nil-credential) breakers so
/// looking one up by `ProviderBreakerKey(source:)` returns the exact instance the
/// shared runtime exposes to diagnostics; a new credential (a user's BYOK key) gets a
/// fresh, isolated breaker the first time it is used.
///
/// Reference vending is synchronous (a plain lock), even though the breaker's own
/// methods are `async` — so it slots into the synchronous provider-wrapping map without
/// forcing that path to become async.
public final class ProviderBreakerRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var breakers: [ProviderBreakerKey: ProviderCircuitBreaker]
    private let makeBreaker: @Sendable () -> ProviderCircuitBreaker

    public init(
        seed: [ProviderBreakerKey: ProviderCircuitBreaker] = [:],
        makeBreaker: @escaping @Sendable () -> ProviderCircuitBreaker = { ProviderCircuitBreaker() }
    ) {
        self.breakers = seed
        self.makeBreaker = makeBreaker
    }

    /// The stable breaker for `key`, creating and caching one on first use.
    public func breaker(for key: ProviderBreakerKey) -> ProviderCircuitBreaker {
        lock.lock(); defer { lock.unlock() }
        if let existing = breakers[key] { return existing }
        let created = makeBreaker()
        breakers[key] = created
        return created
    }

    /// The already-registered breaker for `key`, or `nil` if none has been vended —
    /// used to reset a credential's breaker on key removal without materializing one.
    public func existingBreaker(for key: ProviderBreakerKey) -> ProviderCircuitBreaker? {
        lock.lock(); defer { lock.unlock() }
        return breakers[key]
    }

    /// Resets every registered breaker scoped to `credentialID` — used when a user
    /// replaces or removes their BYOK key so its bad-key auth trip doesn't linger the
    /// full auth cooldown before the (new/removed) credential is retried.
    public func resetBreakers(credentialID: String) async {
        lock.lock()
        let matching = breakers.filter { $0.key.credentialID == credentialID }.map(\.value)
        lock.unlock()
        for breaker in matching { await breaker.reset() }
    }
}

/// A **shared** set of the live resilience objects a metadata pipeline runs on —
/// the provider-and-version-namespaced ``ProviderResultCache`` and one
/// ``ProviderCircuitBreaker`` per source.
///
/// Its purpose is Step 6 diagnostics: by constructing these objects up front and
/// handing the *same* instances to ``ProductionMetadataProviders/make(...)``, the
/// composition root (`AppShell`) keeps references it can later sample for the
/// Settings "Diagnostics" section (result-cache size, per-provider breaker state)
/// without reaching into the pipeline's internals.
///
/// Sharing one runtime across every share also makes the caches behave correctly at
/// the item level: a result-cache entry is keyed by provider+version+whole-item
/// identity (never by share), so the same title resolved for two shares dedupes; and
/// a breaker reflects a source's global health (a source being down is not
/// per-share). When **no** runtime is injected, ``ProductionMetadataProviders``
/// keeps its prior behaviour of minting fresh objects per pipeline, so the Step 5
/// default is unchanged.
public struct MetadataProviderRuntime: Sendable {
    /// The shared result cache used by every wrapped provider.
    public let resultCache: ProviderResultCache
    /// One breaker per **built-in** source, keyed by ``MetadataSource``. This is the
    /// app-global (credential-less) health map diagnostics project from, unchanged
    /// since Step 6 — a TheTVDB 429 applies to every share, so it is a per-source fact.
    public let breakers: [MetadataSource: ProviderCircuitBreaker]
    /// Step 9: the credential-aware breaker registry the pipeline actually draws from.
    /// It is seeded with `breakers` (as `nil`-credential keys), so the built-in path is
    /// byte-identical, and vends a fresh, isolated breaker the first time a user's BYOK
    /// credential is used — so a 401 from one key can't trip another key's (or the
    /// built-in) breaker.
    public let breakerRegistry: ProviderBreakerRegistry

    public init(
        resultCache: ProviderResultCache,
        breakers: [MetadataSource: ProviderCircuitBreaker],
        breakerPolicy: ProviderCircuitBreaker.Policy = ProviderCircuitBreaker.Policy()
    ) {
        self.resultCache = resultCache
        self.breakers = breakers
        var seed: [ProviderBreakerKey: ProviderCircuitBreaker] = [:]
        for (source, breaker) in breakers {
            seed[ProviderBreakerKey(source: source)] = breaker
        }
        self.breakerRegistry = ProviderBreakerRegistry(
            seed: seed,
            makeBreaker: { ProviderCircuitBreaker(policy: breakerPolicy) }
        )
    }

    /// The default production runtime: a fresh shared result cache and one breaker
    /// per source in the default provider set (see ``ProductionMetadataProviders``).
    public static func makeDefault(
        breakerPolicy: ProviderCircuitBreaker.Policy = ProviderCircuitBreaker.Policy(),
        resultCache: ProviderResultCache = ProviderResultCache()
    ) -> MetadataProviderRuntime {
        var breakers: [MetadataSource: ProviderCircuitBreaker] = [:]
        for source in ProductionMetadataProviders.defaultSources {
            breakers[source] = ProviderCircuitBreaker(policy: breakerPolicy)
        }
        return MetadataProviderRuntime(
            resultCache: resultCache,
            breakers: breakers,
            breakerPolicy: breakerPolicy
        )
    }

    /// A point-in-time projection of every known breaker's state, in the module-neutral
    /// diagnostics shape. Ordered by ``ProductionMetadataProviders/defaultSources`` so
    /// the UI list is stable; sources without a breaker are omitted.
    ///
    /// When `tmdbCredentialID` is supplied (a user's BYOK key is active), the TMDb row
    /// reflects **that credential's** breaker — the one the pipeline actually serves
    /// from — so a tripped user key shows up in diagnostics instead of the healthy,
    /// unused built-in breaker. It falls back to the built-in breaker when the active
    /// credential has no breaker yet (nothing has used it).
    public func breakerStates(
        tmdbCredentialID: String? = nil
    ) async -> [MetadataEnrichmentDiagnosticsSnapshot.ProviderBreakerState] {
        var states: [MetadataEnrichmentDiagnosticsSnapshot.ProviderBreakerState] = []
        for source in ProductionMetadataProviders.defaultSources {
            let breaker: ProviderCircuitBreaker?
            if source == .tmdb, let credentialID = tmdbCredentialID {
                breaker = breakerRegistry.existingBreaker(
                    for: ProviderBreakerKey(source: .tmdb, credentialID: credentialID)
                ) ?? breakers[source]
            } else {
                breaker = breakers[source]
            }
            guard let breaker else { continue }
            let state = await breaker.trippedState
            states.append(
                MetadataEnrichmentDiagnosticsSnapshot.ProviderBreakerState(
                    source: source,
                    isTripped: state.isTripped,
                    trippedReason: state.reason.map(Self.describe)
                )
            )
        }
        return states
    }

    /// Current live entry count of the shared result cache.
    public func resultCacheEntryCount() async -> Int {
        await resultCache.count
    }

    /// Clears all shared state for a specific BYOK `credentialID` — its cached results
    /// (and bad-key negatives) plus its circuit-breaker trip. `AppShell` calls this
    /// when a user replaces or removes their TMDB key, so the old credential can never
    /// resurface and re-adding the same key refills immediately instead of waiting out
    /// the negative TTL / auth cooldown.
    public func invalidateCredential(_ credentialID: String) async {
        await resultCache.invalidate(credential: credentialID)
        await breakerRegistry.resetBreakers(credentialID: credentialID)
    }

    private static func describe(_ kind: ProviderFailureKind) -> String {
        switch kind {
        case .transient: return "unavailable"
        case .unauthorized: return "unauthorized"
        case .rateLimited: return "rate limited"
        }
    }
}
