import Foundation

/// A reachable Plex Media Server discovered through the account's resources.
///
/// Produced by `PlexAuthClient.servers(authToken:)` after the PIN link
/// completes. Carries everything needed to build a `UserSession`: the chosen
/// connection's base URL and the server-scoped access token.
public struct PlexServerCandidate: Hashable, Identifiable, Sendable {
    /// Plex `clientIdentifier` — stable per-server id.
    public var id: String
    public var name: String
    /// Base URL of the best connection (no trailing slash), e.g.
    /// `https://10-0-0-2.<hash>.plex.direct:32400`.
    public var baseURL: URL
    /// Server-scoped access token (`X-Plex-Token`) for browsing/playback.
    public var accessToken: String
    public var isOwned: Bool

    public init(id: String, name: String, baseURL: URL, accessToken: String, isOwned: Bool) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.isOwned = isOwned
    }
}

/// Picks the best connection to reach a Plex server, independent of any
/// transport so it can be unit-tested.
///
/// Preference order (highest first):
///  1. **local, non-relay** — same-LAN direct, fastest;
///  2. **remote, non-relay** — direct over the internet (port-forwarded);
///  3. **relay** — plex.tv relay, slowest, used only as a last resort.
///
/// Within a tier, secure (`https`) connections are preferred so Plozz keeps the
/// token off the wire in cleartext where possible.
public enum PlexConnectionSelector {
    struct Candidate {
        var uri: String?
        var isLocal: Bool
        var isRelay: Bool
        var isSecure: Bool
    }

    static func best(from connections: [PlexConnectionDTO]) -> URL? {
        let candidates = connections.map {
            Candidate(
                uri: $0.uri,
                isLocal: $0.local ?? false,
                isRelay: $0.relay ?? false,
                isSecure: ($0.protocol ?? ($0.uri?.hasPrefix("https") == true ? "https" : "http")) == "https"
            )
        }
        let ranked = candidates
            .filter { $0.uri?.isEmpty == false }
            .sorted { lhs, rhs in
                if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
                // Prefer secure within the same tier.
                return (lhs.isSecure ? 0 : 1) < (rhs.isSecure ? 0 : 1)
            }
        for candidate in ranked {
            if let uri = candidate.uri, let url = URL(string: uri) {
                return url
            }
        }
        return nil
    }
}

private extension PlexConnectionSelector.Candidate {
    /// Lower tier == more preferred.
    var tier: Int {
        if isRelay { return 2 }
        return isLocal ? 0 : 1
    }
}
