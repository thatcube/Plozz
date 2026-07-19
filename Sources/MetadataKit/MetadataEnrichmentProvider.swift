import Foundation
import CoreModels

/// When a piece of enrichment work runs, from most to least time-sensitive. A
/// provider declares which tiers it is eligible for in its ``ProviderPolicy`` so the
/// pipeline can, for example, keep an expensive or rate-limited fallback source
/// (Wikidata / Wikipedia) off the foreground path and confine it to idle backlog.
public enum MetadataWorkTier: String, Sendable, Codable, CaseIterable {
    /// The user just opened this item; fill it now, ahead of the backlog.
    case foregroundFill
    /// The item is about to be on screen; prefetch its art.
    case visiblePrefetch
    /// Passive background drain under the Step 1 scheduler's spare capacity.
    case idleBacklog
}

/// How prominently a source participates, independent of code. `disabled` removes it
/// from the running set entirely; `primary` sources are consulted ahead of
/// `secondary` ones for the same field. Persisted as data so a source can be
/// promoted, demoted, or switched off from configuration with no code change.
public enum ProviderRole: String, Sendable, Codable, CaseIterable {
    case primary
    case secondary
    case disabled
}

/// The operational envelope a provider runs under: how long to wait, how fast it may
/// be called, how long its results (positive *and* negative) stay cached, which work
/// tiers it serves, and a cache-namespacing `version`.
///
/// Bumping `version` invalidates only *this* provider's cached entries (Phase 3), so
/// a policy change for one source never flushes another source's art.
public struct ProviderPolicy: Sendable, Equatable {
    /// Per-request timeout. A provider that exceeds it is treated as a transient
    /// failure (never cached as a hard negative).
    public var timeout: Duration
    /// Sustained request ceiling (token-bucket refill rate).
    public var requestsPerSecond: Double
    /// How many requests may fire back-to-back after an idle period.
    public var burst: Int
    /// TTL for a positive (resolved) cache entry.
    public var positiveTTL: TimeInterval
    /// TTL for a remembered negative ("looked, found nothing") cache entry.
    public var negativeTTL: TimeInterval
    /// The work tiers this provider is eligible to run in.
    public var eligibleTiers: Set<MetadataWorkTier>
    /// Cache-namespacing version. Bump to invalidate just this provider's entries.
    public var version: Int

    public init(
        timeout: Duration = .seconds(12),
        requestsPerSecond: Double = 5,
        burst: Int = 5,
        positiveTTL: TimeInterval = 60 * 60 * 24 * 30,
        negativeTTL: TimeInterval = 60 * 60 * 24 * 3,
        eligibleTiers: Set<MetadataWorkTier> = Set(MetadataWorkTier.allCases),
        version: Int = 1
    ) {
        self.timeout = timeout
        self.requestsPerSecond = requestsPerSecond
        self.burst = burst
        self.positiveTTL = positiveTTL
        self.negativeTTL = negativeTTL
        self.eligibleTiers = eligibleTiers
        self.version = version
    }

    /// A conservative default for a fallback source confined to idle backlog only
    /// (e.g. Wikidata / Wikipedia): slower rate, backlog-only eligibility.
    public static let idleBacklogFallback = ProviderPolicy(
        requestsPerSecond: 1,
        burst: 2,
        eligibleTiers: [.idleBacklog]
    )
}

/// The single seam every external metadata source conforms to.
///
/// The pipeline asks a provider to fill **only the fields still missing** for an
/// item (`missing`), and the provider returns whatever of those it can as a
/// ``MetadataEnrichment`` carrying provenance. Implementations must be best-effort
/// and **never throw** — enrichment is always optional. A provider should also honor
/// any ids already present on the `query` (they are threaded in by the pipeline) so
/// an exact-id lookup replaces a fuzzy title search.
public protocol MetadataEnrichmentProvider: Sendable {
    /// The provenance source this provider stamps onto every value it supplies.
    var id: MetadataSource { get }
    /// The capability classes this provider can serve.
    var capabilities: Set<MetadataCapability> { get }
    /// The provider's operational envelope.
    var policy: ProviderPolicy { get }
    /// Resolve as many of `missing` as possible for `query`. Never throws; returns an
    /// empty enrichment when nothing could be resolved.
    func enrich(_ query: MetadataQuery, missing: Set<MetadataField>) async -> MetadataEnrichment
}

public extension MetadataEnrichmentProvider {
    /// The subset of `missing` this provider could conceivably fill (its capabilities
    /// intersect the capability covering each field). The pipeline uses this to skip
    /// a provider with nothing to offer for the remaining fields.
    func serviceableFields(from missing: Set<MetadataField>) -> Set<MetadataField> {
        missing.filter { field in
            guard let capability = MetadataCapability.covering(field) else { return false }
            return capabilities.contains(capability)
        }
    }
}
