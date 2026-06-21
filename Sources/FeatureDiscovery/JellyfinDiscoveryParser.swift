import Foundation
import CoreModels
import CoreNetworking

/// The JSON a Jellyfin server broadcasts in reply to the UDP discovery probe
/// `"Who is JellyfinServer?"` on port 7359.
struct JellyfinDiscoveryResponse: Decodable {
    let Address: String?
    let Id: String?
    let Name: String?
    let EndpointAddress: String?
}

/// A parsed Jellyfin discovery announcement plus the base URLs we should try,
/// in priority order (most-likely-reachable first).
///
/// Why a *list*: a Jellyfin server's self-reported `Address` is frequently
/// wrong for the client's network — multi-NIC hosts and a misconfigured
/// "Published server URL" routinely advertise an address on a different subnet
/// (observed in the wild: a reply arriving from `192.168.68.71` that reports
/// `"Address":"192.168.0.5"`). The datagram's *source IP* is, by definition,
/// reachable, so it is preferred over anything the payload claims.
public struct JellyfinAnnouncement: Equatable, Sendable {
    public let id: String
    public let name: String
    /// Candidate base URLs, reachable-first. `candidateURLs[0]` is the best bet.
    public let candidateURLs: [URL]

    public init(id: String, name: String, candidateURLs: [URL]) {
        self.id = id
        self.name = name
        self.candidateURLs = candidateURLs
    }

    /// The server to surface, built from the most-reachable candidate. The
    /// announcement already carries the server's identity and display name, so
    /// no extra HTTP round-trip is required to list it.
    public var primaryServer: MediaServer? {
        guard let baseURL = candidateURLs.first else { return nil }
        return MediaServer(id: id, name: name, baseURL: baseURL, provider: .jellyfin)
    }
}

/// Pure parsing of discovery datagrams → `JellyfinAnnouncement`.
///
/// Kept free of any networking so it can be unit-tested directly against raw
/// bytes captured from a real server.
public enum JellyfinDiscoveryParser {
    /// The probe message Plozz sends. Jellyfin servers listen for this exact
    /// string on UDP port 7359 and reply to the sender.
    public static let probeMessage = "Who is JellyfinServer?"
    public static let discoveryPort: UInt16 = 7359

    /// Decodes a single UDP response payload into an announcement, or `nil` if
    /// it isn't a usable Jellyfin reply.
    ///
    /// - Parameters:
    ///   - data: the raw datagram bytes.
    ///   - sourceIP: the address the datagram actually arrived from. Preferred
    ///     over the payload's `Address`/`EndpointAddress` because it is known to
    ///     be reachable on this LAN.
    public static func parse(_ data: Data, sourceIP: String? = nil) -> JellyfinAnnouncement? {
        guard let response = try? JSONDecoder().decode(JellyfinDiscoveryResponse.self, from: data),
              response.Id != nil || response.Name != nil || response.Address != nil else {
            return nil
        }

        var candidates: [URL] = []
        func add(_ url: URL?) {
            guard let url, !candidates.contains(url) else { return }
            candidates.append(url)
        }
        func add(_ raw: String?) {
            guard let raw, !raw.isEmpty else { return }
            add(ServerURLNormalizer.normalize(raw))
        }

        // The server's own advertised endpoint, normalized. It may be on a
        // foreign subnet/host, but it carries the scheme, port and path the
        // server actually serves on (https, a reverse-proxy path, a non-default
        // port, …) — information the bare source IP lacks.
        let advertised = ServerURLNormalizer.normalize(response.EndpointAddress ?? "")
            ?? ServerURLNormalizer.normalize(response.Address ?? "")

        if let sourceIP, !sourceIP.isEmpty {
            // 1. Best bet: the reachable host, but using the scheme/port/path the
            //    server advertised. Covers https, reverse proxies and custom
            //    ports while still aiming at an address we know we can reach.
            if let advertised { add(hostSwapped(advertised, host: sourceIP)) }
            // 2. The reachable host on Jellyfin's default http port.
            add(sourceIP)
        }
        // 3/4. The server's own addresses, exactly as advertised (last resort —
        //      only works when the published address is correct for this LAN).
        add(response.EndpointAddress)
        add(response.Address)

        guard let primary = candidates.first else { return nil }

        let id = response.Id ?? primary.absoluteString
        let name = response.Name ?? sourceIP ?? primary.host ?? "Jellyfin Server"
        return JellyfinAnnouncement(id: id, name: name, candidateURLs: candidates)
    }

    /// Returns `template` with its host replaced by `host`, preserving scheme,
    /// port and path. Used to aim the server's advertised endpoint at an address
    /// we know is reachable.
    private static func hostSwapped(_ template: URL, host: String) -> URL? {
        guard var components = URLComponents(url: template, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.host = host
        return components.url
    }
}
