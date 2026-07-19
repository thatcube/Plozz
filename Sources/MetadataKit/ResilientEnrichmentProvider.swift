import Foundation
import CoreModels

/// Wraps a provider with its own ``ProviderCircuitBreaker`` and the shared
/// ``ProviderResultCache`` to give real outage resilience:
///
///   1. **Warm cache wins, even during an outage.** A cached result (positive or
///      authoritative negative) is served without consulting the breaker or the
///      provider — so when a source is down, callers still get its last-known data.
///   2. **Cold + tripped ⇒ graceful skip.** On a cache miss with the breaker open,
///      it returns empty *without* caching, so nothing stale is persisted and the
///      source is retried once its cooldown elapses.
///   3. **Only authoritative outcomes are cached.** A success or a real "nothing
///      found" is cached; a transient / auth / rate failure is never cached as a
///      negative (it would otherwise mask recovery).
///   4. **Recovery refills gaps.** When a probe closes the breaker, that provider's
///      cached negatives are dropped immediately, so previously-missing fields
///      resolve on the next pass without waiting the negative TTL.
///
/// Each provider gets an independent breaker, so outages are isolated per source.
public struct ResilientEnrichmentProvider: MetadataEnrichmentProvider {
    private let base: any MetadataEnrichmentProvider
    private let breaker: ProviderCircuitBreaker
    private let cache: ProviderResultCache?

    public init(
        base: any MetadataEnrichmentProvider,
        breaker: ProviderCircuitBreaker,
        cache: ProviderResultCache? = nil
    ) {
        self.base = base
        self.breaker = breaker
        self.cache = cache
    }

    public var id: MetadataSource { base.id }
    public var capabilities: Set<MetadataCapability> { base.capabilities }
    public var policy: ProviderPolicy { base.policy }

    public func enrich(_ query: MetadataQuery, missing: Set<MetadataField>) async -> MetadataEnrichment {
        await enrichReporting(query, missing: missing).enrichment
    }

    public func enrichReporting(
        _ query: MetadataQuery,
        missing: Set<MetadataField>
    ) async -> ProviderResponse {
        let version = base.policy.version
        let requestKey = CachedEnrichmentProvider.requestKey(query: query, missing: missing)

        // 1. Warm cache short-circuits everything (served even mid-outage).
        if let cache, let hit = await cache.cached(source: base.id, version: version, requestKey: requestKey) {
            let enrichment = hit ?? MetadataEnrichment()
            return ProviderResponse(enrichment: enrichment, health: enrichment.isEmpty ? .empty : .ok)
        }

        // 2. Cold + tripped ⇒ degrade without caching.
        guard await breaker.allow() else {
            return ProviderResponse(enrichment: MetadataEnrichment(), health: .failure(.transient))
        }

        let response = await base.enrichReporting(query, missing: missing)
        let recovered = await breaker.record(response.health)
        if recovered, let cache {
            await cache.invalidateNegatives(source: base.id, version: version)
        }

        // 3. Cache only authoritative outcomes.
        if let cache {
            switch response.health {
            case .ok:
                await cache.store(response.enrichment, source: base.id, version: version, requestKey: requestKey)
            case .empty:
                await cache.store(nil, source: base.id, version: version, requestKey: requestKey)
            case .failure:
                break
            }
        }
        return response
    }
}
