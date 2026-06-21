import Foundation
import CoreModels

/// The JSON a Jellyfin server broadcasts in reply to the UDP discovery probe
/// `"Who is JellyfinServer?"` on port 7359.
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
    public static func parse(_ data: Data) -> MediaServer? {
        guard let response = try? JSONDecoder().decode(JellyfinDiscoveryResponse.self, from: data),
              let address = response.Address,
              let url = URL(string: address),
              url.scheme != nil else {
            return nil
        }
        return MediaServer(
            id: response.Id ?? address,
            name: response.Name ?? url.host ?? "Jellyfin Server",
            baseURL: normalize(url),
            provider: .jellyfin
        )
    }

    /// Drops a trailing slash so server identity comparisons are stable.
    static func normalize(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        if components.path.hasSuffix("/") {
            components.path = String(components.path.dropLast())
        }
        return components.url ?? url
    }
}
