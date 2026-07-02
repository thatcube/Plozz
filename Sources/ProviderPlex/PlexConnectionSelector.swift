import Foundation
import CoreModels

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
    /// All usable connections for this server, most-preferred first
    /// (`baseURL` is `connectionURLs.first`). Persisted on the session so the
    /// client can probe and self-heal onto a reachable one later.
    public var connectionURLs: [URL]
    /// Server-scoped access token (`X-Plex-Token`) for browsing/playback.
    public var accessToken: String
    public var isOwned: Bool

    public init(id: String, name: String, baseURL: URL, accessToken: String, isOwned: Bool) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.connectionURLs = [baseURL]
        self.accessToken = accessToken
        self.isOwned = isOwned
    }

    public init(id: String, name: String, connectionURLs: [URL], accessToken: String, isOwned: Bool) {
        self.id = id
        self.name = name
        self.baseURL = connectionURLs.first ?? URL(string: "https://localhost")!
        self.connectionURLs = connectionURLs
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
        /// Positive locality classification of the connection host, independent of
        /// Plex's own `local` flag (which it sets to `1` on *every* bound
        /// interface, including a Tailscale/VPN tunnel).
        var locality: SourceLocality
    }

    static func best(from connections: [PlexConnectionDTO]) -> URL? {
        ranked(from: connections).first
    }

    /// All usable connection URLs in preference order (most-preferred first).
    ///
    /// Callers that can probe reachability (e.g. `PlexAuthClient.servers`) walk
    /// this list and pick the first connection that actually answers — important
    /// because Plex advertises *every* address it's bound to as "local",
    /// including container-bridge gateways like `172.18.0.1` that a TV on a
    /// different subnet can never reach.
    static func ranked(from connections: [PlexConnectionDTO]) -> [URL] {
        let candidates = connections.map {
            Candidate(
                uri: $0.uri,
                isLocal: $0.local ?? false,
                isRelay: $0.relay ?? false,
                isSecure: ($0.protocol ?? ($0.uri?.hasPrefix("https") == true ? "https" : "http")) == "https",
                locality: SourceLocalityClassifier.classify(url: $0.uri.flatMap { URL(string: $0) })
            )
        }
        let ranked = candidates
            .filter { $0.uri?.isEmpty == false }
            .sorted { lhs, rhs in
                if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
                // Prefer secure within the same tier.
                return (lhs.isSecure ? 0 : 1) < (rhs.isSecure ? 0 : 1)
            }
        var seen = Set<String>()
        var urls: [URL] = []
        for candidate in ranked {
            guard let uri = candidate.uri, let url = URL(string: uri), seen.insert(uri).inserted else {
                continue
            }
            urls.append(url)
        }
        return urls
    }
}

private extension PlexConnectionSelector.Candidate {
    /// Lower tier == more preferred: `0` same-LAN direct, `1` remote direct,
    /// `2` relay.
    ///
    /// A *positive* `.remote` classification (Tailscale CGNAT `100.64/10`,
    /// `*.ts.net`, Tailscale ULA, or a public IP) **overrides** Plex's `local`
    /// flag so a tunnel connection can never share the LAN tier with a real
    /// same-subnet address — Plex marks every bound interface `local=1`, so
    /// trusting the flag alone routed playback over a sister's Tailscale server
    /// whenever it was listed first. The flag is still trusted for a host the
    /// classifier can't place (e.g. a split-horizon LAN domain), and a positive
    /// `.local` classification wins even if the flag is unset. Mirrors the
    /// locality tiering ``PlexConnectionResolver`` applies at probe time.
    var tier: Int {
        if isRelay { return 2 }
        if locality == .remote { return 1 }
        if locality == .local || isLocal { return 0 }
        return 1
    }
}
