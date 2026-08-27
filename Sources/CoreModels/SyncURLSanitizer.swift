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
            var kept: [URLQueryItem] = []
            kept.reserveCapacity(items.count)
            for item in items {
                if sensitiveQueryKeys.contains(item.name.lowercased()) {
                    changed = true
                    continue
                }

                // Plex's photo transcoder carries the resource it will fetch in
                // a `url=` query item, and that inner URL has its OWN
                // `X-Plex-Token`. Filtering only the outer query persisted a live
                // credential inside an apparently harmless value:
                //
                //   /photo/:/transcode?url=/library/…?X-Plex-Token=SECRET
                //
                // It also left the saved URL unusable — the outer request had no
                // token — which is why a relaunch fell through to external art.
                // Sanitize that nested URL exactly like a top-level one.
                if item.name.lowercased() == "url",
                   let value = item.value,
                   let nestedURL = URL(string: value) {
                    let cleaned = sanitize(nestedURL)
                    if cleaned != nestedURL {
                        kept.append(URLQueryItem(
                            name: item.name,
                            value: cleaned.absoluteString
                        ))
                        changed = true
                        continue
                    }
                }
                kept.append(item)
            }
            if changed {
                comps.queryItems = kept.isEmpty ? nil : kept
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

public extension MediaItem {
    /// A copy safe for durable presentation caches.
    ///
    /// Provider URLs are request capabilities: Plex/Jellyfin put credentials in
    /// their query strings, and Plex's transcoder puts another token inside its
    /// nested `url=` value. Home snapshots need the resource identity but must
    /// never become a second credential store. The active provider re-signs owned
    /// watchlist art from `(account, item id)` before render.
    func sanitizingArtworkCredentials() -> Self {
        var copy = self
        let sanitizedProvenance: [String: String] = Dictionary(
            artworkSourceAccountIDsByURL.compactMap {
                key, accountID -> (String, String)? in
                guard let url = URL(string: key) else { return nil }
                return (
                    SyncURLSanitizer.sanitize(url).absoluteString,
                    accountID
                )
            },
            uniquingKeysWith: { first, _ in first }
        )
        copy.posterURL = SyncURLSanitizer.sanitize(posterURL)
        copy.seriesPosterURL = SyncURLSanitizer.sanitize(seriesPosterURL)
        copy.backdropURL = SyncURLSanitizer.sanitize(backdropURL)
        copy.heroBackdropURL = SyncURLSanitizer.sanitize(heroBackdropURL)
        copy.fallbackArtworkURL =
            SyncURLSanitizer.sanitize(fallbackArtworkURL)
        copy.logoURL = SyncURLSanitizer.sanitize(logoURL)
        copy.people = people.map { person in
            var person = person
            person.imageURL = SyncURLSanitizer.sanitize(person.imageURL)
            return person
        }
        copy.artworkSelections = artworkSelections.map { selection in
            ArtworkSelection(
                placement: selection.placement,
                references: selection.references.map { reference in
                    switch reference {
                    case .remote(let url):
                        return .remote(SyncURLSanitizer.sanitize(url))
                    case .networkFile:
                        return reference
                    }
                }
            )
        }
        copy.artworkSourceAccountIDsByURL = Dictionary(
            copy.remoteArtworkURLs.compactMap {
                url -> (String, String)? in
                let key = SyncURLSanitizer.sanitize(url).absoluteString
                return sanitizedProvenance[key].map { (key, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        return copy
    }
}
