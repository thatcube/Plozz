import Foundation
import CryptoKit

/// How the optional TMDb tier is reached. TMDb's terms forbid embedding an API key
/// in an open-source/client app, so Plozz never ships one. Instead it supports three
/// *maintainer-controlled* (never user-facing) modes, the user-supplied BYOK mode,
/// plus "off":
///
///  - ``proxy``: point at a self-hostable caching proxy that holds ONE TMDb key
///    server-side (terms-compliant) and caches responses at the edge. This is the
///    scalable, no-BYOK default for movie/western-TV backdrops, logos and stills.
///  - ``directToken``: a raw v4 read token, used only for the maintainer's own
///    local/TestFlight builds (never committed). Convenient, not for distribution.
///  - ``userToken``: the **Step 9 bring-your-own-key** mode — a v4 read token the
///    *user* entered in Settings, held in the Keychain. Reached exactly like
///    ``directToken`` (direct to TMDb with a bearer), but distinguished as its own
///    case so it — and only it — carries a ``credentialID`` folded into the result
///    cache + circuit-breaker keys. That keeps one user's private results / bad-key
///    401 from ever being conflated with the built-in path or another key, while the
///    built-in (maintainer/proxy/disabled) path stays byte-identical to pre-Step-9.
///  - ``disabled``: no TMDb tier — the app leans entirely on the keyless providers
///    (AniList/Kitsu/TVmaze/Deezer/MusicBrainz) and the user's own server art.
public enum TMDbAccess: Sendable, Equatable {
    case proxy(baseURL: URL)
    case directToken(String)
    case userToken(String)
    case disabled

    var isEnabled: Bool {
        if case .disabled = self { return false }
        return true
    }

    /// A short, opaque, **non-reversible** identity for the active credential, or
    /// `nil` for every built-in path (proxy / maintainer token / disabled).
    ///
    /// Only the user's BYOK token produces one, so the built-in paths keep their
    /// pre-Step-9 (credential-less) cache/breaker namespaces byte-for-byte, while two
    /// different user keys — or a user key vs the built-in path — land in disjoint
    /// namespaces. It is a truncated SHA-256 of the raw token: enough to separate
    /// credentials without collisions, and the raw key never leaves ``userToken``.
    public var credentialID: String? {
        guard case .userToken(let token) = self else { return nil }
        return TMDbAccess.credentialID(forToken: token)
    }

    /// Truncated SHA-256 (first 16 hex chars) of a raw token — the opaque credential
    /// identity. The raw key is never stored, logged, or otherwise recoverable from it.
    static func credentialID(forToken token: String) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
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

    /// Returns a copy with the user's **bring-your-own-key** TMDb token layered on
    /// top of the built-in resolution (Step 9). A present, non-empty key wins over
    /// the maintainer proxy/token and the disabled default, so the TMDb tier runs
    /// under the *user's* credential (its own attribution, rate limit, and cache /
    /// breaker namespace). An absent/blank key returns `self` unchanged, so the
    /// built-in path is byte-identical to pre-Step-9.
    public func withUserToken(_ token: String?) -> MetadataProviderConfig {
        guard let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return self }
        var copy = self
        copy.tmdb = .userToken(trimmed)
        return copy
    }
}
