import Foundation
import CoreModels

/// The single front door for resolving external artwork — the piece that makes the
/// provider set *scalable and content-aware*.
///
/// Given a ``MediaItem`` and an ``ArtworkKind``, the router:
///   1. classifies the item's ``ContentType`` (anime / movie / tvShow / music),
///   2. runs an ordered, content-type-specific fallback chain of providers
///      (keyless per-IP APIs first, the optional TMDb tier as backup),
///   3. memoizes the resolved URL in the persistent ``MetadataDiskCache`` so the
///      whole library is enriched with a small one-time burst of calls, then
///      effectively none — which is what lets the keyless backbone serve any
///      number of users without ever straining a shared quota.
///
/// It self-configures from the app bundle, so call sites just use
/// ``ArtworkRouter/shared`` without any app wiring.
public actor ArtworkRouter {
    public static let shared = ArtworkRouter()

    private let anilist = AniListArtworkProvider()
    private let kitsu = KitsuArtworkProvider()
    private let tvmaze = TVmazeArtworkProvider()
    private let wikidata = WikidataArtworkProvider()
    private let wikipedia = WikipediaArtworkProvider()
    private let deezer = DeezerMusicProvider()
    private let musicBrainz = MusicBrainzArtworkProvider()
    private var tmdb: TMDbMetadataProvider
    /// Bundled TheTVDB backdrop tier (hero art only). Nil-safe when unconfigured.
    private let tvdb = TVDBArtworkProvider(client: TVDBClient(config: .resolved()))
    private let cache: MetadataDiskCache

    /// Test-only override for the exact-ID original-language lookup. `nil` in
    /// production, where ``resolveExactOriginalLanguage(_:)`` calls the live TMDb
    /// tier; injected by tests to exercise the cache/normalization/keying without a
    /// network call.
    private let injectedOriginalLanguageResolver: (@Sendable (MetadataQuery) async -> String?)?

    /// Positive + negative in-memory cache of resolved original languages, keyed by
    /// the query's show-level external-id identity so every episode of a show — and
    /// every re-play — share a single lookup. A cached `.some(nil)` means "looked,
    /// found nothing" so a miss is never re-fetched within a run.
    private var originalLanguageCache: [String: String?] = [:]

    public init(
        config: MetadataProviderConfig = .resolved(),
        cache: MetadataDiskCache = .shared
    ) {
        self.tmdb = TMDbMetadataProvider(access: config.tmdb)
        self.cache = cache
        self.injectedOriginalLanguageResolver = nil
    }

    /// Testing seam: injects the exact-ID original-language resolver so unit tests
    /// can drive ``originalLanguage(for:)``'s cache/normalization/keying without a
    /// live TMDb request.
    init(
        config: MetadataProviderConfig = MetadataProviderConfig(tmdb: .disabled),
        cache: MetadataDiskCache = .shared,
        exactOriginalLanguageResolver: @escaping @Sendable (MetadataQuery) async -> String?
    ) {
        self.tmdb = TMDbMetadataProvider(access: config.tmdb)
        self.cache = cache
        self.injectedOriginalLanguageResolver = exactOriginalLanguageResolver
    }

    /// Reconfigures the TMDb tier at runtime (e.g. after the user sets a proxy).
    public func reconfigure(_ config: MetadataProviderConfig) {
        self.tmdb = TMDbMetadataProvider(access: config.tmdb)
    }

    /// `true` when the optional TMDb tier is configured (proxy or local token).
    public var isTMDbEnabled: Bool { tmdb.isEnabled }

    // MARK: - Original language (audio "prefer original" policy)

    /// Best-effort ISO-639-1 original language for a SERVER-backed `item` whose
    /// provider gave none (Plex/Jellyfin/Emby never fill `original_language`),
    /// resolved from an **exact external id** (TMDb, or IMDB via `/find`) with no
    /// fuzzy title search, normalized to ISO-639-1, and cached (positive +
    /// negative). Returns `nil` when TMDb is unconfigured, the item is music, it
    /// carries no usable external id, or nothing was found — the caller then defers
    /// to the container default.
    ///
    /// This reuses the same shared, self-configuring, provider-id-keyed external-
    /// metadata seam the artwork path already uses for server items (one actor +
    /// the configured TMDb tier), rather than standing up a parallel subsystem, so
    /// playback's "prefer original language" audio policy works for server items
    /// exactly as it already does for direct-share items.
    public func originalLanguage(for item: MediaItem) async -> String? {
        await originalLanguage(for: MetadataQuery(item))
    }

    /// Lower-level entry point taking a prebuilt ``MetadataQuery``.
    public func originalLanguage(for query: MetadataQuery) async -> String? {
        let key = Self.originalLanguageCacheKey(for: query)
        if let hit = originalLanguageCache[key] { return hit }
        let resolved = OriginalLanguageNormalizer.normalized(
            await resolveExactOriginalLanguage(query)
        )
        originalLanguageCache[key] = resolved
        return resolved
    }

    private func resolveExactOriginalLanguage(_ query: MetadataQuery) async -> String? {
        if let injectedOriginalLanguageResolver {
            return await injectedOriginalLanguageResolver(query)
        }
        return await tmdb.originalLanguage(forExactMatchOf: query)
    }

    /// Stable identity for the original-language cache: a concrete **show-level**
    /// external id when present (so all episodes of a show and every re-play share
    /// one entry), else a normalized title+year. Never keyed on a per-episode id.
    static func originalLanguageCacheKey(for query: MetadataQuery) -> String {
        var parts: [String] = ["origlang", query.contentType.rawValue]
        let showTMDb: String? = query.providerIDs.providerID(.seriesTmdb)
            ?? ((!query.isTV || query.kind == .series) ? query.providerIDs.providerID(.tmdb) : nil)
        if let showTMDb {
            parts.append("tmdb:\(showTMDb)")
        } else if let imdb = query.providerIDs.providerID(.imdb) {
            parts.append("imdb:\(imdb)")
        } else {
            parts.append("t:\(query.title.lowercased())|y:\(query.year.map(String.init) ?? "")")
        }
        return parts.joined(separator: "|")
    }

    // MARK: - Video artwork

    /// Resolves a `kind` artwork URL for `item`, trying the content-type-specific
    /// provider chain and caching the (positive or negative) result. Never throws.
    public func artworkURL(_ kind: ArtworkKind, for item: MediaItem) async -> URL? {
        let query = MetadataQuery(item)
        return await artworkURL(kind, for: query)
    }

    public func sourcedArtworkURL(
        _ kind: ArtworkKind,
        for item: MediaItem
    ) async -> SourcedValue<URL>? {
        await sourcedArtworkURL(kind, for: MetadataQuery(item))
    }

    /// Lower-level entry point taking a prebuilt ``MetadataQuery``.
    public func artworkURL(_ kind: ArtworkKind, for query: MetadataQuery) async -> URL? {
        await sourcedArtworkURL(kind, for: query)?.value
    }

    /// Resolves artwork together with the provider that supplied it.
    public func sourcedArtworkURL(
        _ kind: ArtworkKind,
        for query: MetadataQuery
    ) async -> SourcedValue<URL>? {
        let key = query.cacheKey(for: kind)
        if let hit = await cache.cached(key) {
            guard let hit else { return nil }
            // The pre-provenance URL cache does not retain which provider won.
            return SourcedValue(value: hit, source: .legacyUnknown)
        }

        for provider in chain(for: query.contentType, kind: kind) {
            if let url = await provider.artworkURL(kind, for: query) {
                await cache.store(url, for: key)
                return SourcedValue(
                    value: url,
                    source: MetadataSource(rawValue: provider.id)
                )
            }
        }
        await cache.store(nil, for: key)
        return nil
    }

    /// The ordered provider chain for a content type + artwork kind. Keyless,
    /// per-IP providers come first (they scale infinitely and cover anime/episodes
    /// best); the optional TMDb tier backs them up for heroes/logos/stills.
    private func chain(for type: ContentType, kind: ArtworkKind) -> [any ArtworkProvider] {
        CurrentMetadataPriority.artworkSources(for: type, kind: kind).compactMap {
            provider(for: $0)
        }
    }

    private func provider(for source: MetadataSource) -> (any ArtworkProvider)? {
        switch source {
        case .anilist: anilist
        case .kitsu: kitsu
        case .tvmaze: tvmaze
        case .wikidata: wikidata
        case .wikipedia: wikipedia
        case .tmdb: tmdb
        case .tvdb: tvdb
        default: nil
        }
    }

    // MARK: - Music artwork (separate model path)

    /// A large artist image for a music hero/background. Keyless (Deezer).
    public func artistImageURL(artist: String) async -> URL? {
        let key = "music|artist|\(artist.lowercased())"
        if let hit = await cache.cached(key) { return hit }
        let url = await deezer.artistImageURL(artist: artist)
        await cache.store(url, for: key)
        return url
    }

    /// A large album cover, trying Deezer then MusicBrainz/Cover Art Archive.
    public func albumCoverURL(artist: String?, album: String) async -> URL? {
        let key = "music|album|\((artist ?? "").lowercased())|\(album.lowercased())"
        if let hit = await cache.cached(key) { return hit }
        if let url = await deezer.albumCoverURL(artist: artist, album: album) {
            await cache.store(url, for: key)
            return url
        }
        let fallback = await musicBrainz.albumCoverURL(artist: artist, album: album)
        await cache.store(fallback, for: key)
        return fallback
    }
}
