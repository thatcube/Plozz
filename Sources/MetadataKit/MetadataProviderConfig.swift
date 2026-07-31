import Foundation
import CryptoKit

/// How the TMDb tier is reached. Plozz **ships a TMDb key** because for several
/// video fields TMDb is currently the best *free* source — not because TMDb is
/// preferred as a matter of policy. What Plozz avoids is *reliance*: every
/// TMDb-backed capability has a fallback, so a revoked, throttled or newly-paid
/// key degrades quality, not function.
/// There are four modes:
///
///  - ``proxy``: an optional self-hostable caching proxy that holds a TMDb key
///    server-side and caches responses at the edge. An enhancement (traffic
///    absorption, key rotation without a new build), not a requirement.
///  - ``directToken``: the **bundled** v4 read token baked into the build from the
///    gitignored secrets file. This is the normal path.
///  - ``userToken``: the **bring-your-own-key** mode — a v4 read token the
///    *user* entered in Settings, held in the Keychain. Reached exactly like
///    ``directToken`` (direct to TMDb with a bearer), but distinguished as its own
///    case so it — and only it — carries a ``credentialID`` folded into the result
///    cache + circuit-breaker keys. That keeps one user's private results / bad-key
///    401 from ever being conflated with the built-in path or another key, while the
///    built-in (bundled-token/proxy/disabled) path stays byte-identical.
///  - ``disabled``: no TMDb tier — e.g. a contributor build without the key, or if
///    the key is ever retired. The app leans on the other providers
///    (TheTVDB/TVmaze/AniList/Kitsu/Wikidata) and the user's own server art.
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
/// The TMDb key is bundled at build time (never committed to the repo); a proxy URL
/// can optionally front it. Neither is user-facing — the user can supply their own
/// token, but never has to. A build with neither simply runs the TMDb tier off and
/// falls back to the other providers.
public struct MetadataProviderConfig: Sendable {
    public var tmdb: TMDbAccess

    public init(tmdb: TMDbAccess) {
        self.tmdb = tmdb
    }

    /// Reads configuration from the app's Info.plist. A `TMDBProxyBaseURL` wins when
    /// present (edge caching / key rotation); otherwise the bundled `TMDBBearerToken`
    /// is used; with neither, the TMDb tier is disabled and the other providers carry
    /// the app.
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
    /// top of the built-in resolution. A present, non-empty key wins over the
    /// bundled token and the proxy, so the TMDb tier runs
    /// under the *user's* credential (its own attribution, rate limit, and cache /
    /// breaker namespace). An absent/blank key returns `self` unchanged, so the
    /// built-in path is byte-identical.
    public func withUserToken(_ token: String?) -> MetadataProviderConfig {
        guard let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return self }
        var copy = self
        copy.tmdb = .userToken(trimmed)
        return copy
    }
}
