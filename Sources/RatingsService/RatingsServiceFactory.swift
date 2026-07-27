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
        var providers: [any ExternalRatingsProviding] = [AniListRatingsProvider()]

        // TMDb is the broad-coverage source, and the only one that reaches media
        // shares (SMB/WebDAV/local), which have no server metadata to fall back
        // on. Ordered ahead of OMDb only for readability — sources are merged by
        // their own key, never overwritten positionally.
        if let token = config.tmdbBearerToken {
            providers.append(TMDbRatingsProvider(bearerToken: token, http: http))
        }

        // OMDb (IMDb) is opt-in: its free tier is capped per key per day, so it
        // is only ever configured for builds that have a key to spend.
        if let key = config.omdbAPIKey {
            providers.append(
                OMDbRatingsProvider(apiKey: key, baseURL: config.omdbBaseURL, http: http)
            )
        }

        let base: any ExternalRatingsProviding = providers.count == 1
            ? providers[0]
            : CompositeRatingsProvider(providers)
        let diskURL = cacheDirectory?.appendingPathComponent("plozz-ratings-cache.json")
        let cache = RatingsCache(ttl: config.cacheTTL, diskURL: diskURL)
        return CachingRatingsProvider(base: base, cache: cache)
    }

    /// The app's caches directory (best-effort; `nil` falls back to memory-only).
    public static func defaultCacheDirectory() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    }
}
