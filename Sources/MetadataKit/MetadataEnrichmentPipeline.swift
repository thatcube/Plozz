import Foundation
import CoreModels

public extension MetadataQuery {
    /// A stable, whole-item cache identity for pipeline/provider result caching:
    /// prefers a concrete external id (so every episode of a show shares one lookup)
    /// and otherwise a normalized title+year, with SxE appended for a specific
    /// episode. Distinct from ``cacheKey(for:)`` which is per-``ArtworkKind``.
    var enrichmentCacheKey: String {
        var parts: [String] = [contentType.rawValue]
        if let anilist = animeIDs.anilist { parts.append("anilist:\(anilist)") }
        else if let mal = animeIDs.mal { parts.append("mal:\(mal)") }
        else if let tmdb = providerIDs.providerID(.tmdb) ?? providerIDs.providerID(.seriesTmdb) { parts.append("tmdb:\(tmdb)") }
        else if let tvdb = providerIDs.providerID(.tvdb) { parts.append("tvdb:\(tvdb)") }
        else if let imdb = providerIDs.providerID(.imdb) { parts.append("imdb:\(imdb)") }
        else { parts.append("t:\(title.lowercased())|y:\(year.map(String.init) ?? "")") }
        if let s = seasonNumber, let e = episodeNumber { parts.append("s\(s)e\(e)") }
        return parts.joined(separator: "|")
    }

    /// A copy with `additionalIDs` merged into ``providerIDs``, **without overwriting
    /// ids the query already carries** (a local/NFO/server id is authoritative and
    /// keeps priority). Used by the pipeline to thread ids a provider just resolved
    /// down to later providers, so an exact-id lookup can replace a fuzzy title
    /// search.
    func mergingProviderIDs(_ additionalIDs: [String: String]) -> MetadataQuery {
        guard !additionalIDs.isEmpty else { return self }
        var merged = providerIDs
        for (key, value) in additionalIDs where merged[key] == nil {
            merged[key] = value
        }
        guard merged.count != providerIDs.count else { return self }
        return MetadataQuery(
            contentType: contentType,
            kind: kind,
            title: title,
            alternateTitle: alternateTitle,
            year: year,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber,
            animeIDs: animeIDs,
            providerIDs: merged
        )
    }
}

/// The single front door for resolving external metadata (ids, canonical text,
/// artwork, ratings) for one item.
///
/// The pipeline is **capability- and gap-driven**: given the fields an item still
/// needs (`requesting`) and the fields a higher-priority local/server source already
/// supplied (`present`), it visits the configured providers in priority order, asks
/// each to fill **only** the fields it can that are still missing, threads any ids a
/// provider resolves down to the next, and **stops the moment every requested field
/// is filled**. Winners are merged with their provenance intact (Step 2/3), and wide
/// backdrops are kept as an ordered candidate set so one response serves both the
/// home hero and the detail backdrop.
///
/// It performs no network work of its own and never throws — each provider is
/// best-effort. Provider outage handling (circuit breakers, cache) layers in later
/// phases *inside* the providers and the shared cache, leaving this driver stable.
public actor MetadataEnrichmentPipeline {
    private let providers: [MetadataSource: any MetadataEnrichmentProvider]
    private let config: MetadataEnrichmentConfig

    public init(
        providers: [any MetadataEnrichmentProvider],
        config: MetadataEnrichmentConfig = MetadataEnrichmentConfig()
    ) {
        self.providers = Dictionary(
            providers.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        self.config = config
    }

    /// The provider ids registered with this pipeline, for diagnostics/tests.
    public var registeredSources: Set<MetadataSource> { Set(providers.keys) }

    /// Resolve `requesting` for `query`, skipping fields already in `present`.
    ///
    /// - Parameters:
    ///   - query: The normalized item to enrich.
    ///   - present: Fields a higher-priority source already filled; never requested
    ///     and never overwritten.
    ///   - requesting: The fields the caller wants filled.
    ///   - tier: The work tier; a provider is skipped when it is not eligible for it.
    /// - Returns: An enrichment containing whatever of `requesting` could be resolved.
    public func enrich(
        _ query: MetadataQuery,
        present: Set<MetadataField> = [],
        requesting requested: Set<MetadataField>,
        tier: MetadataWorkTier
    ) async -> MetadataEnrichment {
        var result = MetadataEnrichment()
        var remaining = requested.subtracting(present)
        guard !remaining.isEmpty else { return result }

        for source in orderedSourceSweep(for: remaining, query: query) {
            if remaining.isEmpty { break }
            guard let provider = providers[source],
                  provider.policy.eligibleTiers.contains(tier)
            else { continue }
            let want = provider.serviceableFields(from: remaining)
            guard !want.isEmpty else { continue }

            let threaded = query.mergingProviderIDs(result.externalIDs.mapValues(\.value))
            let enrichment = await provider.enrich(threaded, missing: want)
            result.fillMissing(from: enrichment, skipping: present)
            remaining = requested.subtracting(present).subtracting(result.filledFields)
        }
        return result
    }

    /// A de-duplicated, priority-ordered sweep of every source relevant to any of the
    /// still-missing `fields`. Each field contributes its own configured chain; the
    /// chains are interleaved by rank (all top choices first, then all seconds, …) so
    /// a source that is the best choice for one field is visited before another
    /// field's fallbacks, and each source is visited at most once.
    private func orderedSourceSweep(
        for fields: Set<MetadataField>,
        query: MetadataQuery
    ) -> [MetadataSource] {
        let sortedFields = fields.sorted { $0.rawValue < $1.rawValue }
        let chains = sortedFields.map { config.orderedSources(for: $0, query: query) }
        var order: [MetadataSource] = []
        var seen: Set<MetadataSource> = []
        var rank = 0
        var addedAny = true
        while addedAny {
            addedAny = false
            for chain in chains where rank < chain.count {
                addedAny = true
                let source = chain[rank]
                if seen.insert(source).inserted { order.append(source) }
            }
            rank += 1
        }
        return order
    }
}
