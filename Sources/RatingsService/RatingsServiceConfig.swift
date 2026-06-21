import Foundation

/// Configuration for external ratings enrichment.
///
/// The OMDb API key is read from configuration only and is **never committed**.
/// When no key resolves, OMDb enrichment is disabled and only the backend's
/// native ratings are shown.
public struct RatingsServiceConfig: Sendable {
    /// OMDb API key, or `nil` when enrichment should be disabled.
    public var omdbAPIKey: String?
    /// How long a cached rating set stays fresh.
    public var cacheTTL: TimeInterval
    /// OMDb API base URL.
    public var omdbBaseURL: URL

    public init(
        omdbAPIKey: String? = nil,
        cacheTTL: TimeInterval = 60 * 60 * 24 * 7,
        omdbBaseURL: URL = URL(string: "https://www.omdbapi.com")!
    ) {
        self.omdbAPIKey = Self.sanitize(omdbAPIKey)
        self.cacheTTL = cacheTTL
        self.omdbBaseURL = omdbBaseURL
    }

    /// Resolves configuration from the app bundle's Info.plist (`OMDBAPIKey`),
    /// falling back to the `OMDB_API_KEY` process-environment variable (handy
    /// for `swift test`/CI and local runs).
    public static func resolved(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> RatingsServiceConfig {
        let plistKey = bundle.object(forInfoDictionaryKey: "OMDBAPIKey") as? String
        let envKey = environment["OMDB_API_KEY"]
        return RatingsServiceConfig(omdbAPIKey: sanitize(plistKey) ?? sanitize(envKey))
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
