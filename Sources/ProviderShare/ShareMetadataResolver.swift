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
    /// On-disk episode fingerprints (season/episode/title), used to disambiguate a
    /// same-name series collision by content. Empty for movies or when unknown.
    var episodeHints: [SeriesEpisodeHint] = []
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

/// The bundled **TheTVDB** tier layered over the keyless base. Resolves ids +
/// overview + poster + genres from TheTVDB (which, unlike the keyless sources, also
/// covers **movies** — their previously id-less, poster-less gap), then fills any
/// remaining holes keylessly: AniList/MAL ids for anime (TheTVDB lacks these), and
/// `ArtworkRouter` backdrop/logo (+ poster if TheTVDB had none) / `OverviewRouter`.
/// TheTVDB ids are merged in before artwork resolution so the routers match by id.
struct TVDBShareResolver: ShareMetadataResolving {
    let tvdb: TVDBClient

    func resolve(_ request: ShareEnrichRequest) async -> ShareCatalogStore.EnrichmentRecord {
        // Keyless ids: for anime these add AniList/MAL (TheTVDB doesn't carry them);
        // for TV they add IMDb/TVDB but TheTVDB supersedes those below.
        async let keylessIDsTask = KeylessIDResolver().externalIDs(
            title: request.title, year: request.year, isAnime: request.isAnime, isTV: !request.isMovie
        )
        async let tvdbTask = tvdb.resolve(title: request.title, year: request.year,
                                          isMovie: request.isMovie, episodeHints: request.episodeHints)
        var ids = await keylessIDsTask
        let meta = await tvdbTask
        if let meta {
            if let t = meta.tvdbID, !t.isEmpty { ids["Tvdb"] = t }
            if let i = meta.imdbID, !i.isEmpty { ids["Imdb"] = i }
            if let t = meta.tmdbID, !t.isEmpty { ids["Tmdb"] = t }
        }

        let item = MediaItem(
            id: request.itemID,
            title: request.title,
            kind: request.isMovie ? .movie : .series,
            productionYear: request.isMovie ? request.year : nil,
            genres: request.isAnime ? ["Anime"] : (meta?.genres ?? []),
            providerIDs: ids
        )

        async let hero = ArtworkRouter.shared.artworkURL(.hero, for: item)
        async let logo = ArtworkRouter.shared.artworkURL(.logo, for: item)
        // Poster: prefer TheTVDB's (real, high-quality, and the only source for
        // movie posters), else the keyless router.
        let poster: URL?
        if let tvdbPoster = meta?.posterURL {
            poster = tvdbPoster
        } else {
            poster = await ArtworkRouter.shared.artworkURL(.poster, for: item)
        }
        let overview: String?
        if let tvdbOverview = meta?.overview {
            overview = tvdbOverview
        } else {
            overview = await OverviewRouter.shared.overview(for: item)
        }

        return ShareCatalogStore.EnrichmentRecord(
            providerIDs: ids,
            overview: overview,
            genres: meta?.genres ?? [],
            runtime: nil,
            posterURL: poster,
            backdropURL: await hero,
            logoURL: await logo
        )
    }
}
