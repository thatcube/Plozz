import Foundation
import CoreModels
import CoreNetworking

/// A freshly issued Plex.tv PIN the user links at **plex.tv/link**.
///
/// The `code` is shown to the user; the `id` is polled to learn when they've
/// entered it. Both are non-secret (unlike the resulting auth token).
public struct PlexPinChallenge: Hashable, Sendable {
    public var id: Int
    public var code: String

    public init(id: Int, code: String) {
        self.id = id
        self.code = code
    }
}

/// Low-level client for the **plex.tv** account API (`plex.tv/api/v2`).
///
/// Handles the parts of sign-in that happen *before* a server is known: issuing
/// and polling a PIN, reading the account user, and listing the servers the
/// account can reach. Server browsing/playback lives in `PlexClient`.
public struct PlexAuthClient: Sendable {
    /// Base URL of the Plex.tv account API.
    public static let plexTVBaseURL = URL(string: "https://plex.tv")!

    private let deviceProfile: PlexDeviceProfile
    private let http: HTTPClient
    private let baseURL: URL

    public init(
        deviceProfile: PlexDeviceProfile,
        http: HTTPClient = URLSessionHTTPClient(),
        baseURL: URL = PlexAuthClient.plexTVBaseURL
    ) {
        self.deviceProfile = deviceProfile
        self.http = http
        self.baseURL = baseURL
    }

    // MARK: PIN flow

    /// `POST /api/v2/pins?strong=true` — issues a new PIN/code pair.
    public func createPin() async throws -> PlexPinChallenge {
        let endpoint = Endpoint(
            method: .post,
            path: "/api/v2/pins",
            queryItems: [URLQueryItem(name: "strong", value: "true")],
            headers: deviceProfile.headers()
        )
        let dto = try await http.decode(PlexPinDTO.self, from: endpoint, baseURL: baseURL)
        return PlexPinChallenge(id: dto.id, code: dto.code)
    }

    /// `GET /api/v2/pins/{id}` — one poll of a PIN's link state.
    public func pollPin(id: Int) async throws -> PlexPinFlow.Outcome {
        let endpoint = Endpoint(path: "/api/v2/pins/\(id)", headers: deviceProfile.headers())
        let dto = try await http.decode(PlexPinDTO.self, from: endpoint, baseURL: baseURL)
        return PlexPinFlow.evaluate(pin: dto)
    }

    // MARK: Account + servers

    /// `GET /api/v2/user` — the signed-in account identity.
    public func user(authToken: String) async throws -> (id: String, userName: String) {
        let endpoint = Endpoint(path: "/api/v2/user", headers: deviceProfile.headers(token: authToken))
        let dto = try await http.decode(PlexUserDTO.self, from: endpoint, baseURL: baseURL)
        let id = dto.uuid ?? dto.id.map(String.init) ?? "plex-user"
        let name = dto.title ?? dto.username ?? "Plex"
        return (id, name)
    }

    /// `GET /api/v2/resources?includeHttps=1` — the servers this account can
    /// reach, each resolved to its best connection's base URL + server token.
    public func servers(authToken: String) async throws -> [PlexServerCandidate] {
        let endpoint = Endpoint(
            path: "/api/v2/resources",
            queryItems: [
                URLQueryItem(name: "includeHttps", value: "1"),
                URLQueryItem(name: "includeRelay", value: "1")
            ],
            headers: deviceProfile.headers(token: authToken)
        )
        let resources = try await http.decode([PlexResourceDTO].self, from: endpoint, baseURL: baseURL)
        return resources.compactMap { resource in
            guard resource.provides?.contains("server") == true,
                  let id = resource.clientIdentifier,
                  let baseURL = PlexConnectionSelector.best(from: resource.connections ?? []) else {
                return nil
            }
            return PlexServerCandidate(
                id: id,
                name: resource.name ?? baseURL.host ?? "Plex Server",
                baseURL: baseURL,
                accessToken: resource.accessToken ?? authToken,
                isOwned: resource.owned ?? false
            )
        }
    }
}
