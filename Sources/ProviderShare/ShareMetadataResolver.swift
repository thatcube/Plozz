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
    /// Extra, more-specific series titles recovered from the FILENAMES when the
    /// (folder-derived) `title` is generic — e.g. an "Avatar (2024)" folder whose
    /// files say "Avatar The Last Airbender". Tried ahead of `title` at search so a
    /// generic folder still resolves. Most-specific first; empty for movies or when
    /// filenames match the folder title.
    var titleAlternates: [String] = []
    /// An EXPLICIT TheTVDB id the library folder declared (`[tvdb-####]`). When
    /// present, enrichment resolves DIRECTLY by this id — authoritative, skipping
    /// the ambiguous title search (fixes the tagged 1999 One Piece anime).
    var knownTVDBID: String? = nil
    /// Already-persisted LOCAL (NFO/filename) provider ids for this item, keyed
    /// by lowercased namespace (`tvdb`, `imdb`, `tmdb`, …) — see
    /// `ShareCatalogStore.localProviderIDs`. Seeded so a resolver that supports
    /// exact-id resolution can skip fuzzy title-based discovery for a namespace
    /// it already knows, without reordering existing external sources or adding
    /// new ones. Does not replace `knownTVDBID` (an authoritative FOLDER tag),
    /// which still wins when both are present.
    var knownProviderIDs: [String: String] = [:]
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
        let sourcedIDs = await KeylessIDResolver().sourcedExternalIDs(
            title: request.title,
            year: request.year,
            isAnime: request.isAnime,
            isTV: !request.isMovie
        )
        let ids = sourcedIDs.mapValues(\.value)

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

        async let poster = ArtworkRouter.shared.sourcedArtworkURL(.poster, for: item)
        async let hero = ArtworkRouter.shared.sourcedArtworkURL(.hero, for: item)
        async let logo = ArtworkRouter.shared.sourcedArtworkURL(.logo, for: item)
        async let overview = OverviewRouter.shared.sourcedOverview(for: item)

        return ShareCatalogStore.EnrichmentRecord.sourced(
            providerIDs: sourcedIDs,
            overview: await overview,
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
        async let keylessIDsTask = KeylessIDResolver().sourcedExternalIDs(
            title: request.title, year: request.year, isAnime: request.isAnime, isTV: !request.isMovie
        )
        // TheTVDB metadata: when the folder declared an explicit [tvdb-####] id,
        // resolve DIRECTLY by that id (authoritative) — otherwise try the
        // more-specific filename-derived titles first (a generic folder like
        // "Avatar (2024)" resolves via "Avatar The Last Airbender"), then the stored
        // folder title. `search` prefers an exact-year hit but falls back to
        // relevance, so a specific query is far less likely to mis-match.
        //
        // A LOCAL (NFO/filename) tvdb id fills in only when no explicit folder
        // tag was already known — the existing folder-tag behavior is preserved
        // exactly; this only extends the SAME "skip the ambiguous title search"
        // treatment to a persisted local id.
        let knownID = request.knownTVDBID ?? request.knownProviderIDs["tvdb"]
        let meta: TVDBMetadata?
        if let knownID {
            if let byID = await tvdb.resolve(byTVDBID: knownID, isMovie: request.isMovie) {
                meta = byID
            } else {
                meta = await tvdb.resolve(titles: request.titleAlternates + [request.title],
                                          year: request.year, isMovie: request.isMovie,
                                          episodeHints: request.episodeHints)
            }
        } else {
            meta = await tvdb.resolve(titles: request.titleAlternates + [request.title],
                                      year: request.year,
                                      isMovie: request.isMovie, episodeHints: request.episodeHints)
        }
        var sourcedIDs = await keylessIDsTask
        let tvdbSourceURL = meta.flatMap {
            Self.sourceURL(tvdbID: $0.tvdbID, isMovie: request.isMovie)
        }
        if let meta {
            if let t = meta.tvdbID, !t.isEmpty {
                sourcedIDs["Tvdb"] = SourcedValue(
                    value: t,
                    source: .tvdb,
                    sourceURL: tvdbSourceURL
                )
            }
            if let i = meta.imdbID, !i.isEmpty {
                sourcedIDs["Imdb"] = SourcedValue(
                    value: i,
                    source: .tvdb,
                    sourceURL: tvdbSourceURL
                )
            }
            if let t = meta.tmdbID, !t.isEmpty {
                sourcedIDs["Tmdb"] = SourcedValue(
                    value: t,
                    source: .tvdb,
                    sourceURL: tvdbSourceURL
                )
            }
        }
        let ids = sourcedIDs.mapValues(\.value)

        // The best display title: TheTVDB's canonical name (which upgrades a generic
        // folder title like "Avatar" → "Avatar: The Last Airbender") else the stored
        // one. Feeding it into the artwork item lets the id- and title-based logo
        // providers target the RIGHT same-named show. (The year is set for
        // completeness but title-based TV art providers currently key on title +
        // provider id, not year.)
        let resolvedTitle = meta?.title?.nonBlank
        let artworkTitle = resolvedTitle ?? request.title
        let item = MediaItem(
            id: request.itemID,
            title: artworkTitle,
            kind: request.isMovie ? .movie : .series,
            productionYear: request.isMovie ? request.year : (meta?.year ?? request.year),
            genres: request.isAnime ? ["Anime"] : (meta?.genres ?? []),
            providerIDs: ids
        )

        async let hero = ArtworkRouter.shared.sourcedArtworkURL(.hero, for: item)
        async let logo = ArtworkRouter.shared.sourcedArtworkURL(.logo, for: item)
        // Poster: prefer TheTVDB's (real, high-quality, and the only source for
        // movie posters), else the keyless router.
        let poster: SourcedValue<URL>?
        if let tvdbPoster = meta?.posterURL {
            poster = SourcedValue(
                value: tvdbPoster,
                source: .tvdb,
                sourceURL: tvdbSourceURL
            )
        } else {
            poster = await ArtworkRouter.shared.sourcedArtworkURL(.poster, for: item)
        }
        let overview: SourcedValue<String>?
        if let tvdbOverview = meta?.overview {
            overview = SourcedValue(
                value: tvdbOverview,
                source: .tvdb,
                sourceURL: tvdbSourceURL
            )
        } else {
            overview = await OverviewRouter.shared.sourcedOverview(for: item)
        }
        let genres = meta.flatMap { metadata -> SourcedValue<[String]>? in
            guard !metadata.genres.isEmpty else { return nil }
            return SourcedValue(
                value: metadata.genres,
                source: .tvdb,
                sourceURL: tvdbSourceURL
            )
        }
        let title = resolvedTitle.map {
            SourcedValue(value: $0, source: .tvdb, sourceURL: tvdbSourceURL)
        }

        return ShareCatalogStore.EnrichmentRecord.sourced(
            providerIDs: sourcedIDs,
            overview: overview,
            genres: genres,
            posterURL: poster,
            backdropURL: await hero,
            logoURL: await logo,
            title: title
        )
    }

    private static func sourceURL(tvdbID: String?, isMovie: Bool) -> URL? {
        guard let tvdbID, !tvdbID.isEmpty else { return nil }
        let resource = isMovie ? "movies" : "series"
        return URL(string: "https://api4.thetvdb.com/v4/\(resource)/\(tvdbID)/extended")
    }
}

private extension String {
    var nonBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
