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

    // MARK: - OAuth (device code)

    func requestDeviceCode() async throws -> SimklDeviceCode {
        let body = ["client_id": config.clientID ?? ""]
        let endpoint = try Endpoint(method: .post, path: "/oauth/device/code", headers: headers())
            .jsonBody(body)
        return try await http.decode(SimklDeviceCode.self, from: endpoint, baseURL: baseURL)
    }

    func requestToken(deviceCode: String) async throws -> SimklTokenResponse {
        let body = [
            "code": deviceCode,
            "client_id": config.clientID ?? "",
            "client_secret": config.clientSecret ?? ""
        ]
        let endpoint = try Endpoint(method: .post, path: "/oauth/device/token", headers: headers())
            .jsonBody(body)
        return try await http.decode(SimklTokenResponse.self, from: endpoint, baseURL: baseURL)
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
}
