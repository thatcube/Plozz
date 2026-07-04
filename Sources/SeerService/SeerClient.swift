import Foundation
import CoreModels
import CoreNetworking

/// Low-level Seerr (Overseerr / Jellyseerr) API calls, built on the shared
/// `HTTPClient`.
///
/// Centralises Seerr's auth headers — `X-Api-Key` (admin key) and the optional
/// `X-API-User` (act-as-user) — and the discovery/request endpoints. All paths
/// are under `/api/v1`. Stateless and `Sendable`; the facade builds a fresh one
/// per call from the current ``SeerConfig``.
struct SeerClient: Sendable {
    let config: SeerConfig
    let http: HTTPClient

    init(config: SeerConfig, http: HTTPClient) {
        self.config = config
        self.http = http
    }

    private var baseURL: URL {
        // The facade only builds a client once `isConfigured`, so this is safe;
        // fall back to a sentinel that will simply fail the request otherwise.
        config.baseURL ?? URL(string: "https://invalid.invalid")!
    }

    private func headers() -> [String: String] {
        var headers = [
            "Content-Type": "application/json",
            "X-Api-Key": config.apiKey ?? ""
        ]
        if let userId = config.userId {
            headers["X-API-User"] = String(userId)
        }
        return headers
    }

    // MARK: - Health

    /// `GET /api/v1/status` — connectivity + version probe (no admin scope needed).
    func status() async throws -> SeerStatus {
        let endpoint = Endpoint(method: .get, path: "/api/v1/status", headers: headers())
        return try await http.decode(SeerStatus.self, from: endpoint, baseURL: baseURL)
    }

    // MARK: - Discovery

    /// `GET /api/v1/discover/trending` — mixed trending movies/TV/people.
    func trending(page: Int = 1, language: String = "en") async throws -> SeerDiscoverPage {
        try await discover(path: "/api/v1/discover/trending", page: page, language: language)
    }

    /// `GET /api/v1/discover/movies` — popular/discoverable movies.
    func discoverMovies(page: Int = 1, language: String = "en") async throws -> SeerDiscoverPage {
        try await discover(path: "/api/v1/discover/movies", page: page, language: language)
    }

    /// `GET /api/v1/discover/tv` — popular/discoverable TV.
    func discoverTv(page: Int = 1, language: String = "en") async throws -> SeerDiscoverPage {
        try await discover(path: "/api/v1/discover/tv", page: page, language: language)
    }

    private func discover(path: String, page: Int, language: String) async throws -> SeerDiscoverPage {
        let endpoint = Endpoint(
            method: .get,
            path: path,
            queryItems: [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "language", value: language)
            ],
            headers: headers()
        )
        return try await http.decode(SeerDiscoverPage.self, from: endpoint, baseURL: baseURL)
    }

    /// `GET /api/v1/search?query=` — multi-search across movies/TV/people.
    func search(query: String, page: Int = 1, language: String = "en") async throws -> SeerDiscoverPage {
        let endpoint = Endpoint(
            method: .get,
            path: "/api/v1/search",
            queryItems: [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "language", value: language)
            ],
            headers: headers()
        )
        return try await http.decode(SeerDiscoverPage.self, from: endpoint, baseURL: baseURL)
    }

    // MARK: - Radarr / Sonarr defaults

    /// `GET /api/v1/service/radarr` — configured Radarr servers (for defaults).
    func radarrServers() async throws -> [SeerServiceServer] {
        let endpoint = Endpoint(method: .get, path: "/api/v1/service/radarr", headers: headers())
        return try await http.decode([SeerServiceServer].self, from: endpoint, baseURL: baseURL)
    }

    /// `GET /api/v1/service/sonarr` — configured Sonarr servers (for defaults).
    func sonarrServers() async throws -> [SeerServiceServer] {
        let endpoint = Endpoint(method: .get, path: "/api/v1/service/sonarr", headers: headers())
        return try await http.decode([SeerServiceServer].self, from: endpoint, baseURL: baseURL)
    }

    // MARK: - Requests

    /// `POST /api/v1/request` — create a request. Decodes the result when the
    /// server returns one (201); a 202 "nothing to request" body may not decode,
    /// so decoding failures are swallowed to `nil` (the send itself succeeded).
    func createRequest(_ body: SeerRequestBody) async throws -> SeerRequestResponse? {
        let endpoint = try Endpoint(method: .post, path: "/api/v1/request", headers: headers())
            .jsonBody(body)
        let (data, _) = try await http.send(endpoint, baseURL: baseURL)
        return try? JSONDecoder.plozz.decode(SeerRequestResponse.self, from: data)
    }
}
