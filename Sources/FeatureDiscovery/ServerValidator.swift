import Foundation
import CoreModels
import CoreNetworking

/// Validates a manually-entered server URL by hitting Jellyfin's public
/// system-info endpoint. Provider-light on purpose: it depends only on
/// `CoreNetworking` so the discovery feature doesn't pull in a provider.
public struct ServerValidator: Sendable {
    private let http: HTTPClient

    public init(http: HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    private struct PublicInfo: Decodable {
        let Id: String?
        let ServerName: String?
        let Version: String?
        let ProductName: String?
    }

    /// Normalises `rawURL`, confirms a Jellyfin server answers, and returns a
    /// fully-identified `MediaServer`.
    ///
    /// Throws `.serverUnreachable` / `.invalidResponse` on failure so the UI can
    /// show a friendly message.
    public func validate(rawURL: String) async throws -> MediaServer {
        guard let baseURL = ServerURLNormalizer.normalize(rawURL) else {
            throw AppError.invalidResponse
        }
        let endpoint = Endpoint(path: "/System/Info/Public")
        let info = try await http.decode(PublicInfo.self, from: endpoint, baseURL: baseURL)
        // Guard against non-Jellyfin endpoints answering with arbitrary JSON.
        guard info.Id != nil || info.ServerName != nil || info.ProductName != nil else {
            throw AppError.invalidResponse
        }
        return MediaServer(
            id: info.Id ?? baseURL.absoluteString,
            name: info.ServerName ?? baseURL.host ?? "Jellyfin Server",
            baseURL: baseURL,
            provider: .jellyfin,
            version: info.Version
        )
    }

    /// Lightweight reachability check for an already-known server: returns
    /// `true` if the server answers its public system-info endpoint right now.
    ///
    /// Used to tell the user whether a saved server is actually online, even
    /// when UDP broadcast discovery turns up nothing (blocked broadcasts,
    /// different subnet, lossy Wi-Fi, etc.).
    public func isReachable(_ baseURL: URL) async -> Bool {
        let endpoint = Endpoint(path: "/System/Info/Public")
        do {
            _ = try await http.send(endpoint, baseURL: baseURL)
            return true
        } catch {
            return false
        }
    }
}
