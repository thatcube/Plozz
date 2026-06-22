import Foundation
import CoreModels
import CoreNetworking

/// Low-level Trakt API calls, built on the shared `HTTPClient`.
///
/// Centralises Trakt's required headers (`trakt-api-version`, `trakt-api-key`,
/// and the bearer `Authorization`) and the OAuth + scrobble endpoints. All
/// request bodies are JSON; tokens are never logged (the `HTTPClient` redacts
/// `Authorization`).
struct TraktClient: Sendable {
    let config: TraktConfig
    let http: HTTPClient

    init(config: TraktConfig, http: HTTPClient) {
        self.config = config
        self.http = http
    }

    private var baseURL: URL { config.apiBaseURL }

    /// Headers required on every Trakt request. The bearer token is optional —
    /// OAuth endpoints are unauthenticated.
    private func headers(accessToken: String? = nil) -> [String: String] {
        var headers = [
            "Content-Type": "application/json",
            "trakt-api-version": "2",
            "trakt-api-key": config.clientID ?? ""
        ]
        if let accessToken {
            headers["Authorization"] = "Bearer \(accessToken)"
        }
        return headers
    }

    // MARK: - OAuth (device code)

    /// `POST /oauth/device/code` — begins the device-code flow.
    func requestDeviceCode() async throws -> TraktDeviceCode {
        let endpoint = try Endpoint(method: .post, path: "/oauth/device/code", headers: headers())
            .jsonBody(["client_id": config.clientID ?? ""])
        return try await http.decode(TraktDeviceCode.self, from: endpoint, baseURL: baseURL)
    }

    /// `POST /oauth/device/token` — exchanges a device code for tokens once the
    /// user approves. Throws (HTTP 4xx) while still pending; the caller polls.
    func requestToken(deviceCode: String) async throws -> TraktTokenResponse {
        let body = [
            "code": deviceCode,
            "client_id": config.clientID ?? "",
            "client_secret": config.clientSecret ?? ""
        ]
        let endpoint = try Endpoint(method: .post, path: "/oauth/device/token", headers: headers())
            .jsonBody(body)
        return try await http.decode(TraktTokenResponse.self, from: endpoint, baseURL: baseURL)
    }

    /// `POST /oauth/token` — refreshes an expired access token.
    func refreshToken(_ refreshToken: String) async throws -> TraktTokenResponse {
        let body = [
            "refresh_token": refreshToken,
            "client_id": config.clientID ?? "",
            "client_secret": config.clientSecret ?? "",
            "redirect_uri": "urn:ietf:wg:oauth:2.0:oob",
            "grant_type": "refresh_token"
        ]
        let endpoint = try Endpoint(method: .post, path: "/oauth/token", headers: headers())
            .jsonBody(body)
        return try await http.decode(TraktTokenResponse.self, from: endpoint, baseURL: baseURL)
    }

    /// `POST /oauth/revoke` — invalidates the token server-side on disconnect.
    func revoke(accessToken: String) async throws {
        let body = [
            "token": accessToken,
            "client_id": config.clientID ?? "",
            "client_secret": config.clientSecret ?? ""
        ]
        let endpoint = try Endpoint(method: .post, path: "/oauth/revoke", headers: headers())
            .jsonBody(body)
        _ = try await http.send(endpoint, baseURL: baseURL)
    }

    // MARK: - User

    /// `GET /users/settings` — the connected user's profile (for display).
    func userSettings(accessToken: String) async throws -> TraktUserSettings {
        let endpoint = Endpoint(method: .get, path: "/users/settings", headers: headers(accessToken: accessToken))
        return try await http.decode(TraktUserSettings.self, from: endpoint, baseURL: baseURL)
    }

    // MARK: - Scrobble

    /// `POST /scrobble/{action}` — records playback state. A `stop` past Trakt's
    /// watched threshold (80%) adds the item to the user's history.
    func scrobble(action: String, body: TraktScrobbleBody, accessToken: String) async throws {
        let endpoint = try Endpoint(method: .post, path: "/scrobble/\(action)", headers: headers(accessToken: accessToken))
            .jsonBody(body)
        _ = try await http.send(endpoint, baseURL: baseURL)
    }
}
