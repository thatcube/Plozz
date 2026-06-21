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
        guard let key = config.omdbAPIKey else {
            return DisabledRatingsProvider()
        }
        let omdb = OMDbRatingsProvider(apiKey: key, baseURL: config.omdbBaseURL, http: http)
        let diskURL = cacheDirectory?.appendingPathComponent("plozz-ratings-cache.json")
        let cache = RatingsCache(ttl: config.cacheTTL, diskURL: diskURL)
        return CachingRatingsProvider(base: omdb, cache: cache)
    }

    /// The app's caches directory (best-effort; `nil` falls back to memory-only).
    public static func defaultCacheDirectory() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    }
}
