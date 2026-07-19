import Foundation

/// A point-in-time picture of the metadata enrichment subsystem, aggregated for the
/// Settings "Diagnostics" section.
///
/// **This snapshot is deliberately point-in-time and cross-actor, not
/// transactional.** Its parts are gathered from several independent actors (the two
/// caches, the per-provider circuit breakers, the share catalog store, the work
/// scheduler) with no global lock, so two fields can reflect instants a few
/// milliseconds apart. `capturedAt` records when aggregation started; a reader
/// should treat the whole value as "roughly now" and re-capture to refresh rather
/// than expecting the fields to be mutually consistent to the instant.
///
/// The value type lives in `CoreModels` (a leaf) so both the `AppShell` aggregator
/// that fills it from the live actors and the `FeatureSettings` UI that renders it
/// share one definition without a layering violation.
public struct MetadataEnrichmentDiagnosticsSnapshot: Sendable, Equatable {
    /// When aggregation began. The fields below may each be a few ms newer.
    public var capturedAt: Date

    /// Per-source count of persisted provenance rows in the local share catalog
    /// (`metadata_values`), keyed by `MetadataSource`. Empty when no share catalog
    /// exists yet or the on-demand count hasn't been requested.
    public var metadataCountPerSource: [MetadataSource: Int]

    /// Current size, in bytes, of the derived-artwork cache
    /// (`CoreUI.LocalArtworkDerivedCache`). `nil` when unavailable on this platform.
    public var artworkCacheBytes: Int?

    /// Current size, in bytes, of the resolved-URL metadata cache
    /// (`MetadataKit.MetadataDiskCache`).
    public var metadataCacheBytes: Int?

    /// Live entry count of the in-memory provider result cache
    /// (`MetadataKit.ProviderResultCache`).
    public var resultCacheEntryCount: Int?

    /// Per-provider circuit-breaker state, one entry per source that has a breaker.
    public var providerBreakers: [ProviderBreakerState]

    /// Background scan / enrichment work status (queued backlogs, queued items, and
    /// which account, if any, is currently running).
    public var work: WorkStatus

    public init(
        capturedAt: Date = Date(),
        metadataCountPerSource: [MetadataSource: Int] = [:],
        artworkCacheBytes: Int? = nil,
        metadataCacheBytes: Int? = nil,
        resultCacheEntryCount: Int? = nil,
        providerBreakers: [ProviderBreakerState] = [],
        work: WorkStatus = WorkStatus()
    ) {
        self.capturedAt = capturedAt
        self.metadataCountPerSource = metadataCountPerSource
        self.artworkCacheBytes = artworkCacheBytes
        self.metadataCacheBytes = metadataCacheBytes
        self.resultCacheEntryCount = resultCacheEntryCount
        self.providerBreakers = providerBreakers
        self.work = work
    }

    /// One provider's circuit-breaker state, in a UI-friendly, module-neutral form
    /// (the real breaker actor lives in `MetadataKit`; this is its projection).
    public struct ProviderBreakerState: Sendable, Equatable, Identifiable {
        public var source: MetadataSource
        /// Whether the breaker is currently open (the source is being skipped).
        public var isTripped: Bool
        /// A short, human-readable reason when tripped (e.g. "rate limited",
        /// "unauthorized", "unavailable"); `nil` when closed/healthy.
        public var trippedReason: String?

        public var id: String { source.rawValue }

        public init(source: MetadataSource, isTripped: Bool, trippedReason: String? = nil) {
            self.source = source
            self.isTripped = isTripped
            self.trippedReason = trippedReason
        }
    }

    /// Background metadata work status, mirroring the scheduler's own snapshot.
    public struct WorkStatus: Sendable, Equatable {
        /// Number of shares with queued backlog work.
        public var queuedBacklogs: Int
        /// Number of queued urgent (opened-item) work units.
        public var queuedItems: Int
        /// Whether an account is actively running a slice/item right now.
        public var isRunning: Bool

        public init(queuedBacklogs: Int = 0, queuedItems: Int = 0, isRunning: Bool = false) {
            self.queuedBacklogs = queuedBacklogs
            self.queuedItems = queuedItems
            self.isRunning = isRunning
        }
    }
}
