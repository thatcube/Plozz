import Foundation

// MARK: - Sync URL sanitizer (strip credentials before anything is synced)
//
// CloudKit records must NEVER carry a token/secret. Several URLs the app stores —
// most notably Jellyfin avatar image URLs — embed the bearer token as a query
// parameter (`?api_key=…`) or occasionally as URL user-info (`user:pass@host`).
// If such a URL were placed in a synced descriptor or profile record it would
// publish a live credential to iCloud.
//
// This sanitizer removes credential-bearing user-info and a denylist of known
// auth query parameters from any URL before it enters a synced representation.
// It is:
//   • DETERMINISTIC and IDEMPOTENT — sanitize(sanitize(x)) == sanitize(x) — so a
//     device that captures its own (tokenized) URL and a peer that receives the
//     already-stripped URL both converge on identical bytes (the capture==apply
//     invariant the sync ledger relies on).
//   • NON-DESTRUCTIVE to the resource identity — scheme, host, port, and path are
//     preserved, so the receiving device can re-sign the URL with ITS OWN token
//     at render time.
public enum SyncURLSanitizer {

    /// Query parameter names (compared case-insensitively) that carry credentials.
    /// Anything matching is dropped from a synced URL.
    static let sensitiveQueryKeys: Set<String> = [
        "api_key", "apikey",
        "token", "access_token", "accesstoken", "id_token", "refresh_token",
        "x-emby-token", "x-mediabrowser-token", "x-emby-authorization",
        "x-plex-token", "plextoken", "plex-token",
        "auth", "authorization", "authtoken", "auth_token",
        "password", "passwd", "pwd", "secret", "sig", "signature",
    ]

    /// Return a copy of `url` with credential user-info and sensitive query
    /// parameters removed. Non-URL-decomposable strings are returned unchanged.
    public static func sanitize(_ url: URL) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var changed = false

        if comps.user != nil || comps.password != nil {
            comps.user = nil
            comps.password = nil
            changed = true
        }

        if let items = comps.queryItems, !items.isEmpty {
            let kept = items.filter { !sensitiveQueryKeys.contains($0.name.lowercased()) }
            if kept.count != items.count {
                comps.queryItems = kept.isEmpty ? nil : kept
                changed = true
            }
        }

        guard changed, let out = comps.url else { return url }
        return out
    }

    /// Optional-URL convenience.
    public static func sanitize(_ url: URL?) -> URL? {
        url.map(sanitize)
    }

    /// String convenience for stored URL strings (e.g. `Profile.avatarImageURL`).
    /// A value that isn't a decomposable URL is returned unchanged.
    public static func sanitize(string: String?) -> String? {
        guard let string, !string.isEmpty else { return string }
        guard let url = URL(string: string) else { return string }
        let cleaned = sanitize(url)
        // Nothing stripped → return the ORIGINAL string verbatim (don't re-encode a
        // value that only round-tripped through URLComponents), so a plain string is
        // untouched and the transform stays idempotent.
        return cleaned == url ? string : cleaned.absoluteString
    }

    /// True if the URL carries anything this sanitizer would strip — used by tests
    /// and by apply-side "should I keep the local tokenized URL?" comparisons.
    public static func containsCredential(_ url: URL) -> Bool {
        sanitize(url) != url
    }
}
