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

    /// The namespaced key: `source#version|requestKey`, or, when a `credential` is
    /// supplied, `source#version@credential|requestKey`.
    ///
    /// - Step 9 (per-user BYOK): `credential` is a short **opaque** identity for the
    ///   active credential (e.g. a hash of a user's TMDB key — never the raw key), or
    ///   `nil` for the built-in/app-global path. A `nil` credential reproduces the
    ///   pre-Step-9 key byte-for-byte, so every built-in provider's entries are
    ///   unchanged; a non-`nil` credential gives that key its own disjoint namespace,
    ///   so a private result resolved with one key is never served to another, and a
    ///   bad key's negative can't mask a good key's data.
    static func key(source: MetadataSource, version: Int, requestKey: String, credential: String? = nil) -> String {
        "\(namespacePrefix(source: source, version: version, credential: credential))\(requestKey)"
    }

    static func namespacePrefix(source: MetadataSource, version: Int, credential: String? = nil) -> String {
        if let credential {
            return "\(source.rawValue)#\(version)@\(credential)|"
        }
        return "\(source.rawValue)#\(version)|"
    }

    /// Looks up a cached result. Returns `nil` for a miss/expired entry, `.some(nil)`
    /// for a fresh remembered negative, and `.some(enrichment)` for a positive hit.
    public func cached(source: MetadataSource, version: Int, requestKey: String, credential: String? = nil) -> MetadataEnrichment?? {
        let key = Self.key(source: source, version: version, requestKey: requestKey, credential: credential)
        guard let entry = entries[key], entry.expires > now() else { return nil }
        return .some(entry.enrichment)
    }

    /// Stores a positive (`enrichment`) or negative (`nil`) result under the provider's
    /// (and, for a BYOK credential, that credential's) namespace, then enforces the
    /// entry budget.
    public func store(
        _ enrichment: MetadataEnrichment?,
        source: MetadataSource,
        version: Int,
        requestKey: String,
        credential: String? = nil
    ) {
        let key = Self.key(source: source, version: version, requestKey: requestKey, credential: credential)
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
    /// used when its credentials change so nothing stale can be served. Scoped to the
    /// given `credential` namespace when supplied (so replacing/removing a BYOK key
    /// clears only that key's entries, never the built-in path's or another key's).
    public func invalidate(source: MetadataSource, version: Int, credential: String? = nil) {
        let prefix = Self.namespacePrefix(source: source, version: version, credential: credential)
        entries = entries.filter { !$0.key.hasPrefix(prefix) }
    }

    /// Drops only the **negative** entries for a provider version, so a recovered
    /// source refills the gaps it previously couldn't fill without waiting the normal
    /// negative TTL. Scoped to `credential` when supplied.
    public func invalidateNegatives(source: MetadataSource, version: Int, credential: String? = nil) {
        let prefix = Self.namespacePrefix(source: source, version: version, credential: credential)
        entries = entries.filter { !($0.key.hasPrefix(prefix) && $0.value.isNegative) }
    }

    /// Drops **every** entry (any source, any version) belonging to a specific BYOK
    /// `credential` — used when a user replaces or removes their key so its results and
    /// bad-key negatives can never resurface (Step 9 credential-change invalidation).
    ///
    /// A key is `source#version[@credential]|requestKey`; the credential, when present,
    /// is the suffix of the namespace segment before the first `|`, so this matches it
    /// unambiguously (a `requestKey` after the `|` can never be mistaken for it) and
    /// version-agnostically.
    public func invalidate(credential: String) {
        let marker = "@\(credential)"
        entries = entries.filter { key, _ in
            guard let bar = key.firstIndex(of: "|") else { return true }
            return !key[key.startIndex..<bar].hasSuffix(marker)
        }
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
    private let credentialID: String?

    public init(base: any MetadataEnrichmentProvider, cache: ProviderResultCache, credentialID: String? = nil) {
        self.base = base
        self.cache = cache
        self.credentialID = credentialID
    }

    public var id: MetadataSource { base.id }
    public var capabilities: Set<MetadataCapability> { base.capabilities }
    public var policy: ProviderPolicy { base.policy }

    public func enrich(_ query: MetadataQuery, missing: Set<MetadataField>) async -> MetadataEnrichment {
        let requestKey = Self.requestKey(query: query, missing: missing)
        if let hit = await cache.cached(source: base.id, version: base.policy.version, requestKey: requestKey, credential: credentialID) {
            return hit ?? MetadataEnrichment()
        }
        let result = await base.enrich(query, missing: missing)
        await cache.store(
            result.isEmpty ? nil : result,
            source: base.id,
            version: base.policy.version,
            requestKey: requestKey,
            credential: credentialID
        )
        return result
    }

    static func requestKey(query: MetadataQuery, missing: Set<MetadataField>) -> String {
        let fields = missing.map(\.rawValue).sorted().joined(separator: ",")
        return "\(query.enrichmentCacheKey)#\(fields)"
    }
}
