import Foundation
import CoreNetworking

/// Builds the app's external-ratings provider from configuration.
///
/// Returns a cached OMDb provider when an API key is configured, otherwise a
/// `DisabledRatingsProvider` so callers always receive a usable, non-optional
/// value and the detail screen still shows backend-native ratings.
public enum RatingsServiceFactory {
    public static func make(
        config: RatingsServiceConfig = .resolved(),
        http: HTTPClient = URLSessionHTTPClient(),
        cacheDirectory: URL? = defaultCacheDirectory()
    ) -> any ExternalRatingsProviding {
        // AniList anime scores are keyless and per-IP, so they're always on — the
        // anime experience never depends on any configured key.
        let anilist = AniListRatingsProvider()

        let base: any ExternalRatingsProviding
        if let key = config.omdbAPIKey {
            let omdb = OMDbRatingsProvider(apiKey: key, baseURL: config.omdbBaseURL, http: http)
            // OMDb (IMDb/RT/Metacritic) is authoritative for movies/western TV and
            // is merged over the keyless AniList score for anime titles.
            base = CompositeRatingsProvider([anilist, omdb])
        } else {
            // No OMDb key: still serve keyless AniList scores for anime.
            base = anilist
        }
        let diskURL = cacheDirectory?.appendingPathComponent("plozz-ratings-cache.json")
        let cache = RatingsCache(ttl: config.cacheTTL, diskURL: diskURL)
        return CachingRatingsProvider(base: base, cache: cache)
    }

    /// The app's caches directory (best-effort; `nil` falls back to memory-only).
    public static func defaultCacheDirectory() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    }
}
