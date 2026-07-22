import Foundation
import CoreModels

/// Whether any wide-backdrop variant is among the requested fields. The three
/// backdrop fields are served together (one response → home hero + detail backdrop),
/// so providers test them as a group.
func requestsBackdrop(_ missing: Set<MetadataField>) -> Bool {
    missing.contains(.backdropURL) || missing.contains(.homeHero) || missing.contains(.detailBackdrop)
}

// MARK: - Generic single-URL artwork adapter

/// Seam over a single-URL artwork source (any ``ArtworkProvider``) so the fallback
/// and isolated art sources (Kitsu, Wikidata, Wikipedia artwork) plug into the
/// pipeline without bespoke code. A resolved backdrop becomes a one-element
/// candidate list; the multi-candidate set comes from the dedicated TMDb adapter.
public struct ArtworkEnrichmentAdapter: MetadataEnrichmentProvider {
    public let id: MetadataSource
    public let capabilities: Set<MetadataCapability>
    public let policy: ProviderPolicy
    private let provider: any ArtworkProvider

    public init(
        id: MetadataSource,
        capabilities: Set<MetadataCapability>,
        policy: ProviderPolicy = ProviderPolicy(),
        provider: any ArtworkProvider
    ) {
        self.id = id
        self.capabilities = capabilities
        self.policy = policy
        self.provider = provider
    }

    public func enrich(_ query: MetadataQuery, missing: Set<MetadataField>) async -> MetadataEnrichment {
        var out = MetadataEnrichment()
        if capabilities.contains(.poster), missing.contains(.posterURL),
           let url = await provider.artworkURL(.poster, for: query) {
            out.posterURL = SourcedValue(value: url, source: id)
        }
        if capabilities.contains(.backdrop), requestsBackdrop(missing),
           let url = await provider.artworkURL(.hero, for: query) {
            out.backdropCandidates = [SourcedValue(value: url, source: id)]
        }
        if capabilities.contains(.logo), missing.contains(.logoURL),
           let url = await provider.artworkURL(.logo, for: query) {
            out.logoURL = SourcedValue(value: url, source: id)
        }
        if capabilities.contains(.episodeStill), missing.contains(.episodeThumbnail),
           let url = await provider.artworkURL(.thumbnail, for: query) {
            out.episodeStillURL = SourcedValue(value: url, source: id)
        }
        return out
    }
}

// MARK: - TheTVDB (canonical: ids, text, poster, backdrop)

/// The subset of TheTVDB resolution the enrichment adapter needs. `TVDBClient`
/// conforms, and tests substitute a fake — no network in the mapping tests.
public protocol TVDBEnriching: Sendable {
    func resolve(byTVDBID id: String, isMovie: Bool) async -> TVDBMetadata?
    func resolve(titles: [String], year: Int?, isMovie: Bool, episodeHints: [SeriesEpisodeHint]) async -> TVDBMetadata?
    func backdropURL(title: String, year: Int?, isMovie: Bool, tvdbID: String?) async -> URL?
    /// The series' next scheduled episode by a known TheTVDB id. TheTVDB's `nextAired`
    /// is a bare calendar day (`dateOnly`); the season/episode/title are filled
    /// best-effort by matching that day against the series' episode list. Returns
    /// `nil` when unconfigured (keyless) or the series has no scheduled next episode.
    func nextAired(byTVDBID id: String) async -> ProviderNextEpisode?
}

extension TVDBClient: TVDBEnriching {}

/// TheTVDB as the canonical primary source for movies + TV (and anime *identity*):
/// external ids, canonical title/overview/genres, poster, and a hero backdrop. An
/// exact-id lookup (a known `Tvdb` id threaded in by the pipeline) is preferred over
/// a title search, so no duplicate work is done.
public struct TVDBEnrichmentProvider: MetadataEnrichmentProvider {
    public let id: MetadataSource = .tvdb
    public let capabilities: Set<MetadataCapability> = [.externalIDs, .canonicalText, .poster, .backdrop, .nextAiringEpisode]
    public let policy: ProviderPolicy
    private let client: any TVDBEnriching

    public init(client: any TVDBEnriching, policy: ProviderPolicy = ProviderPolicy()) {
        self.client = client
        self.policy = policy
    }

    public func enrich(_ query: MetadataQuery, missing: Set<MetadataField>) async -> MetadataEnrichment {
        guard query.contentType != .music else { return MetadataEnrichment() }
        let isMovie = !query.isTV
        let knownTVDB = query.providerIDs.providerID(.tvdb).flatMap { $0.isEmpty ? nil : $0 }

        // Only the schedule is being asked for and there's nothing else to resolve —
        // TheTVDB schedule needs a concrete id, so skip the show resolve entirely.
        let wantsResolveFields = missing.contains(.title) || missing.contains(.overview)
            || missing.contains(.genres) || missing.contains(.posterURL) || requestsBackdrop(missing)
            || missing.contains { $0.rawValue.hasPrefix("providerID.") }

        var out = MetadataEnrichment()
        var meta: TVDBMetadata?
        if wantsResolveFields {
            if let known = knownTVDB, let byID = await client.resolve(byTVDBID: known, isMovie: isMovie) {
                meta = byID
            } else if knownTVDB == nil {
                meta = await client.resolve(titles: [query.title], year: query.year, isMovie: isMovie, episodeHints: [])
            }
        }

        if let meta {
            let sourceURL = Self.sourceURL(tvdbID: meta.tvdbID, isMovie: isMovie)
            if let t = meta.tvdbID, !t.isEmpty {
                out.externalIDs["Tvdb"] = SourcedValue(value: t, source: .tvdb, sourceURL: sourceURL)
            }
            if let i = meta.imdbID, !i.isEmpty {
                out.externalIDs["Imdb"] = SourcedValue(value: i, source: .tvdb, sourceURL: sourceURL)
            }
            if let m = meta.tmdbID, !m.isEmpty {
                out.externalIDs["Tmdb"] = SourcedValue(value: m, source: .tvdb, sourceURL: sourceURL)
            }
            if missing.contains(.title), let title = meta.title, !title.isEmpty {
                out.title = SourcedValue(value: title, source: .tvdb, sourceURL: sourceURL)
            }
            if missing.contains(.overview), let overview = meta.overview, !overview.isEmpty {
                out.overview = SourcedValue(value: overview, source: .tvdb, sourceURL: sourceURL)
            }
            if missing.contains(.genres), !meta.genres.isEmpty {
                out.genres = SourcedValue(value: meta.genres, source: .tvdb, sourceURL: sourceURL)
            }
            if missing.contains(.posterURL), let poster = meta.posterURL {
                out.posterURL = SourcedValue(value: poster, source: .tvdb, sourceURL: sourceURL)
            }
            if requestsBackdrop(missing),
               let backdrop = await client.backdropURL(
                   title: meta.title ?? query.title, year: meta.year ?? query.year,
                   isMovie: isMovie, tvdbID: meta.tvdbID
               ) {
                out.backdropCandidates = [SourcedValue(value: backdrop, source: .tvdb, sourceURL: sourceURL)]
            }
        }

        if missing.contains(.nextAiringEpisode), query.isTV,
           let tvdbID = meta?.tvdbID ?? knownTVDB,
           let next = await client.nextAired(byTVDBID: tvdbID) {
            out.upcomingEpisode = next.upcomingEpisode(
                seriesIdentity: .external(source: "tvdb", value: tvdbID),
                source: .tvdb,
                refreshedAt: Date()
            )
        }
        return out
    }

    static func sourceURL(tvdbID: String?, isMovie: Bool) -> URL? {
        guard let tvdbID, !tvdbID.isEmpty else { return nil }
        return URL(string: "https://api4.thetvdb.com/v4/\(isMovie ? "movies" : "series")/\(tvdbID)/extended")
    }
}

// MARK: - TMDb (primary artwork: poster, backdrop candidate set, logo, still)

/// The subset of TMDb the enrichment adapter needs; `TMDbMetadataProvider` conforms.
public protocol TMDbEnriching: Sendable {
    var isEnabled: Bool { get }
    func backdropURLs(for query: MetadataQuery, limit: Int) async -> [URL]
    func artworkURL(_ kind: ArtworkKind, for query: MetadataQuery) async -> URL?
}

extension TMDbMetadataProvider: TMDbEnriching {}

/// TMDb as the primary external artwork source while configured: an ordered backdrop
/// candidate set (serves home hero + a distinct detail backdrop from one response),
/// poster, clear logo, and per-episode stills. Inert when TMDb isn't configured.
public struct TMDbEnrichmentProvider: MetadataEnrichmentProvider {
    public let id: MetadataSource = .tmdb
    public let capabilities: Set<MetadataCapability> = [.poster, .backdrop, .logo, .episodeStill]
    public let policy: ProviderPolicy
    private let provider: any TMDbEnriching
    private let backdropLimit: Int

    public init(provider: any TMDbEnriching, backdropLimit: Int = 4, policy: ProviderPolicy = ProviderPolicy()) {
        self.provider = provider
        self.backdropLimit = backdropLimit
        self.policy = policy
    }

    public func enrich(_ query: MetadataQuery, missing: Set<MetadataField>) async -> MetadataEnrichment {
        guard provider.isEnabled else { return MetadataEnrichment() }
        var out = MetadataEnrichment()
        if requestsBackdrop(missing) {
            let urls = await provider.backdropURLs(for: query, limit: backdropLimit)
            out.backdropCandidates = urls.map { SourcedValue(value: $0, source: .tmdb) }
        }
        if missing.contains(.posterURL), let url = await provider.artworkURL(.poster, for: query) {
            out.posterURL = SourcedValue(value: url, source: .tmdb)
        }
        if missing.contains(.logoURL), let url = await provider.artworkURL(.logo, for: query) {
            out.logoURL = SourcedValue(value: url, source: .tmdb)
        }
        if missing.contains(.episodeThumbnail), let url = await provider.artworkURL(.thumbnail, for: query) {
            out.episodeStillURL = SourcedValue(value: url, source: .tmdb)
        }
        return out
    }
}

// MARK: - AniList (anime ids, score, poster, banner)

/// The subset of AniList the enrichment adapter needs; `AniListArtworkProvider`
/// conforms via `fetchMedia`.
public protocol AniListEnriching: Sendable {
    func fetchMedia(for query: MetadataQuery) async -> AniListArtworkProvider.Media?
}

extension AniListArtworkProvider: AniListEnriching {}

/// AniList as the anime identity/art source: AniList id, community score, vertical
/// poster (cover), and a wide banner used both for the banner slot and the hero
/// backdrop. Anime only.
public struct AniListEnrichmentProvider: MetadataEnrichmentProvider {
    public let id: MetadataSource = .anilist
    public let capabilities: Set<MetadataCapability> = [.externalIDs, .score, .poster, .banner, .backdrop, .nextAiringEpisode]
    public let policy: ProviderPolicy
    private let client: any AniListEnriching

    public init(client: any AniListEnriching, policy: ProviderPolicy = ProviderPolicy()) {
        self.client = client
        self.policy = policy
    }

    public func enrich(_ query: MetadataQuery, missing: Set<MetadataField>) async -> MetadataEnrichment {
        guard query.contentType == .anime, let media = await client.fetchMedia(for: query) else {
            return MetadataEnrichment()
        }
        let sourceURL = media.id.flatMap { URL(string: "https://anilist.co/anime/\($0)") }
        var out = MetadataEnrichment()
        if let anilist = media.id {
            out.externalIDs["AniList"] = SourcedValue(value: String(anilist), source: .anilist, sourceURL: sourceURL)
        }
        if let mal = media.idMal {
            out.externalIDs["Mal"] = SourcedValue(value: String(mal), source: .anilist, sourceURL: sourceURL)
        }
        if let score = media.averageScore {
            out.score = SourcedValue(value: Double(score) / 10.0, source: .anilist, sourceURL: sourceURL)
        }
        if missing.contains(.posterURL), let raw = media.coverImage?.extraLarge ?? media.coverImage?.large,
           let url = URL(string: raw) {
            out.posterURL = SourcedValue(value: url, source: .anilist, sourceURL: sourceURL)
        }
        if let banner = media.bannerImage, let url = URL(string: banner) {
            out.bannerURL = SourcedValue(value: url, source: .anilist, sourceURL: sourceURL)
            if requestsBackdrop(missing) {
                out.backdropCandidates = [SourcedValue(value: url, source: .anilist, sourceURL: sourceURL)]
            }
        }
        if missing.contains(.nextAiringEpisode), let anilistID = media.id,
           let schedule = media.nextAiringEpisode,
           let airingAt = schedule.airingAt {
            // AniList uses absolute episode numbering within the media entry, and
            // `airingAt` is an exact Unix timestamp — never a per-season (S, E), so
            // the season/episode fields stay nil (never guessed).
            out.upcomingEpisode = ProviderNextEpisode(
                absoluteEpisodeNumber: schedule.episode,
                airDate: Date(timeIntervalSince1970: TimeInterval(airingAt)),
                datePrecision: .dateAndTime,
                sourceURL: sourceURL
            ).upcomingEpisode(
                seriesIdentity: .external(source: "anilist", value: String(anilistID)),
                source: .anilist,
                refreshedAt: Date()
            )
        }
        return out
    }
}
