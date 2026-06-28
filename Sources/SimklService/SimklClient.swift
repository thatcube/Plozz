import Foundation
import CoreModels
import CoreNetworking

/// Low-level Simkl API calls.
struct SimklClient: Sendable {
    let config: SimklConfig
    let http: HTTPClient

    init(config: SimklConfig, http: HTTPClient) {
        self.config = config
        self.http = http
    }

    private var baseURL: URL { config.apiBaseURL }

    private func headers(accessToken: String? = nil) -> [String: String] {
        var headers = [
            "Content-Type": "application/json",
            "simkl-api-key": config.clientID ?? ""
        ]
        if let accessToken {
            headers["Authorization"] = "Bearer \(accessToken)"
        }
        return headers
    }

    // MARK: - OAuth (PIN flow)

    /// `GET /oauth/pin?client_id=...` — request a device PIN code.
    func requestDeviceCode() async throws -> SimklDeviceCode {
        let endpoint = Endpoint(
            method: .get,
            path: "/oauth/pin",
            queryItems: [URLQueryItem(name: "client_id", value: config.clientID ?? "")],
            headers: headers()
        )
        return try await http.decode(SimklDeviceCode.self, from: endpoint, baseURL: baseURL)
    }

    /// `GET /oauth/pin/{USER_CODE}?client_id=...` — poll for approval.
    /// Returns `nil` if still pending, or the access token string on success.
    func pollForToken(userCode: String) async throws -> String? {
        let endpoint = Endpoint(
            method: .get,
            path: "/oauth/pin/\(userCode)",
            queryItems: [URLQueryItem(name: "client_id", value: config.clientID ?? "")],
            headers: headers()
        )
        let (data, _) = try await http.send(endpoint, baseURL: baseURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        // Success: {"result":"OK","access_token":"..."}
        if let token = json["access_token"] as? String {
            return token
        }
        // If the response contains "device_code", the original code expired/was consumed
        if json["device_code"] != nil {
            throw SimklPINExpiredError()
        }
        // Still pending: {"result":"KO","message":"Authorization pending"}
        return nil
    }

    // MARK: - User

    func userSettings(accessToken: String) async throws -> SimklUserSettings {
        let endpoint = Endpoint(method: .get, path: "/users/settings", headers: headers(accessToken: accessToken))
        return try await http.decode(SimklUserSettings.self, from: endpoint, baseURL: baseURL)
    }

    // MARK: - History (scrobble)

    /// `POST /sync/history` — adds items to the user's watch history.
    /// Simkl deduplicates server-side; posting the same episode twice is harmless.
    func addToHistory(body: SimklHistoryBody, accessToken: String) async throws {
        let endpoint = try Endpoint(method: .post, path: "/sync/history", headers: headers(accessToken: accessToken))
            .jsonBody(body)
        _ = try await http.send(endpoint, baseURL: baseURL)
    }

    // MARK: - Real-time scrobble

    /// `POST /scrobble/{action}` — reports real-time playback (start/pause/stop).
    /// Shows "Now Watching" on the user's Simkl dashboard and auto-marks watched
    /// on stop with progress >= 80%.
    func scrobble(action: String, body: SimklScrobbleBody, accessToken: String) async throws {
        let endpoint = try Endpoint(method: .post, path: "/scrobble/\(action)", headers: headers(accessToken: accessToken))
            .jsonBody(body)
        _ = try await http.send(endpoint, baseURL: baseURL)
    }
}

/// Thrown when the PIN code has expired or been consumed.
struct SimklPINExpiredError: Error {}
