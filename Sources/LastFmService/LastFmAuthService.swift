import Foundation
import CoreModels
import CoreNetworking

/// Orchestrates the Last.fm desktop-auth flow (TV-friendly, no code typing).
///
/// 1. `auth.getToken` → an unauthorized request token.
/// 2. The UI shows a QR to `last.fm/api/auth/?api_key=…&token=…`; the user
///    approves on their phone.
/// 3. `awaitSession` polls `auth.getSession` until Last.fm returns the durable
///    session key (error 14 = "still pending" while the user hasn't approved).
public struct LastFmAuthService: Sendable {
    private let client: LastFmClient
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    /// Last.fm request tokens are valid for ~60 minutes.
    static let tokenLifetime: TimeInterval = 3600
    /// Seconds between `auth.getSession` polls.
    static let pollInterval: TimeInterval = 5

    public init(
        config: LastFmConfig,
        http: HTTPClient = URLSessionHTTPClient(),
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
        }
    ) {
        self.client = LastFmClient(config: config, http: http)
        self.sleep = sleep
    }

    /// Requests a fresh unauthorized request token.
    public func beginToken() async throws -> String {
        try await client.getToken()
    }

    /// Builds the approval URL the user opens (encoded in the QR the TV shows).
    public func authURL(token: String, apiKey: String, base: URL) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "token", value: token)
        ]
        return components?.url ?? base
    }

    /// Polls `auth.getSession` until the user approves (→ session key) or the
    /// request token's ~60-minute lifetime elapses.
    public func awaitSession(token: String) async throws -> LastFmTokens {
        let deadline = Date().addingTimeInterval(Self.tokenLifetime)
        while Date() < deadline {
            try Task.checkCancellation()
            do {
                return try await client.getSession(token: token)
            } catch let error as LastFmAPIError where error.isPendingAuthorization {
                // Not approved yet — keep waiting.
            } catch let error as LastFmAPIError where error.isTokenExpired {
                throw AppError.quickConnectExpired
            } catch is CancellationError {
                throw AppError.cancelled
            }
            try await sleep(Self.pollInterval)
        }
        throw AppError.quickConnectExpired
    }
}
