import Foundation
import CoreModels
import CoreNetworking

/// Low-level MyAnimeList API calls.
///
/// MAL uses form-encoded bodies for OAuth and the list update endpoints, not JSON.
struct MALClient: Sendable {
    let config: MALConfig
    let http: HTTPClient

    init(config: MALConfig, http: HTTPClient) {
        self.config = config
        self.http = http
    }

    private var authBaseURL: URL { config.authBaseURL }
    private var apiBaseURL: URL { config.apiBaseURL }

    // MARK: - OAuth (authorization code + PKCE)

    func beginAuthorization(codeVerifier: String) throws -> MALAuthorizationRequest {
        guard let clientID = config.clientID else {
            throw AppError.unknown("MAL: missing client id")
        }

        guard var components = URLComponents(
            url: authBaseURL.appendingPathComponent("/v1/oauth2/authorize"),
            resolvingAgainstBaseURL: false
        ) else {
            throw AppError.unknown("MAL: invalid authorization URL")
        }

        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "code_challenge", value: codeVerifier),
            URLQueryItem(name: "code_challenge_method", value: "plain")
        ]

        guard let authorizationURL = components.url?.absoluteString else {
            throw AppError.unknown("MAL: invalid authorization URL")
        }

        return MALAuthorizationRequest(
            authorizationURL: authorizationURL,
            codeVerifier: codeVerifier,
            redirectURI: config.redirectURI
        )
    }

    /// `POST /v1/oauth2/token` — exchanges the short authorization code for tokens.
    func requestToken(authorizationCode: String, codeVerifier: String) async throws -> MALTokenResponse {
        guard let clientID = config.clientID else {
            throw AppError.unknown("MAL: missing client id")
        }

        let endpoint = Endpoint(
            method: .post,
            path: "/v1/oauth2/token",
            headers: ["Content-Type": "application/x-www-form-urlencoded"]
        )
        let data = try await sendForm(
            endpoint: endpoint,
            parameters: [
                "client_id": clientID,
                "grant_type": "authorization_code",
                "code": authorizationCode,
                "code_verifier": codeVerifier,
                "redirect_uri": config.redirectURI
            ],
            baseURL: authBaseURL
        )
        return try JSONDecoder().decode(MALTokenResponse.self, from: data)
    }

    /// `POST /v1/oauth2/token` — refreshes an expired access token.
    func refreshToken(_ refreshToken: String) async throws -> MALTokenResponse {
        guard let clientID = config.clientID else {
            throw AppError.unknown("MAL: missing client id")
        }

        let endpoint = Endpoint(
            method: .post,
            path: "/v1/oauth2/token",
            headers: ["Content-Type": "application/x-www-form-urlencoded"]
        )
        let data = try await sendForm(
            endpoint: endpoint,
            parameters: [
                "client_id": clientID,
                "grant_type": "refresh_token",
                "refresh_token": refreshToken
            ],
            baseURL: authBaseURL
        )
        return try JSONDecoder().decode(MALTokenResponse.self, from: data)
    }

    // MARK: - User

    /// `GET /v2/users/@me` — the connected user's profile.
    func userInfo(accessToken: String) async throws -> MALUserInfo {
        let endpoint = Endpoint(
            method: .get,
            path: "/users/@me",
            headers: ["Authorization": "Bearer \(accessToken)"]
        )
        return try await http.decode(MALUserInfo.self, from: endpoint, baseURL: apiBaseURL)
    }

    // MARK: - Anime list

    /// `GET /v2/anime?q=…` — searches MAL's catalog, returning the top match's id.
    /// Fallback for anime whose AniDB id isn't in the ARM map (e.g. brand-new
    /// seasons), so a MAL-only user still gets list updates.
    func searchAnimeID(title: String, accessToken: String) async throws -> Int? {  // l10n:content — media title used as a MyAnimeList search query parameter
        let endpoint = Endpoint(
            method: .get,
            path: "/anime",
            queryItems: [
                URLQueryItem(name: "q", value: title),
                URLQueryItem(name: "limit", value: "1"),
                URLQueryItem(name: "fields", value: "id")
            ],
            headers: ["Authorization": "Bearer \(accessToken)"]
        )
        let result = try await http.decode(MALAnimeSearchResponse.self, from: endpoint, baseURL: apiBaseURL)
        return result.data.first?.node.id
    }

    /// `PATCH /v2/anime/{anime_id}/my_list_status` — updates the user's list entry.
    /// `GET /v2/users/@me/animelist?status=plan_to_watch` — the plan-to-watch list.
    func planToWatch(accessToken: String) async throws -> MALAnimeListResponse {
        let limit = 1_000
        let maximumPages = 1_000
        var offset = 0
        var entries: [MALAnimeListEntry] = []
        var seenIDs: Set<Int> = []
        for _ in 0..<maximumPages {
            let endpoint = Endpoint(
                method: .get,
                path: "/users/@me/animelist",
                queryItems: [
                    URLQueryItem(name: "status", value: "plan_to_watch"),
                    URLQueryItem(name: "sort", value: "list_updated_at"),
                    URLQueryItem(name: "limit", value: String(limit)),
                    URLQueryItem(name: "offset", value: String(offset)),
                    URLQueryItem(name: "fields", value: "id,title,start_season"),
                ],
                headers: ["Authorization": "Bearer \(accessToken)"]
            )
            let page = try await http.decode(
                MALAnimeListResponse.self,
                from: endpoint,
                baseURL: apiBaseURL
            )
            guard let pageEntries = page.data else {
                throw WatchlistDestinationError.transient
            }
            guard pageEntries.count <= limit else {
                throw WatchlistDestinationError.transient
            }
            for entry in pageEntries {
                if let id = entry.node?.id,
                   !seenIDs.insert(id).inserted {
                    throw WatchlistDestinationError.transient
                }
            }
            entries.append(contentsOf: pageEntries)
            guard let next = page.paging?.next else {
                return MALAnimeListResponse(data: entries, paging: nil)
            }
            guard !pageEntries.isEmpty else {
                throw WatchlistDestinationError.transient
            }
            let nextOffset = URLComponents(string: next)?.queryItems?
                .first { $0.name == "offset" }?.value.flatMap(Int.init)
            // MAL exposes no total count; a contiguous next offset plus the
            // eventual absence of `paging.next` are its only completion proof.
            guard let nextOffset,
                  nextOffset == offset + pageEntries.count else {
                throw WatchlistDestinationError.transient
            }
            offset = nextOffset
        }
        throw WatchlistDestinationError.transient
    }

    /// `DELETE /v2/anime/{anime_id}/my_list_status` — removes the list entry.
    ///
    /// MAL answers 404 when the entry was not there, which for a removal means
    /// the desired state already holds; the caller treats that as success.
    func deleteAnimeListStatus(animeID: Int, accessToken: String) async throws {
        let endpoint = Endpoint(
            method: .delete,
            path: "/anime/\(animeID)/my_list_status",
            headers: ["Authorization": "Bearer \(accessToken)"]
        )
        _ = try await http.send(endpoint, baseURL: apiBaseURL)
    }

    func updateAnimeListStatus(
        animeID: Int,
        status: MALAnimeStatus?,
        numWatchedEpisodes: Int?,
        accessToken: String
    ) async throws {
        var parameters: [String: String] = [:]
        if let status { parameters["status"] = status.rawValue }
        if let numWatchedEpisodes { parameters["num_watched_episodes"] = String(numWatchedEpisodes) }

        // Through the injected client, like every other call here.
        //
        // This used to build its own `URLRequest` against `URLSession.shared`,
        // which meant it bypassed the app's networking stack entirely — no shared
        // configuration, and untestable, since a test double could never observe
        // it. The form encoding is the only thing that differs from a JSON call,
        // and that belongs in the body rather than in a second transport.
        var endpoint = Endpoint(
            method: .patch,
            path: "/anime/\(animeID)/my_list_status",
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "Content-Type": "application/x-www-form-urlencoded"
            ]
        )
        endpoint.body = formBody(parameters)
        _ = try await http.send(endpoint, baseURL: apiBaseURL)
    }

    // MARK: - Helpers

    private func sendForm(endpoint: Endpoint, parameters: [String: String], baseURL: URL) async throws -> Data {
        var endpoint = endpoint
        endpoint.body = formBody(parameters)
        let (data, _) = try await http.send(endpoint, baseURL: baseURL)
        return data
    }

    private func formBody(_ parameters: [String: String]) -> Data? {
        var components = URLComponents()
        components.queryItems = parameters
            .sorted(by: { $0.key < $1.key })
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.percentEncodedQuery?.data(using: .utf8)
    }
}
