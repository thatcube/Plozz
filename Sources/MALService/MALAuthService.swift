import Foundation
import CoreModels
import CoreNetworking

/// Orchestrates the MAL OAuth authorization-code-with-PKCE flow.
public struct MALAuthService: Sendable {
    private let client: MALClient

    public init(config: MALConfig, http: HTTPClient = URLSessionHTTPClient()) {
        self.client = MALClient(config: config, http: http)
    }

    public func beginAuthorization() throws -> MALAuthorizationRequest {
        try client.beginAuthorization(codeVerifier: Self.makeCodeVerifier())
    }

    public func exchangeAuthorizationCode(_ code: String, codeVerifier: String) async throws -> MALTokens {
        try await client.requestToken(authorizationCode: code, codeVerifier: codeVerifier).tokens
    }

    /// Refreshes an expired access token.
    public func refresh(_ refreshToken: String) async throws -> MALTokens {
        try await client.refreshToken(refreshToken).tokens
    }

    public func userInfo(accessToken: String) async throws -> MALUserInfo {
        try await client.userInfo(accessToken: accessToken)
    }

    private static func makeCodeVerifier(length: Int = 64) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).compactMap { _ in alphabet.randomElement(using: &generator) })
    }
}
