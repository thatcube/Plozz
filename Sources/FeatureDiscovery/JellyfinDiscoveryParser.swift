import Foundation
import CoreModels
import CoreNetworking

/// The JSON a Jellyfin server broadcasts in reply to the UDP discovery probe
/// `"Who is JellyfinServer?"` on port 7359.
///
/// Field shapes vary across Jellyfin versions / deployment styles:
///  * `Address` is usually a full URL (`http://10.0.0.5:8096`,
///    `https://jelly.example.com`, or one with a reverse-proxy base path like
///    `http://10.0.0.5:8096/jellyfin`) — it's the server's "smart" API URL for
///    the requesting client's subnet.
///  * Some builds instead put a bare IP/host in `Address` and the full URL in
///    `EndpointAddress`, or leave `EndpointAddress` null.
/// We therefore try both fields and normalise whatever we get.
struct JellyfinDiscoveryResponse: Decodable {
    let Address: String?
    let Id: String?
    let Name: String?
    let EndpointAddress: String?
}

/// Pure parsing of discovery datagrams → `MediaServer`.
///
/// Kept free of any networking so it can be unit-tested directly against raw
/// bytes captured from a real server.
public enum JellyfinDiscoveryParser {
    /// The probe message Plozz broadcasts. Jellyfin servers listen for this
    /// exact string on UDP port 7359.
    public static let probeMessage = "Who is JellyfinServer?"
    public static let discoveryPort: UInt16 = 7359

    /// Decodes a single UDP response payload into a `MediaServer`, or `nil` if
    /// it isn't a usable Jellyfin announcement.
    ///
    /// Accepts either `Address` or `EndpointAddress`, and tolerates scheme-less
    /// / bare-IP values by routing them through `ServerURLNormalizer` (which
    /// adds `http://` + the default port and strips trailing slashes). This is
    /// what lets stock servers behind reverse proxies, custom base paths, or
    /// older firmware all resolve to a usable base URL.
    public static func parse(_ data: Data) -> MediaServer? {
        guard let response = try? JSONDecoder().decode(JellyfinDiscoveryResponse.self, from: data) else {
            return nil
        }

        // Prefer the first field that yields a usable base URL. `Address` is the
        // server's smart URL for our subnet; `EndpointAddress` is a fallback.
        let candidates = [response.Address, response.EndpointAddress]
        guard let url = candidates
            .compactMap({ $0 })
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            .flatMap(ServerURLNormalizer.normalize)
        else {
            return nil
        }

        return MediaServer(
            id: response.Id ?? url.absoluteString,
            name: response.Name ?? url.host ?? "Jellyfin Server",
            baseURL: url,
            provider: .jellyfin
        )
    }
}
