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

    // MARK: - OAuth (device code)

    /// `POST /v1/oauth2/device/code` — begins the device-code flow.
    /// MAL returns a form-like response; we parse JSON from it.
    func requestDeviceCode() async throws -> MALDeviceCode {
        let body = "client_id=\(config.clientID ?? "")"
        let endpoint = Endpoint(
            method: .post,
            path: "/v1/oauth2/device_authorization",
            headers: ["Content-Type": "application/x-www-form-urlencoded"]
        )
        let data = try await sendForm(endpoint: endpoint, body: body, baseURL: authBaseURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let deviceCode = json["device_code"] as? String,
              let userCode = json["user_code"] as? String,
              let verificationURL = json["verification_uri"] as? String ?? json["verification_url"] as? String
        else {
            throw AppError.unknown("MAL: invalid device code response")
        }
        let expiresIn = (json["expires_in"] as? Double) ?? 600
        let interval = (json["interval"] as? Double) ?? 5
        return MALDeviceCode(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURL: verificationURL,
            expiresIn: expiresIn,
            interval: interval
        )
    }

    /// `POST /v1/oauth2/token` — exchanges device code for tokens.
    func requestToken(deviceCode: String) async throws -> MALTokenResponse {
        let body = [
            "client_id=\(config.clientID ?? "")",
            "grant_type=urn:ietf:params:oauth:grant-type:device_code",
            "device_code=\(deviceCode)"
        ].joined(separator: "&")
        let endpoint = Endpoint(
            method: .post,
            path: "/v1/oauth2/token",
            headers: ["Content-Type": "application/x-www-form-urlencoded"]
        )
        let data = try await sendForm(endpoint: endpoint, body: body, baseURL: authBaseURL)
        return try JSONDecoder().decode(MALTokenResponse.self, from: data)
    }

    /// `POST /v1/oauth2/token` — refreshes an expired access token.
    func refreshToken(_ refreshToken: String) async throws -> MALTokenResponse {
        let body = [
            "client_id=\(config.clientID ?? "")",
            "grant_type=refresh_token",
            "refresh_token=\(refreshToken)"
        ].joined(separator: "&")
        let endpoint = Endpoint(
            method: .post,
            path: "/v1/oauth2/token",
            headers: ["Content-Type": "application/x-www-form-urlencoded"]
        )
        let data = try await sendForm(endpoint: endpoint, body: body, baseURL: authBaseURL)
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
        var parts: [String] = []
        if let status { parts.append("status=\(status.rawValue)") }
        if let numWatchedEpisodes { parts.append("num_watched_episodes=\(numWatchedEpisodes)") }
        let body = parts.joined(separator: "&")

        let endpoint = Endpoint(
            method: .patch,
            path: "/anime/\(animeID)/my_list_status",
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "Content-Type": "application/x-www-form-urlencoded"
            ]
        )
        _ = try await sendForm(endpoint: endpoint, body: body, baseURL: apiBaseURL)
    }

    // MARK: - Helpers

    private func sendForm(endpoint: Endpoint, body: String, baseURL: URL) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(endpoint.path))
        request.httpMethod = endpoint.method.rawValue
        request.httpBody = body.data(using: .utf8)
        for (key, value) in endpoint.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppError.unknown("MAL: non-HTTP response")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 400 {
                // 400 during device-code polling means "authorization_pending"
                throw AppError.serverUnreachable
            }
            throw AppError.unknown("MAL: HTTP \(httpResponse.statusCode)")
        }
        return data
    }
}
