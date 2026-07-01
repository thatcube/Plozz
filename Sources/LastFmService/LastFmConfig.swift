import Foundation

/// Configuration for the Last.fm music-scrobbling integration.
///
/// Unlike the MAL/AniList relay integrations, Last.fm auth + scrobble signing run
/// **on-device** (matching Trakt/Simkl, whose secrets already ship in the app's
/// Info.plist). Last.fm signs every call with an `api_sig` (MD5 of the sorted
/// params + the shared secret), so the app needs BOTH the API key and the shared
/// secret. Both are read from Info.plist (`LastFmAPIKey` / `LastFmSharedSecret`,
/// substituted from the gitignored `Config/Secrets.local.xcconfig`), falling back
/// to the process environment.
public struct LastFmConfig: Sendable, Equatable {
    public var apiKey: String?
    public var sharedSecret: String?
    /// Root of the Last.fm web-services API (calls hit `/2.0/`).
    public var apiBaseURL: URL
    /// The desktop-auth approval page the user visits to grant access.
    public var authPageURL: URL

    public init(
        apiKey: String? = nil,
        sharedSecret: String? = nil,
        apiBaseURL: URL = URL(string: "https://ws.audioscrobbler.com")!,
        authPageURL: URL = URL(string: "https://www.last.fm/api/auth/")!
    ) {
        self.apiKey = Self.sanitize(apiKey)
        self.sharedSecret = Self.sanitize(sharedSecret)
        self.apiBaseURL = apiBaseURL
        self.authPageURL = authPageURL
    }

    /// Signing requires both the API key and the shared secret.
    public var isConfigured: Bool {
        apiKey != nil && sharedSecret != nil
    }

    public static func resolved(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> LastFmConfig {
        let plistKey = bundle.object(forInfoDictionaryKey: "LastFmAPIKey") as? String
        let plistSecret = bundle.object(forInfoDictionaryKey: "LastFmSharedSecret") as? String
        return LastFmConfig(
            apiKey: sanitize(plistKey) ?? sanitize(environment["LASTFM_API_KEY"]),
            sharedSecret: sanitize(plistSecret) ?? sanitize(environment["LASTFM_SHARED_SECRET"])
        )
    }

    private static func sanitize(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !trimmed.contains("$(")
        else { return nil }
        return trimmed
    }
}
