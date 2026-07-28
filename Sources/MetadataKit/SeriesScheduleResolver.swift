import Foundation
import CoreModels

/// Resolves and caches a series' next-airing-episode schedule.
///
/// Cache-first by design: ``cachedRecord(for:)`` never touches the network, so Home
/// can render "Airing Soon" from whatever the passive worker has already filled. The
/// network-touching ``refresh(_:tier:)`` runs the same ``MetadataEnrichmentPipeline``
/// as every other enrichment — inheriting its configured provider ordering, id
/// threading (exact-id lookups, never a title search per render), and circuit
/// breakers — requesting *only* ``MetadataField/nextAiringEpisode`` so no other work
/// is triggered. It persists exactly one ``SeriesScheduleRecord`` per series and
/// honors the schedule TTL policy, so a fresh record is never re-fetched.
public actor SeriesScheduleResolver {
    /// The app-wide resolver, self-configuring from the bundle exactly like
    /// ``ArtworkRouter/shared`` — so a view can read a cached schedule without any
    /// app wiring, and a refresh reuses the same provider set as every other
    /// enrichment.
    public static let shared = SeriesScheduleResolver(
        pipeline: ProductionMetadataProviders.makePipeline()
    )

    private let pipeline: MetadataEnrichmentPipeline
    private let store: SeriesScheduleStore
    private let now: @Sendable () -> Date

    public init(
        pipeline: MetadataEnrichmentPipeline,
        store: SeriesScheduleStore = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.pipeline = pipeline
        self.store = store
        self.now = now
    }

    /// The cached record for a series query, or `nil` — **zero network**.
    public func cachedRecord(for query: MetadataQuery) async -> SeriesScheduleRecord? {
        await store.record(for: query.enrichmentCacheKey)
    }

    /// The cached record for a raw series key, or `nil` — **zero network**.
    public func cachedRecord(forSeriesKey key: String) async -> SeriesScheduleRecord? {
        await store.record(for: key)
    }

    /// Ensures a fresh schedule record for `query`, resolving from providers only when
    /// no fresh record exists (or `force` is set). Returns the current record either
    /// way. Safe to call on every open of a series (foreground fast-track) — a fresh
    /// record short-circuits with no network.
    @discardableResult
    public func refresh(
        _ query: MetadataQuery,
        tier: MetadataWorkTier,
        seriesEnded: Bool = false,
        force: Bool = false
    ) async -> SeriesScheduleRecord {
        let key = query.enrichmentCacheKey
        if !force, let existing = await store.record(for: key), !existing.isRefreshDue(now: now()) {
            return existing
        }

        let enrichment = await pipeline.enrich(query, requesting: [.nextAiringEpisode], tier: tier)
        let refreshedAt = now()
        let upcoming = enrichment.upcomingEpisode
        let due = SeriesScheduleTTLPolicy.refreshDue(
            upcomingEpisode: upcoming,
            seriesEnded: seriesEnded,
            refreshedAt: refreshedAt
        )
        let record = SeriesScheduleRecord(
            seriesKey: key,
            upcomingEpisode: upcoming,
            upcomingEpisodes: enrichment.upcomingEpisodes,
            cadence: enrichment.cadence,
            seriesEnded: seriesEnded,
            refreshedAt: refreshedAt,
            refreshDueAt: due
        )
        await store.store(record)
        return record
    }
}
