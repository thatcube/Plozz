import Foundation
import CoreModels

/// A logical item awaiting external enrichment, surfaced by `ShareCatalogStore`'s
/// pending-work queries. A standalone ProviderShare domain type (no longer nested
/// in the store) so the resolver/enricher/projection depend on the DTO, not on the
/// concrete persistence actor.
struct PendingEnrichment: Sendable, Equatable {
    var itemID: String
    var title: String
    var year: Int?
    var isMovie: Bool
    var isAnime: Bool
    var discoveredAt: Date
}

/// Resolved metadata to persist for one logical item. Standalone ProviderShare
/// domain type shared by the enrichment repository, resolver, and read projection.
struct EnrichmentRecord: Sendable, Equatable {
    var providerIDs: [String: String] = [:]
    var overview: String?
    var genres: [String] = []
    var runtime: TimeInterval?
    var posterURL: URL?
    var backdropURL: URL?
    var logoURL: URL?
    /// The resolved canonical show/movie title (e.g. "Avatar: The Last
    /// Airbender"), overlaid over a generic folder-derived display title at read
    /// time. Persisted in the `title` enrichment column so it survives re-scans.
    var title: String?
    /// The work's original/production audio language (ISO-639-1, lowercased),
    /// resolved by the external pipeline. Projected onto ``MediaItem/originalLanguage``
    /// so the prefer-original-language audio policy can request the true original
    /// track instead of the container's (possibly foreign) default.
    var originalLanguage: String?
    var provenance = MetadataProvenance()

    static func sourced(
        providerIDs: [String: SourcedValue<String>] = [:],
        overview: SourcedValue<String>? = nil,
        genres: SourcedValue<[String]>? = nil,
        runtime: SourcedValue<TimeInterval>? = nil,
        posterURL: SourcedValue<URL>? = nil,
        backdropURL: SourcedValue<URL>? = nil,
        logoURL: SourcedValue<URL>? = nil,
        title: SourcedValue<String>? = nil,
        originalLanguage: SourcedValue<String>? = nil
    ) -> EnrichmentRecord {
        var provenance = MetadataProvenance()
        for (namespace, value) in providerIDs {
            provenance[.providerID(namespace)] = value.attribution
        }
        provenance.set(overview, for: .overview)
        provenance.set(genres, for: .genres)
        provenance.set(runtime, for: .runtime)
        provenance.set(posterURL, for: .posterURL)
        provenance.set(backdropURL, for: .backdropURL)
        provenance.set(logoURL, for: .logoURL)
        provenance.set(title, for: .title)
        provenance.set(originalLanguage, for: .originalLanguage)
        return EnrichmentRecord(
            providerIDs: providerIDs.mapValues(\.value),
            overview: overview?.value,
            genres: genres?.value ?? [],
            runtime: runtime?.value,
            posterURL: posterURL?.value,
            backdropURL: backdropURL?.value,
            logoURL: logoURL?.value,
            title: title?.value,
            originalLanguage: originalLanguage?.value,
            provenance: provenance
        )
    }

    /// Whether this record carries anything worth showing/merging. An *unusable*
    /// result (no ids, overview, or artwork) is treated as a miss — usually a
    /// transient rate-limit/timeout — and is retried across passes rather than
    /// cached as a permanent blank.
    var isUsable: Bool {
        !providerIDs.isEmpty
            || (overview?.isEmpty == false)
            || posterURL != nil || backdropURL != nil || logoURL != nil
    }

    mutating func inferLegacyProvenanceForMissingFields() {
        let legacy = MetadataAttribution(source: .legacyUnknown)
        provenance.fillMissing(
            legacy,
            for: providerIDs.keys.map(MetadataField.providerID)
        )
        if overview?.isEmpty == false { provenance.fillMissing(legacy, for: [.overview]) }
        if !genres.isEmpty { provenance.fillMissing(legacy, for: [.genres]) }
        if runtime != nil { provenance.fillMissing(legacy, for: [.runtime]) }
        if posterURL != nil { provenance.fillMissing(legacy, for: [.posterURL]) }
        if backdropURL != nil { provenance.fillMissing(legacy, for: [.backdropURL]) }
        if logoURL != nil { provenance.fillMissing(legacy, for: [.logoURL]) }
        if title?.isEmpty == false { provenance.fillMissing(legacy, for: [.title]) }
        if originalLanguage?.isEmpty == false { provenance.fillMissing(legacy, for: [.originalLanguage]) }
    }
}
