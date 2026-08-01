import CoreModels
import Foundation

public struct ExternalTitleMetadata: Sendable, Equatable {
    public var enrichment: MetadataEnrichment
    public var availability: ExternalTitleAvailability

    public init(
        enrichment: MetadataEnrichment,
        availability: ExternalTitleAvailability
    ) {
        self.enrichment = enrichment
        self.availability = availability
    }
}

/// Provider-independent rich metadata for a synthetic TMDb/Seerr/person-credit
/// item. It never resolves a playable source and never calls a media server.
public actor ExternalTitleMetadataResolver {
    public static let shared = ExternalTitleMetadataResolver()

    private let pipeline: MetadataEnrichmentPipeline
    private let tmdb: TMDbMetadataProvider
    private struct CachedAvailability {
        var value: ExternalTitleAvailability
        var expiresAt: Date
    }
    private var availabilityCache: [String: CachedAvailability] = [:]
    private var availabilityCacheOrder: [String] = []
    private var availabilityTasks:
        [String: Task<ExternalTitleAvailability, Never>] = [:]
    private static let availabilityCacheCapacity = 256

    public init(
        providerConfig: MetadataProviderConfig = .resolved(),
        tvdbConfig: TVDBConfig = .resolved(),
        enrichmentConfig: MetadataEnrichmentConfig = .resolved(),
        cache: ProviderResultCache = ProviderResultCache()
    ) {
        pipeline = ProductionMetadataProviders.makePipeline(
            providerConfig: providerConfig,
            tvdbConfig: tvdbConfig,
            enrichmentConfig: enrichmentConfig,
            cache: cache
        )
        tmdb = TMDbMetadataProvider(access: providerConfig.tmdb)
    }

    public func resolve(
        item: MediaItem,
        regionCode: String
    ) async -> ExternalTitleMetadata {
        let query = MetadataQuery(item).seriesScoped
        let requested: Set<MetadataField> = [
            .overview,
            .genres,
            .taglines,
            .posterURL,
            .logoURL,
            .detailBackdrop,
            .cast,
            .providerID(ProviderIDNamespace.tmdb.canonicalKey),
            .providerID(ProviderIDNamespace.tvdb.canonicalKey),
            .providerID(ProviderIDNamespace.imdb.canonicalKey),
        ]
        let present = Self.presentFields(in: item)
        async let enrichment = pipeline.enrich(
            query,
            present: present,
            requesting: requested,
            tier: .foregroundFill
        )
        async let availability = availability(
            for: item,
            regionCode: regionCode
        )
        return await ExternalTitleMetadata(
            enrichment: enrichment,
            availability: availability
        )
    }

    /// Availability-only fast path for the Home hero. The fronted slide does not
    /// need full detail enrichment, and the same region/title answer is shared
    /// with the detail page for the rest of the process lifetime.
    public func availability(
        for item: MediaItem,
        regionCode: String
    ) async -> ExternalTitleAvailability {
        let query = MetadataQuery(item).seriesScoped
        let region = regionCode.uppercased()
        let key = "\(query.enrichmentCacheKey)|region:\(region)"
        if let cached = availabilityCache[key], cached.expiresAt > Date() {
            return cached.value
        }
        availabilityCache[key] = nil
        if let inFlight = availabilityTasks[key] {
            return await inFlight.value
        }
        let provider = tmdb
        let task = Task {
            await provider.externalAvailability(
                for: query,
                regionCode: region
            )
        }
        availabilityTasks[key] = task
        let resolved = await task.value
        availabilityTasks[key] = nil
        availabilityCache[key] = CachedAvailability(
            value: resolved,
            expiresAt: Date().addingTimeInterval(
                resolved.isEmpty ? 10 * 60 : 6 * 60 * 60
            )
        )
        availabilityCacheOrder.removeAll { $0 == key }
        availabilityCacheOrder.append(key)
        while availabilityCacheOrder.count > Self.availabilityCacheCapacity {
            availabilityCache.removeValue(
                forKey: availabilityCacheOrder.removeFirst()
            )
        }
        return resolved
    }

    private static func presentFields(in item: MediaItem) -> Set<MetadataField> {
        var fields = Set<MetadataField>()
        if item.overview?.isEmpty == false { fields.insert(.overview) }
        if !item.genres.isEmpty { fields.insert(.genres) }
        if !item.taglines.isEmpty { fields.insert(.taglines) }
        if item.posterURL != nil { fields.insert(.posterURL) }
        if item.logoURL != nil { fields.insert(.logoURL) }
        if item.backdropURL != nil || item.heroBackdropURL != nil {
            fields.insert(.detailBackdrop)
        }
        if !item.cast.isEmpty { fields.insert(.cast) }
        for key in item.providerIDs.keys {
            fields.insert(.providerID(key))
        }
        return fields
    }
}
