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
    private let probeHTTP: HTTPClient
    private let baseURL: URL

    public init(
        deviceProfile: PlexDeviceProfile,
        http: HTTPClient = URLSessionHTTPClient(),
        probeHTTP: HTTPClient = URLSessionHTTPClient(session: .plozzDiscovery),
        baseURL: URL = PlexAuthClient.plexTVBaseURL
    ) {
        self.deviceProfile = deviceProfile
        self.http = http
        self.probeHTTP = probeHTTP
        self.baseURL = baseURL
    }

    // MARK: PIN flow

    /// `POST /api/v2/pins` — issues a new PIN/code pair.
    ///
    /// We intentionally do NOT request `strong=true`. A strong PIN returns a
    /// long, random code meant for app-to-app / deep-link auth — not something
    /// a person can read off a TV screen and type. The default (non-strong)
    /// PIN returns the short 4-character code that the plex.tv/link manual-entry
    /// flow expects.
    public func createPin() async throws -> PlexPinChallenge {
        let endpoint = Endpoint(
            method: .post,
            path: "/api/v2/pins",
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
    public func user(authToken: String) async throws -> (id: String, userName: String, avatarURL: URL?) {
        let endpoint = Endpoint(path: "/api/v2/user", headers: deviceProfile.headers(token: authToken))
        let dto = try await http.decode(PlexUserDTO.self, from: endpoint, baseURL: baseURL)
        let id = dto.uuid ?? dto.id.map(String.init) ?? "plex-user"
        let name = dto.title ?? dto.username ?? "Plex"
        let avatarURL = dto.thumb.flatMap { thumb in
            URL(string: thumb, relativeTo: baseURL)?.absoluteURL
        }
        return (id, name, avatarURL)
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
        let servers = resources.filter { $0.provides?.contains("server") == true }

        return await withTaskGroup(of: PlexServerCandidate?.self) { group in
            for resource in servers {
                group.addTask {
                    await self.resolveServer(resource, authToken: authToken)
                }
            }
            var candidates: [PlexServerCandidate] = []
            for await candidate in group {
                if let candidate { candidates.append(candidate) }
            }
            return candidates
        }
    }

    /// The reachable-ordered connection URLs for one specific server the account
    /// can reach, identified by its stable `clientIdentifier`. Used to refresh a
    /// saved server's connection list when its previously-good URL has gone
    /// unreachable (e.g. the server changed networks). Returns `[]` if the server
    /// is no longer listed for the account.
    public func connectionURLs(forServerID serverID: String, authToken: String) async throws -> [URL] {
        try await servers(authToken: authToken)
            .first { $0.id == serverID }?
            .connectionURLs ?? []
    }

    /// Resolves a single server resource to its best *reachable* connection.
    ///
    /// Plex lists every address the server is bound to — including ones a TV on a
    /// different network can't reach (e.g. a Docker bridge gateway advertised as
    /// "local"). We probe the ranked connections and keep the first that answers,
    /// falling back to the top-ranked URL if none respond so the server still
    /// appears (the UI can then surface "unreachable" instead of silently
    /// dropping it).
    private func resolveServer(_ resource: PlexResourceDTO, authToken: String) async -> PlexServerCandidate? {
        guard let id = resource.clientIdentifier else { return nil }
        let ranked = PlexConnectionSelector.ranked(from: resource.connections ?? [])
        guard !ranked.isEmpty else { return nil }
        let token = resource.accessToken ?? authToken
        let reachable = await firstReachable(among: ranked, token: token)
        // Order the persisted candidate list so the connection that answered the
        // probe is first (becomes `baseURL`), with the rest kept as fallbacks the
        // client can self-heal onto later.
        let ordered: [URL]
        if let reachable {
            ordered = [reachable] + ranked.filter { $0 != reachable }
        } else {
            ordered = ranked
        }
        return PlexServerCandidate(
            id: id,
            name: resource.name ?? ordered.first?.host ?? "Plex Server",
            connectionURLs: ordered,
            accessToken: token,
            isOwned: resource.owned ?? false
        )
    }

    /// Returns the most-preferred connection that answers a lightweight
    /// `/identity` probe, or `nil` if none respond within the probe window.
    private func firstReachable(among urls: [URL], token: String) async -> URL? {
        await withTaskGroup(of: (Int, Bool).self) { group in
            for (index, url) in urls.enumerated() {
                group.addTask {
                    let endpoint = Endpoint(path: "/identity", headers: self.deviceProfile.headers(token: token))
                    do {
                        _ = try await self.probeHTTP.send(endpoint, baseURL: url)
                        return (index, true)
                    } catch {
                        return (index, false)
                    }
                }
            }
            var bestReachable: Int?
            for await (index, reachable) in group where reachable {
                bestReachable = min(bestReachable ?? index, index)
            }
            return bestReachable.map { urls[$0] }
        }
    }

    // MARK: Home users ("Who's watching?")

    /// `GET /api/v2/home/users` — the Plex Home users reachable from this
    /// account's (admin) token. Use the returned `id` (uuid) with
    /// `switchHomeUser` to assume that user's identity.
    public func homeUsers(authToken: String) async throws -> [PlexHomeUser] {
        let endpoint = Endpoint(
            path: "/api/v2/home/users",
            headers: deviceProfile.headers(token: authToken)
        )
        let dto = try await http.decode(PlexHomeUsersDTO.self, from: endpoint, baseURL: baseURL)
        return dto.users.compactMap { user in
            guard let id = user.uuid ?? user.id.map(String.init) else { return nil }
            return PlexHomeUser(
                id: id,
                name: user.title ?? user.username ?? "Plex User",
                requiresPIN: user.protected ?? user.hasPassword ?? false,
                isAdmin: user.admin ?? false,
                isRestricted: user.restricted ?? false
            )
        }
    }

    /// `POST /api/v2/home/users/{uuid}/switch` — assume a Home user, returning
    /// **that user's** auth token (derived from the admin token).
    ///
    /// `pin` must be supplied for protected users and omitted otherwise. A
    /// missing/incorrect PIN surfaces as `AppError.unauthorized`. Plozz never
    /// stores the PIN — it is passed straight through on each switch.
    public func switchHomeUser(uuid: String, pin: String?, authToken: String) async throws -> String {
        var queryItems: [URLQueryItem] = []
        if let pin, !pin.isEmpty {
            queryItems.append(URLQueryItem(name: "pin", value: pin))
        }
        let endpoint = Endpoint(
            method: .post,
            path: "/api/v2/home/users/\(uuid)/switch",
            queryItems: queryItems,
            headers: deviceProfile.headers(token: authToken)
        )
        let dto = try await http.decode(PlexHomeSwitchDTO.self, from: endpoint, baseURL: baseURL)
        guard let token = dto.authToken ?? dto.authenticationToken, !token.isEmpty else {
            throw AppError.unauthorized
        }
        return token
    }
}
