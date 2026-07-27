import Foundation

/// Configuration for external ratings enrichment.
///
/// The OMDb API key is read from configuration only and is **never committed**.
/// When no key resolves, OMDb enrichment is disabled and only the backend's
/// native ratings are shown.
public struct RatingsServiceConfig: Sendable {
    /// OMDb API key, or `nil` when enrichment should be disabled.
    public var omdbAPIKey: String?
    /// TMDb v4 read token, or `nil` when the TMDb tier is unavailable. Shares the
    /// app's existing artwork credential — no separate key, no separate quota.
    public var tmdbBearerToken: String?
    /// How long a cached rating set stays fresh.
    public var cacheTTL: TimeInterval
    /// OMDb API base URL.
    public var omdbBaseURL: URL

    public init(
        omdbAPIKey: String? = nil,
        tmdbBearerToken: String? = nil,
        cacheTTL: TimeInterval = 60 * 60 * 24 * 7,
        omdbBaseURL: URL = URL(string: "https://www.omdbapi.com")!
    ) {
        self.omdbAPIKey = Self.sanitize(omdbAPIKey)
        self.tmdbBearerToken = Self.sanitize(tmdbBearerToken)
        self.cacheTTL = cacheTTL
        self.omdbBaseURL = omdbBaseURL
    }

    /// Resolves configuration from the app bundle's Info.plist (`OMDBAPIKey`,
    /// `TMDBBearerToken`), falling back to the `OMDB_API_KEY` /
    /// `TMDB_BEARER_TOKEN` process-environment variables (handy for
    /// `swift test`/CI and local runs).
    public static func resolved(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> RatingsServiceConfig {
        let plistKey = bundle.object(forInfoDictionaryKey: "OMDBAPIKey") as? String
        let envKey = environment["OMDB_API_KEY"]
        // Deliberately the same key the artwork tier reads. TMDb ratings ride the
        // credential the app already ships rather than introducing a second one.
        let plistTMDb = bundle.object(forInfoDictionaryKey: "TMDBBearerToken") as? String
        let envTMDb = environment["TMDB_BEARER_TOKEN"]
        return RatingsServiceConfig(
            omdbAPIKey: sanitize(plistKey) ?? sanitize(envKey),
            tmdbBearerToken: sanitize(plistTMDb) ?? sanitize(envTMDb)
        )
    }

    /// Normalizes a raw key: trims whitespace and rejects empty strings and the
    /// unsubstituted build-setting placeholder (`$(OMDB_API_KEY)`).
    private static func sanitize(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !trimmed.contains("$(")
        else { return nil }
        return trimmed
    }
}
