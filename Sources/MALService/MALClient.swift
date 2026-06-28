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

    /// `PATCH /v2/anime/{anime_id}/my_list_status` — updates the user's list entry.
    func updateAnimeListStatus(
        animeID: Int,
        status: MALAnimeStatus?,
        numWatchedEpisodes: Int?,
        accessToken: String
    ) async throws {
        var parameters: [String: String] = [:]
        if let status { parameters["status"] = status.rawValue }
        if let numWatchedEpisodes { parameters["num_watched_episodes"] = String(numWatchedEpisodes) }

        let endpoint = Endpoint(
            method: .patch,
            path: "/anime/\(animeID)/my_list_status",
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "Content-Type": "application/x-www-form-urlencoded"
            ]
        )
        _ = try await sendForm(
            endpoint: endpoint,
            parameters: parameters,
            baseURL: apiBaseURL
        )
    }

    // MARK: - Helpers

    private func sendForm(endpoint: Endpoint, parameters: [String: String], baseURL: URL) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(endpoint.path))
        request.httpMethod = endpoint.method.rawValue
        request.httpBody = formBody(parameters)
        for (key, value) in endpoint.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppError.unknown("MAL: non-HTTP response")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            switch httpResponse.statusCode {
            case 400:
                throw AppError.invalidResponse
            case 401, 403:
                throw AppError.unauthorized
            case 404:
                throw AppError.notFound
            default:
                throw AppError.unknown("MAL: HTTP \(httpResponse.statusCode)")
            }
        }
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
