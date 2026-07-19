import Foundation
import CoreModels

/// A provider- and version-namespaced cache of ``MetadataEnrichment`` results, with
/// positive **and** negative entries.
///
/// Every entry's key is prefixed with `source#version`, so:
///   * bumping one provider's ``ProviderPolicy/version`` (a policy change) invalidates
///     only that provider's entries — a poster policy tweak never flushes another
///     source's art, unlike the old global cache-file version bump; and
///   * a recovered/credential-changed provider can drop just its own **negative**
///     entries (``invalidateNegatives(source:)``) so gaps refill immediately without
///     waiting the normal negative TTL (the Phase 4 circuit-breaker tie-in).
///
/// In-memory and bounded (oldest-expiring evicted first, mirroring the disk cache's
/// budget policy). Kept deliberately independent of ``MetadataDiskCache`` so this
/// change touches none of that actor's shared file/IO code.
public actor ProviderResultCache {
    struct Entry: Sendable {
        /// `nil` is a remembered negative result.
        let enrichment: MetadataEnrichment?
        let expires: Date
        let isNegative: Bool
    }

    private var entries: [String: Entry] = [:]
    private let positiveTTL: TimeInterval
    private let negativeTTL: TimeInterval
    private let maxEntries: Int
    private let now: @Sendable () -> Date

    public init(
        positiveTTL: TimeInterval = 60 * 60 * 24 * 30,
        negativeTTL: TimeInterval = 60 * 60 * 24 * 3,
        maxEntries: Int = 4096,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.positiveTTL = positiveTTL
        self.negativeTTL = negativeTTL
        self.maxEntries = max(1, maxEntries)
        self.now = now
    }

    /// The namespaced key: `source#version|requestKey`.
    ///
    /// - TODO(Step 9, per-profile BYOK): this key is keyed on `source` alone. Once
    ///   per-profile credentials/API keys land (e.g. a user's own TMDB key), the key
    ///   MUST gain a credential/profile dimension — otherwise a private result
    ///   resolved with one profile's key could be served to another profile, and a
    ///   bad key's negative could mask a good key. App-global credentials today make
    ///   this safe; do not let Step 9 forget to extend the key.
    static func key(source: MetadataSource, version: Int, requestKey: String) -> String {
        "\(source.rawValue)#\(version)|\(requestKey)"
    }

    static func namespacePrefix(source: MetadataSource, version: Int) -> String {
        "\(source.rawValue)#\(version)|"
    }

    /// Looks up a cached result. Returns `nil` for a miss/expired entry, `.some(nil)`
    /// for a fresh remembered negative, and `.some(enrichment)` for a positive hit.
    public func cached(source: MetadataSource, version: Int, requestKey: String) -> MetadataEnrichment?? {
        let key = Self.key(source: source, version: version, requestKey: requestKey)
        guard let entry = entries[key], entry.expires > now() else { return nil }
        return .some(entry.enrichment)
    }

    /// Stores a positive (`enrichment`) or negative (`nil`) result under the provider's
    /// namespace, then enforces the entry budget.
    public func store(
        _ enrichment: MetadataEnrichment?,
        source: MetadataSource,
        version: Int,
        requestKey: String
    ) {
        let key = Self.key(source: source, version: version, requestKey: requestKey)
        let isNegative = enrichment == nil
        let ttl = isNegative ? negativeTTL : positiveTTL
        entries[key] = Entry(
            enrichment: enrichment,
            expires: now().addingTimeInterval(ttl),
            isNegative: isNegative
        )
        evictIfNeeded()
    }

    /// Drops **all** cached entries (positive and negative) for a provider version —
    /// used when its credentials change so nothing stale can be served.
    public func invalidate(source: MetadataSource, version: Int) {
        let prefix = Self.namespacePrefix(source: source, version: version)
        entries = entries.filter { !$0.key.hasPrefix(prefix) }
    }

    /// Drops only the **negative** entries for a provider version, so a recovered
    /// source refills the gaps it previously couldn't fill without waiting the normal
    /// negative TTL.
    public func invalidateNegatives(source: MetadataSource, version: Int) {
        let prefix = Self.namespacePrefix(source: source, version: version)
        entries = entries.filter { !($0.key.hasPrefix(prefix) && $0.value.isNegative) }
    }

    /// Test/diagnostic: current live entry count.
    public var count: Int { entries.count }

    private func evictIfNeeded() {
        guard entries.count > maxEntries else { return }
        let overflow = entries.count - maxEntries
        let oldest = entries.sorted {
            $0.value.expires != $1.value.expires
                ? $0.value.expires < $1.value.expires
                : $0.key < $1.key
        }.prefix(overflow).map(\.key)
        for key in oldest { entries[key] = nil }
    }
}

/// Decorates any ``MetadataEnrichmentProvider`` with the namespaced
/// ``ProviderResultCache``: a cache hit (positive or negative) short-circuits the
/// wrapped provider entirely, so a resolved item costs no network on re-enrichment.
///
/// The cache key folds in the requested `missing` set, so a later request for
/// additional fields is not served a stale, narrower result. A recovered provider's
/// negatives are cleared via ``ProviderResultCache/invalidateNegatives(source:version:)``.
public struct CachedEnrichmentProvider: MetadataEnrichmentProvider {
    private let base: any MetadataEnrichmentProvider
    private let cache: ProviderResultCache

    public init(base: any MetadataEnrichmentProvider, cache: ProviderResultCache) {
        self.base = base
        self.cache = cache
    }

    public var id: MetadataSource { base.id }
    public var capabilities: Set<MetadataCapability> { base.capabilities }
    public var policy: ProviderPolicy { base.policy }

    public func enrich(_ query: MetadataQuery, missing: Set<MetadataField>) async -> MetadataEnrichment {
        let requestKey = Self.requestKey(query: query, missing: missing)
        if let hit = await cache.cached(source: base.id, version: base.policy.version, requestKey: requestKey) {
            return hit ?? MetadataEnrichment()
        }
        let result = await base.enrich(query, missing: missing)
        await cache.store(
            result.isEmpty ? nil : result,
            source: base.id,
            version: base.policy.version,
            requestKey: requestKey
        )
        return result
    }

    static func requestKey(query: MetadataQuery, missing: Set<MetadataField>) -> String {
        let fields = missing.map(\.rawValue).sorted().joined(separator: ",")
        return "\(query.enrichmentCacheKey)#\(fields)"
    }
}
