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
    func resolve(_ request: ShareEnrichRequest) async -> EnrichmentRecord
}

/// The keyless enrichment tier: strong external ids (AniList/MAL for anime, TVmaze
/// IMDb/TVDB for TV), plus artwork and an overview — all no-API-key. Every external
/// capability is injected (`idResolver`/`artworkResolver`/`overviewResolver`) so this
/// tier reaches no process-wide router directly.
///
/// The resolved ids are stamped onto the synthetic query item **before** artwork
/// resolution, so the routers can match by id (accurate) rather than title alone.
struct KeylessShareResolver: ShareMetadataResolving {
    let idResolver: any ShareExternalIDResolving
    let artworkResolver: any ShareSourcedArtworkResolving
    let overviewResolver: any ShareSourcedOverviewResolving

    func resolve(_ request: ShareEnrichRequest) async -> EnrichmentRecord {
        let sourcedIDs = await idResolver.sourcedExternalIDs(
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

        async let poster = artworkResolver.sourcedArtworkURL(.poster, for: item)
        async let hero = artworkResolver.sourcedArtworkURL(.hero, for: item)
        async let logo = artworkResolver.sourcedArtworkURL(.logo, for: item)
        async let overview = overviewResolver.sourcedOverview(for: item)

        return EnrichmentRecord.sourced(
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
/// injected artwork backdrop/logo (+ poster if TheTVDB had none) / overview.
/// TheTVDB ids are merged in before artwork resolution so the routers match by id.
/// The TVDB client and keyless artwork/overview/id capabilities are all injected, so
/// this tier reaches no process-wide router directly.
struct TVDBShareResolver: ShareMetadataResolving {
    let tvdb: any ShareTVDBMetadataResolving
    let idResolver: any ShareExternalIDResolving
    let artworkResolver: any ShareSourcedArtworkResolving
    let overviewResolver: any ShareSourcedOverviewResolving

    func resolve(_ request: ShareEnrichRequest) async -> EnrichmentRecord {
        // Keyless ids: for anime these add AniList/MAL (TheTVDB doesn't carry them);
        // for TV they add IMDb/TVDB but TheTVDB supersedes those below.
        async let keylessIDsTask = idResolver.sourcedExternalIDs(
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

        async let hero = artworkResolver.sourcedArtworkURL(.hero, for: item)
        async let logo = artworkResolver.sourcedArtworkURL(.logo, for: item)
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
            poster = await artworkResolver.sourcedArtworkURL(.poster, for: item)
        }
        let overview: SourcedValue<String>?
        if let tvdbOverview = meta?.overview {
            overview = SourcedValue(
                value: tvdbOverview,
                source: .tvdb,
                sourceURL: tvdbSourceURL
            )
        } else {
            overview = await overviewResolver.sourcedOverview(for: item)
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

        return EnrichmentRecord.sourced(
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

/// The Step 5 resolver: drives the capability-based ``MetadataEnrichmentPipeline``
/// for a bare share item and maps its ``MetadataEnrichment`` back onto an
/// ``EnrichmentRecord`` with provenance intact.
///
/// This supersedes the split Keyless/TVDB resolvers: the pipeline's provider set
/// already contains TheTVDB (canonical, inert when unconfigured), TMDb (inert when
/// unconfigured), and the keyless anime/TV/fallback sources, ordered by
/// configuration — so one resolver covers every share, direct or otherwise. Locally
/// known ids (NFO / folder tag) are seeded as `present` so the pipeline skips
/// re-resolving them and threads them into exact-id lookups; the store's Step 3
/// sourced-field priority still merges these external results under any
/// higher-priority local values.
struct PipelineShareResolver: ShareMetadataResolving {
    let pipeline: MetadataEnrichmentPipeline
    /// The work tier used for share enrichment. Idle backlog is the dominant path and
    /// is the only tier that admits the idle-only fallback sources (Wikidata /
    /// Wikipedia).
    var tier: MetadataWorkTier = .idleBacklog

    func resolve(_ request: ShareEnrichRequest) async -> EnrichmentRecord {
        var ids = request.knownProviderIDs
        if let tvdb = request.knownTVDBID?.nonBlank, ids.providerID(.tvdb) == nil {
            ids["Tvdb"] = tvdb
        }
        let item = MediaItem(
            id: request.itemID,
            title: request.title,
            kind: request.isMovie ? .movie : .series,
            productionYear: request.isMovie ? request.year : nil,
            genres: request.isAnime ? ["Anime"] : [],
            providerIDs: ids
        )
        let query = MetadataQuery(item)

        let enrichment = await pipeline.enrich(
            query,
            present: Self.presentFields(knownIDs: ids),
            requesting: Self.requestedFields(isAnime: request.isAnime),
            tier: tier
        )

        return EnrichmentRecord.sourced(
            providerIDs: enrichment.externalIDs,
            overview: enrichment.overview,
            genres: enrichment.genres,
            posterURL: enrichment.posterURL,
            // The pipeline keeps an ordered backdrop candidate set; the record persists
            // the top (home-hero) candidate as its single backdrop today.
            backdropURL: enrichment.homeHero,
            logoURL: enrichment.logoURL,
            title: enrichment.title,
            originalLanguage: enrichment.originalLanguage
        )
    }

    /// Fields a higher-priority local source already supplies, so the pipeline neither
    /// re-requests nor overwrites them. Today this is the locally-known id namespaces.
    static func presentFields(knownIDs: [String: String]) -> Set<MetadataField> {
        Set(knownIDs.keys.map { MetadataField.providerID($0) })
    }

    /// The standard external field set a share item wants filled: canonical text,
    /// artwork (including both backdrop screens from one candidate set), and the id
    /// namespaces that let a share merge with its server twin, pull ratings, and
    /// scrobble.
    static func requestedFields(isAnime: Bool) -> Set<MetadataField> {
        var fields: Set<MetadataField> = [
            .title, .overview, .genres,
            .posterURL, .backdropURL, .homeHero, .detailBackdrop, .logoURL,
            .originalLanguage,
            .providerID("Imdb"), .providerID("Tvdb"), .providerID("Tmdb"),
        ]
        if isAnime {
            fields.formUnion([.providerID("AniList"), .providerID("Mal")])
        }
        return fields
    }
}
