import Foundation

/// How reachable a server is from *this device right now* — the axis Plozz uses
/// to prefer the copy of a merged title that will play best.
///
/// A household can hold the same title on several servers: a box on the same
/// LAN as the Apple TV, and a relative's server reached over the internet or a
/// Tailscale tunnel. All else being equal we always want to stream from the
/// **local** one (lowest latency, highest bandwidth, no relay), so locality is
/// the *top* ranking key in ``CrossSourceSelector`` — a local 1080p copy beats a
/// remote 4K copy.
///
/// The raw value is the preference rank (higher = preferred), so tiers compare
/// directly: `local (2) > unknown (1) > remote (0)`. `unknown` sits in the
/// middle so an unclassifiable host (a manually-entered domain that might be a
/// LAN box via split-horizon DNS) never loses to a *known-remote* server nor
/// beats a *known-local* one.
///
/// ACCEPTED CONSEQUENCE (r6-tailscale-vs-unknown): because Tailscale/CGNAT hosts
/// are *positively* classified `.remote` (rank 0) while a bare public DDNS
/// hostname we can't place is `.unknown` (rank 1), a title available on both a
/// Tailscale peer and an unclassifiable public domain will prefer the public
/// domain. This is intentional: a Tailscale tunnel is genuinely a relayed remote
/// path, whereas the unclassifiable domain *might* resolve to a same-LAN box via
/// split-horizon DNS — so ranking the maybe-local host above the definitely-
/// tunnelled one is the safer default. If a user wants to force the tunnelled
/// peer, that is what the (upcoming) per-profile preferred-server override is for,
/// not a change to this conservative tiering.
public enum SourceLocality: Int, Codable, Sendable, Hashable, Comparable {
    /// Reached over the internet / a relay / a Tailscale tunnel (CGNAT or
    /// MagicDNS) — treat as high-latency, low-bandwidth.
    case remote = 0
    /// Reachability couldn't be classified from the connection host.
    case unknown = 1
    /// Same LAN as the device (RFC1918 / loopback / `.local` mDNS, or a
    /// `plex.direct` host whose embedded IP is private).
    case local = 2

    public static func < (lhs: SourceLocality, rhs: SourceLocality) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// The preference rank (higher preferred). Convenience for ranking code that
    /// wants an `Int` without unwrapping the optional tier.
    public var rank: Int { rawValue }
}

/// Provider-agnostic classification of a connection host into a ``SourceLocality``.
///
/// Deliberately conservative: only hosts we can *positively* place on the LAN
/// become `.local`, and only hosts we can *positively* place off-LAN (public
/// IPs, CGNAT/Tailscale, `*.ts.net`) become `.remote`. Everything else is
/// `.unknown`. This mirrors the tiering Plex's own connection resolver applies
/// per server, promoted here so the *cross-server* selector can use it too.
public enum SourceLocalityClassifier {
    /// Classifies a full base URL by its host.
    public static func classify(url: URL?) -> SourceLocality {
        classify(host: url?.host)
    }

    /// Classifies a host string (bare IP, `plex.direct` host, or hostname).
    public static func classify(host rawHost: String?) -> SourceLocality {
        guard let host = rawHost?.lowercased(), !host.isEmpty else { return .unknown }

        // Loopback (the app's own remux proxy or a same-box server).
        if host == "localhost" || host == "127.0.0.1" || host == "::1" { return .local }

        // IPv6 literal (URL hosts may arrive bracketed and/or zone-scoped).
        if let ipv6 = classifyIPv6(host) { return ipv6 }

        // A `plex.direct` host embeds the server's real IP as its first label
        // (`192-168-1-5.<hash>.plex.direct`); classify by that embedded address.
        if let octets = leadingIPv4(host) {
            return classifyIPv4(octets)
        }

        // mDNS / Bonjour names are LAN-only by definition.
        if host.hasSuffix(".local") { return .local }

        // Tailscale MagicDNS names are always the tunnel (remote), never LAN.
        if host.hasSuffix(".ts.net") { return .remote }

        // A bare public-looking IPv6 or an arbitrary hostname can't be placed.
        return .unknown
    }

    /// Classifies an IPv6 literal host (possibly bracketed and/or zone-scoped)
    /// into a ``SourceLocality``, or `nil` when the host is not an IPv6 literal.
    ///
    /// - Loopback `::1` → local.
    /// - Link-local `fe80::/10` and Unique-Local `fc00::/7` (ULA) → local, the
    ///   IPv6 equivalents of RFC1918 — a home LAN reached over IPv6.
    /// - **Tailscale's ULA range `fd7a:115c:a1e0::/48` → remote.** It is
    ///   ULA-shaped but is the tunnel, not the LAN, so it must be caught *before*
    ///   the generic ULA rule (mirrors the CGNAT `100.64/10` carve-out for v4).
    /// - Any other global-unicast IPv6 → remote.
    static func classifyIPv6(_ rawHost: String) -> SourceLocality? {
        var host = rawHost
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        // Strip an interface zone id (`fe80::1%en0`).
        let addr = (host.split(separator: "%").first.map(String.init) ?? host).lowercased()
        // An IPv6 literal contains at least two colons; a bare hostname never does
        // (URL.host has already stripped any `:port`).
        guard addr.contains("::") || addr.filter({ $0 == ":" }).count >= 2 else { return nil }

        if addr == "::1" { return .local }                 // loopback
        if addr.hasPrefix("fd7a:115c:a1e0") { return .remote } // Tailscale ULA — the tunnel
        // Link-local fe80::/10 (fe80–febf).
        if addr.hasPrefix("fe8") || addr.hasPrefix("fe9")
            || addr.hasPrefix("fea") || addr.hasPrefix("feb") { return .local }
        // Unique-Local fc00::/7 (fc00–fdff) — the IPv6 "private LAN" range.
        if addr.hasPrefix("fc") || addr.hasPrefix("fd") { return .local }
        // Anything else that parsed as IPv6 is a routable/global address.
        return .remote
    }

    /// Classifies four IPv4 octets by RFC1918 / loopback / CGNAT membership.
    static func classifyIPv4(_ octets: [Int]) -> SourceLocality {
        guard octets.count == 4 else { return .unknown }
        switch (octets[0], octets[1]) {
        case (127, _):
            return .local                    // loopback
        case (10, _), (192, 168):
            return .local                    // RFC1918 home LAN
        case (172, 16...31):
            return .local                    // RFC1918 (Docker bridge / LAN)
        case (169, 254):
            return .local                    // link-local
        case (100, 64...127):
            return .remote                   // CGNAT 100.64.0.0/10 — Tailscale tunnel
        default:
            return .remote                   // routable public address
        }
    }

    /// Extracts the leading IPv4 address from either a bare-IP host
    /// (`192.168.68.71`) or a `plex.direct` host
    /// (`192-168-68-71.<hash>.plex.direct`). `nil` when the host isn't IPv4-shaped.
    static func leadingIPv4(_ host: String) -> [Int]? {
        let firstLabel = host.split(separator: ".").first.map(String.init) ?? host
        for separator in [".", "-"] as [Character] {
            let source = separator == "." ? host : firstLabel
            let parts = source.split(separator: separator).map(String.init)
            if parts.count == 4, let octets = octetsIfValid(parts) { return octets }
        }
        return nil
    }

    private static func octetsIfValid(_ parts: [String]) -> [Int]? {
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return octets
    }
}
