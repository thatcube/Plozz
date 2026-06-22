import Foundation
import CoreModels
import CoreNetworking

/// Discovers Jellyfin servers reachable over Tailscale.
///
/// Queries the Tailscale daemon's local API at the well-known Tailscale service IP
/// (`100.100.100.100`) to enumerate active peers, then probes each peer on the standard
/// Jellyfin ports. If Tailscale is not installed or not running, the initial API call
/// fails silently — no errors are surfaced to the user.
///
/// This discovery type is always available (pure URLSession, no Network.framework)
/// and runs in parallel with UDP LAN discovery inside `ServerPickerViewModel`.
///
/// **ATS**: `100.100.100.100` (local API) and `*.ts.net` (MagicDNS) are declared
/// in `NSExceptionDomains` so HTTP connections to those addresses are permitted.
/// HTTP to bare Tailscale IPs (`100.x.x.x`) is not covered — only HTTPS is tried
/// on raw IPs, which works for Jellyfin servers configured with TLS.
public struct TailscaleDiscovery: ServerDiscovering, Sendable {

    /// Tailscale's well-known service IP that exposes the local daemon API.
    /// This address is only reachable when Tailscale is installed and running.
    static let localAPIURL = URL(string: "http://100.100.100.100/localapi/v0/status")!

    private let validator: ServerValidator

    public init(
        validator: ServerValidator = ServerValidator(
            http: URLSessionHTTPClient(session: .plozzDiscovery)
        )
    ) {
        self.validator = validator
    }

    public func discover(timeout: TimeInterval) -> AsyncStream<MediaServer> {
        let validator = self.validator
        return AsyncStream { continuation in
            let task = Task {
                guard let peers = await Self.fetchPeers() else {
                    continuation.finish()
                    return
                }
                await withTaskGroup(of: MediaServer?.self) { group in
                    for peer in peers {
                        if Task.isCancelled { break }
                        let v = validator
                        group.addTask { await Self.probeJellyfin(peer: peer, validator: v) }
                    }
                    for await result in group {
                        if let server = result { continuation.yield(server) }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Tailscale local API

    struct PeerCandidate: Sendable {
        let displayName: String
        /// First Tailscale IP, e.g. `100.x.x.x`.
        let tailscaleIP: String?
        /// MagicDNS FQDN with trailing dot removed, e.g. `server.tailnet-name.ts.net`.
        let dnsName: String?
    }

    private struct TailscaleStatus: Decodable {
        // swiftlint:disable identifier_name
        let BackendState: String?
        let Peer: [String: TailscalePeer]?
        // swiftlint:enable identifier_name

        struct TailscalePeer: Decodable {
            // swiftlint:disable identifier_name
            let HostName: String?
            let DNSName: String?
            let TailscaleIPs: [String]?
            let Online: Bool?
            // swiftlint:enable identifier_name
        }
    }

    /// Fetches and parses the Tailscale peer list.
    /// Returns `nil` if Tailscale is not active or has no online peers.
    static func fetchPeers() async -> [PeerCandidate]? {
        var request = URLRequest(url: localAPIURL)
        request.timeoutInterval = 3
        guard let (data, response) = try? await URLSession.plozzDiscovery.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let status = try? JSONDecoder().decode(TailscaleStatus.self, from: data),
              status.BackendState == "Running",
              let peers = status.Peer else {
            PlozzLog.discovery.info("Tailscale: not active or local API unreachable")
            return nil
        }

        let candidates = peers.values.compactMap { peer -> PeerCandidate? in
            // Only probe peers that are confirmed online. Offline peers time out and
            // slow down the scan without benefit.
            guard peer.Online == true else { return nil }
            // Strip the trailing DNS dot (e.g. "server.ts.net." → "server.ts.net")
            let dns = peer.DNSName.map { n in n.hasSuffix(".") ? String(n.dropLast()) : n }
            let ip = peer.TailscaleIPs?.first
            guard ip != nil || dns != nil else { return nil }
            return PeerCandidate(
                displayName: peer.HostName ?? dns ?? ip ?? "Unknown",
                tailscaleIP: ip,
                dnsName: dns
            )
        }

        PlozzLog.discovery.info("Tailscale: \(candidates.count) online peer(s) to probe for Jellyfin")
        return candidates.isEmpty ? nil : candidates
    }

    // MARK: - Jellyfin probe

    /// Probes a single Tailscale peer for a running Jellyfin server.
    ///
    /// MagicDNS hostnames are tried first (HTTPS then HTTP — HTTP is permitted by the
    /// `ts.net` ATS exception). Bare Tailscale IPs are tried HTTPS-only because we
    /// cannot add a CIDR range to `NSExceptionDomains`; HTTP to `100.x.x.x` would be
    /// blocked by ATS.
    private static func probeJellyfin(
        peer: PeerCandidate,
        validator: ServerValidator
    ) async -> MediaServer? {
        var candidates: [String] = []

        if let dns = peer.dnsName {
            candidates += [
                "https://\(dns):8920",
                "https://\(dns):443",
                "https://\(dns)",
                "http://\(dns):8096",
                "http://\(dns)",
            ]
        }

        // HTTPS only for bare IPs — HTTP is blocked by ATS without a per-IP exception.
        if let ip = peer.tailscaleIP {
            candidates += [
                "https://\(ip):8920",
                "https://\(ip):443",
                "https://\(ip)",
            ]
        }

        for rawURL in candidates {
            if Task.isCancelled { return nil }
            if let server = try? await validator.validate(rawURL: rawURL) {
                PlozzLog.discovery.info(
                    "Tailscale: '\(peer.displayName)' has Jellyfin at \(rawURL)"
                )
                return server
            }
        }
        PlozzLog.discovery.info("Tailscale: no Jellyfin found for peer '\(peer.displayName)'")
        return nil
    }
}
