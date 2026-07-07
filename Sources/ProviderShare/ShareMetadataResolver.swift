import Foundation
import CoreModels
import MetadataKit

/// A request to enrich one logical share item (movie or series).
struct ShareEnrichRequest: Sendable, Equatable {
    var itemID: String
    var title: String
    var year: Int?
    var isMovie: Bool
    var isAnime: Bool
}

/// Resolves metadata (external ids + overview + artwork) for a bare share item.
/// Abstracted so a keyed tier (TheTVDB — Phase 2b) can layer on top of the
/// keyless base without changing the enricher.
protocol ShareMetadataResolving: Sendable {
    func resolve(_ request: ShareEnrichRequest) async -> ShareCatalogStore.EnrichmentRecord
}

/// The keyless enrichment tier: strong external ids via ``KeylessIDResolver``
/// (AniList/MAL for anime, TVmaze IMDb/TVDB for TV), plus artwork via
/// ``ArtworkRouter`` and an overview via ``OverviewRouter`` — all no-API-key.
///
/// The resolved ids are stamped onto the synthetic query item **before** artwork
/// resolution, so the routers can match by id (accurate) rather than title alone.
struct KeylessShareResolver: ShareMetadataResolving {
    func resolve(_ request: ShareEnrichRequest) async -> ShareCatalogStore.EnrichmentRecord {
        let ids = await KeylessIDResolver().externalIDs(
            title: request.title,
            year: request.year,
            isAnime: request.isAnime,
            isTV: !request.isMovie
        )

        // Synthetic item so the keyless routers can resolve art/overview. Stamping
        // the resolved ids + an "Anime" genre routes ContentClassifier correctly.
        let item = MediaItem(
            id: request.itemID,
            title: request.title,
            kind: request.isMovie ? .movie : .series,
            productionYear: request.isMovie ? request.year : nil,
            genres: request.isAnime ? ["Anime"] : [],
            providerIDs: ids
        )

        async let poster = ArtworkRouter.shared.artworkURL(.poster, for: item)
        async let hero = ArtworkRouter.shared.artworkURL(.hero, for: item)
        async let logo = ArtworkRouter.shared.artworkURL(.logo, for: item)
        async let overview = OverviewRouter.shared.overview(for: item)

        return ShareCatalogStore.EnrichmentRecord(
            providerIDs: ids,
            overview: await overview,
            genres: [],
            runtime: nil,
            posterURL: await poster,
            backdropURL: await hero,
            logoURL: await logo
        )
    }
}
