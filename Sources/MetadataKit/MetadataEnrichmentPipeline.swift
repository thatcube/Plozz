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
    /// The pipeline honors each field's configured priority chain independently: a
    /// field is only ever offered to the **highest-priority source that has not yet
    /// been tried for it**. A provider is asked (in one call) for exactly the batch of
    /// still-missing fields for which it is currently that frontmost source — never for
    /// a field a higher-priority source should own — so a multi-capability source
    /// (e.g. TheTVDB) can't grab a field (e.g. TV `overview`) that the policy assigns
    /// to another source (TVmaze). If a source fails to fill a field it was asked for,
    /// that field falls through to the next source in its chain on a later round.
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

        // Per-field record of which sources have already had their chance at it, so a
        // field falls through its chain on successive rounds and no source is asked
        // twice for the same field.
        var triedForField: [MetadataField: Set<MetadataSource>] = [:]

        while !remaining.isEmpty {
            guard let round = nextRound(remaining: remaining, query: query, tier: tier, tried: triedForField) else {
                break
            }
            for field in round.fields { triedForField[field, default: []].insert(round.source) }
            guard let provider = providers[round.source] else { break }

            // Thread already-resolved ids downstream so an exact-id lookup replaces a
            // fuzzy title search (no duplicate work).
            let threaded = query.mergingProviderIDs(result.externalIDs.mapValues(\.value))
            let enrichment = await provider.enrich(threaded, missing: round.fields)
            result.fillMissing(from: enrichment, skipping: present)
            remaining = requested.subtracting(present).subtracting(result.filledFields)
        }
        return result
    }

    /// The next provider to call and the batch of fields it currently owns.
    ///
    /// For each still-missing field it finds the frontmost source that is registered,
    /// eligible for `tier`, and not yet tried for that field, tagged with the field's
    /// rank (position in its priority chain). It then picks the source owning the
    /// globally-lowest-rank field (ties broken deterministically) and batches every
    /// remaining field for which that same source is currently frontmost — so a source
    /// that is the top choice for several fields is asked for all of them at once.
    private func nextRound(
        remaining: Set<MetadataField>,
        query: MetadataQuery,
        tier: MetadataWorkTier,
        tried: [MetadataField: Set<MetadataSource>]
    ) -> (source: MetadataSource, fields: Set<MetadataField>)? {
        struct Front { let source: MetadataSource; let rank: Int; let field: MetadataField }
        var fronts: [Front] = []
        for field in remaining {
            let chain = config.orderedSources(for: field, query: query)
            for (rank, source) in chain.enumerated() {
                guard let provider = providers[source],
                      provider.policy.eligibleTiers.contains(tier),
                      !(tried[field]?.contains(source) ?? false)
                else { continue }
                fronts.append(Front(source: source, rank: rank, field: field))
                break
            }
        }
        guard let chosen = fronts.min(by: { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            if lhs.field.rawValue != rhs.field.rawValue { return lhs.field.rawValue < rhs.field.rawValue }
            return lhs.source.rawValue < rhs.source.rawValue
        }) else { return nil }

        let fields = Set(fronts.filter { $0.source == chosen.source }.map(\.field))
        return (chosen.source, fields)
    }
}
