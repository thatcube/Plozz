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

    public init(
        config: MetadataProviderConfig = .resolved(),
        cache: MetadataDiskCache = .shared
    ) {
        self.tmdb = TMDbMetadataProvider(access: config.tmdb)
        self.cache = cache
    }

    /// Reconfigures the TMDb tier at runtime (e.g. after the user sets a proxy).
    public func reconfigure(_ config: MetadataProviderConfig) {
        self.tmdb = TMDbMetadataProvider(access: config.tmdb)
    }

    /// `true` when the optional TMDb tier is configured (proxy or local token).
    public var isTMDbEnabled: Bool { tmdb.isEnabled }

    // MARK: - Video artwork

    /// Resolves a `kind` artwork URL for `item`, trying the content-type-specific
    /// provider chain and caching the (positive or negative) result. Never throws.
    public func artworkURL(_ kind: ArtworkKind, for item: MediaItem) async -> URL? {
        let query = MetadataQuery(item)
        return await artworkURL(kind, for: query)
    }

    /// Lower-level entry point taking a prebuilt ``MetadataQuery``.
    public func artworkURL(_ kind: ArtworkKind, for query: MetadataQuery) async -> URL? {
        let key = query.cacheKey(for: kind)
        if let hit = await cache.cached(key) { return hit }

        for provider in chain(for: query.contentType, kind: kind) {
            if let url = await provider.artworkURL(kind, for: query) {
                await cache.store(url, for: key)
                return url
            }
        }
        await cache.store(nil, for: key)
        return nil
    }

    /// The ordered provider chain for a content type + artwork kind. Keyless,
    /// per-IP providers come first (they scale infinitely and cover anime/episodes
    /// best); the optional TMDb tier backs them up for heroes/logos/stills.
    private func chain(for type: ContentType, kind: ArtworkKind) -> [any ArtworkProvider] {
        switch type {
        case .anime:
            switch kind {
            case .hero: return [tmdb, anilist, kitsu]
            case .poster: return [anilist, kitsu, tmdb]
            case .thumbnail: return [tmdb] // real anime stills; series-backdrop fallback handled by callers
            case .logo: return [tmdb, wikidata, wikipedia]
            }
        case .tvShow:
            switch kind {
            case .hero: return [tvdb, tmdb, wikidata, wikipedia]
            case .poster: return [tmdb, tvmaze, wikidata, wikipedia]
            case .thumbnail: return [tmdb, tvmaze]
            case .logo: return [tmdb, wikidata, wikipedia]
            }
        case .movie:
            switch kind {
            case .hero: return [tvdb, tmdb, wikidata, wikipedia]
            case .poster: return [tmdb, wikidata, wikipedia]
            case .thumbnail: return [tmdb]
            case .logo: return [tmdb, wikidata, wikipedia]
            }
        case .unknown:
            switch kind {
            case .hero: return [tvdb, tmdb, wikidata, wikipedia]
            case .poster: return [tmdb, wikidata, wikipedia]
            case .thumbnail: return [tmdb]
            case .logo: return [tmdb, wikidata, wikipedia]
            }
        case .music:
            return []
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
