import Foundation

/// Configuration for the bundled **TheTVDB** metadata tier.
///
/// TheTVDB v4 uses a single project **API key** (read from `Info.plist` as
/// `TVDBAPIKey`, substituted from the `TVDB_API_KEY` build setting in the
/// gitignored `Config/Secrets.local.xcconfig`). Unlike TMDb, TheTVDB licenses by
/// parent-company revenue (free under $50k/yr, FOSS-friendly), so the key ships in
/// every build rather than being per-user. When absent (e.g. a contributor
/// without a key), the tier is disabled and the keyless providers carry
/// enrichment.
public struct TVDBConfig: Sendable, Equatable {
    public var apiKey: String?
    public var apiBaseURL: URL

    public init(apiKey: String? = nil, apiBaseURL: URL = URL(string: "https://api4.thetvdb.com/v4")!) {
        self.apiKey = Self.sanitize(apiKey)
        self.apiBaseURL = apiBaseURL
    }

    /// Whether a usable key resolved, so the TVDB tier can be offered.
    public var isConfigured: Bool { apiKey != nil }

    /// Resolves from the app bundle's Info.plist, falling back to the process
    /// environment (for `swift test` / CI / local runs).
    public static func resolved(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TVDBConfig {
        let plistKey = bundle.object(forInfoDictionaryKey: "TVDBAPIKey") as? String
        return TVDBConfig(apiKey: sanitize(plistKey) ?? sanitize(environment["TVDB_API_KEY"]))
    }

    /// Trims and rejects empty values and the unsubstituted `$(…)` placeholder.
    private static func sanitize(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty, !trimmed.contains("$(")
        else { return nil }
        return trimmed
    }
}
