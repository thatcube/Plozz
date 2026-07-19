import Foundation
import CoreModels

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
    /// One breaker per source. A source absent here is given a fresh breaker at
    /// wrap time (so an incomplete map still works, just without diagnostics for it).
    public let breakers: [MetadataSource: ProviderCircuitBreaker]

    public init(
        resultCache: ProviderResultCache,
        breakers: [MetadataSource: ProviderCircuitBreaker]
    ) {
        self.resultCache = resultCache
        self.breakers = breakers
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
        return MetadataProviderRuntime(resultCache: resultCache, breakers: breakers)
    }

    /// A point-in-time projection of every known breaker's state, in the module-neutral
    /// diagnostics shape. Ordered by ``ProductionMetadataProviders/defaultSources`` so
    /// the UI list is stable; sources without a breaker are omitted.
    public func breakerStates() async -> [MetadataEnrichmentDiagnosticsSnapshot.ProviderBreakerState] {
        var states: [MetadataEnrichmentDiagnosticsSnapshot.ProviderBreakerState] = []
        for source in ProductionMetadataProviders.defaultSources {
            guard let breaker = breakers[source] else { continue }
            let tripped = await breaker.isTripped
            let reason = await breaker.trippedReason
            states.append(
                MetadataEnrichmentDiagnosticsSnapshot.ProviderBreakerState(
                    source: source,
                    isTripped: tripped,
                    trippedReason: reason.map(Self.describe)
                )
            )
        }
        return states
    }

    /// Current live entry count of the shared result cache.
    public func resultCacheEntryCount() async -> Int {
        await resultCache.count
    }

    private static func describe(_ kind: ProviderFailureKind) -> String {
        switch kind {
        case .transient: return "unavailable"
        case .unauthorized: return "unauthorized"
        case .rateLimited: return "rate limited"
        }
    }
}
