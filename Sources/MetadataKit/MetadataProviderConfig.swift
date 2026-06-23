import Foundation

/// How the optional TMDb tier is reached. TMDb's terms forbid embedding an API key
/// in an open-source/client app, so Plozz never ships one. Instead it supports two
/// *maintainer-controlled* (never user-facing) modes, plus "off":
///
///  - ``proxy``: point at a self-hostable caching proxy that holds ONE TMDb key
///    server-side (terms-compliant) and caches responses at the edge. This is the
///    scalable, no-BYOK default for movie/western-TV backdrops, logos and stills.
///  - ``directToken``: a raw v4 read token, used only for the maintainer's own
///    local/TestFlight builds (never committed). Convenient, not for distribution.
///  - ``disabled``: no TMDb tier — the app leans entirely on the keyless providers
///    (AniList/Kitsu/TVmaze/Deezer/MusicBrainz) and the user's own server art.
public enum TMDbAccess: Sendable, Equatable {
    case proxy(baseURL: URL)
    case directToken(String)
    case disabled

    var isEnabled: Bool {
        if case .disabled = self { return false }
        return true
    }
}

/// Resolves how external metadata providers are reached, from the app bundle.
///
/// Everything here is keyless *to the user*: the only configurable values are
/// maintainer infrastructure (a proxy URL) or a local-only token, both optional
/// and absent from the public build — which still gets the full keyless backbone.
public struct MetadataProviderConfig: Sendable {
    public var tmdb: TMDbAccess

    public init(tmdb: TMDbAccess) {
        self.tmdb = tmdb
    }

    /// Reads configuration from the app's Info.plist. A `TMDBProxyBaseURL` wins
    /// (scalable, compliant); otherwise a local `TMDBBearerToken` is honored; with
    /// neither, the TMDb tier is disabled and the keyless providers carry the app.
    public static func resolved(bundle: Bundle = .main) -> MetadataProviderConfig {
        if let proxy = sanitized(bundle.object(forInfoDictionaryKey: "TMDBProxyBaseURL") as? String),
           let url = URL(string: proxy), url.scheme != nil {
            return MetadataProviderConfig(tmdb: .proxy(baseURL: url))
        }
        if let token = sanitized(bundle.object(forInfoDictionaryKey: "TMDBBearerToken") as? String) {
            return MetadataProviderConfig(tmdb: .directToken(token))
        }
        return MetadataProviderConfig(tmdb: .disabled)
    }

    /// Trims, and rejects empty values and the unsubstituted `$(…)` build-setting
    /// placeholder.
    private static func sanitized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty, !trimmed.hasPrefix("$(")
        else { return nil }
        return trimmed
    }
}
