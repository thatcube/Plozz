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

    /// Auth headers. `actingUserID` (or the legacy `config.userId`) is sent as
    /// `X-API-User` so the call runs *as that Seerr user*; pass `nil` for the
    /// admin identity (browse/status/user-list calls).
    private func headers(actingUserID: Int? = nil) -> [String: String] {
        var headers = [
            "Content-Type": "application/json",
            "X-Api-Key": config.apiKey ?? ""
        ]
        if let userId = actingUserID ?? config.userId {
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

    /// `GET /api/v1/{movie|tv}/{tmdbId}` — title details, decoded down to just its
    /// `mediaInfo` (request status + live download queue) so the app can refresh a
    /// discovery title's request/availability state on (re)open. `mediaType` is
    /// Seerr's `"movie"`/`"tv"` (see ``SeerMapper/requestMediaType(for:)``).
    func mediaDetails(mediaType: String, tmdbID: Int) async throws -> SeerMediaDetails {
        let endpoint = Endpoint(method: .get, path: "/api/v1/\(mediaType)/\(tmdbID)", headers: headers())
        return try await http.decode(SeerMediaDetails.self, from: endpoint, baseURL: baseURL)
    }

    /// `GET /api/v1/user` — one page of Seerr users. `take`/`skip` page the list;
    /// Overseerr caps `take` at 100.
    func users(take: Int = 100, skip: Int = 0) async throws -> SeerUserPage {
        let endpoint = Endpoint(
            method: .get,
            path: "/api/v1/user",
            queryItems: [
                URLQueryItem(name: "take", value: String(take)),
                URLQueryItem(name: "skip", value: String(skip))
            ],
            headers: headers()
        )
        return try await http.decode(SeerUserPage.self, from: endpoint, baseURL: baseURL)
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

    /// The low-level result of `POST /api/v1/request`: either created (2xx, with
    /// the decoded response when present) or a server-rejected status + message.
    /// Transport failures throw instead (the caller maps those to `.unreachable`).
    enum CreateRequestResult {
        case created(SeerRequestResponse?, status: Int, rawBody: String?)
        case failed(status: Int, message: String?)
    }

    /// `POST /api/v1/request` — create a request **as** `actingUserID` (its own
    /// quota / approval / default profile). Uses `sendRaw` so a non-2xx status is
    /// inspected rather than thrown, capturing Overseerr's `{ message }` body so
    /// the caller can produce a specific ``SeerRequestFailure``.
    func createRequest(_ body: SeerRequestBody, actingUserID: Int?) async throws -> CreateRequestResult {
        let endpoint = try Endpoint(method: .post, path: "/api/v1/request", headers: headers(actingUserID: actingUserID))
            .jsonBody(body)
        let (data, response) = try await http.sendRaw(endpoint, baseURL: baseURL)
        if (200...299).contains(response.statusCode) {
            let decoded = try? JSONDecoder.plozz.decode(
                SeerRequestResponse.self, from: data
            )
            let rawBody = String(data: data, encoding: .utf8)
            return .created(decoded, status: response.statusCode, rawBody: rawBody)
        }
        let message = (try? JSONDecoder.plozz.decode(SeerErrorBody.self, from: data))?.message
        return .failed(status: response.statusCode, message: message)
    }

    /// `POST /api/v1/request/{id}/retry` — re-dispatch a **failed** request to
    /// Radarr/Sonarr without creating a duplicate. Returns the same
    /// ``CreateRequestResult`` shape as ``createRequest(_:actingUserID:)``.
    func retryRequest(id: Int, actingUserID: Int?) async throws -> CreateRequestResult {
        let endpoint = Endpoint(
            method: .post,
            path: "/api/v1/request/\(id)/retry",
            headers: headers(actingUserID: actingUserID)
        )
        let (data, response) = try await http.sendRaw(endpoint, baseURL: baseURL)
        if (200...299).contains(response.statusCode) {
            let decoded = try? JSONDecoder.plozz.decode(SeerRequestResponse.self, from: data)
            return .created(decoded, status: response.statusCode, rawBody: String(data: data, encoding: .utf8))
        }
        let message = (try? JSONDecoder.plozz.decode(SeerErrorBody.self, from: data))?.message
        return .failed(status: response.statusCode, message: message)
    }

    /// `DELETE /api/v1/request/{id}` — remove a request (used to clear a stale
    /// failed/declined request before recreating a fresh one). Returns whether the
    /// server accepted the delete (2xx); transport failures throw.
    @discardableResult
    func deleteRequest(id: Int) async throws -> Bool {
        let endpoint = Endpoint(method: .delete, path: "/api/v1/request/\(id)", headers: headers())
        let (_, response) = try await http.sendRaw(endpoint, baseURL: baseURL)
        return (200...299).contains(response.statusCode)
    }
}
