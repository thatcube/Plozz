import Foundation
import CoreModels
import CoreNetworking

/// Orchestrates the MAL OAuth device-code flow.
public struct MALAuthService: Sendable {
    private let client: MALClient
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    public init(
        config: MALConfig,
        http: HTTPClient = URLSessionHTTPClient(),
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
        }
    ) {
        self.client = MALClient(config: config, http: http)
        self.sleep = sleep
    }

    public func beginDeviceCode() async throws -> MALDeviceCode {
        try await client.requestDeviceCode()
    }

    /// Polls for approval, returning tokens once the user authorizes.
    public func awaitToken(for code: MALDeviceCode) async throws -> MALTokens {
        let deadline = Date().addingTimeInterval(code.expiresIn)
        let pollInterval = max(code.interval, 5)
        while Date() < deadline {
            try Task.checkCancellation()
            do {
                let response = try await client.requestToken(deviceCode: code.deviceCode)
                return response.tokens
            } catch is CancellationError {
                throw AppError.cancelled
            } catch {
                try await sleep(pollInterval)
            }
        }
        throw AppError.quickConnectExpired
    }

    /// Refreshes an expired access token.
    public func refresh(_ refreshToken: String) async throws -> MALTokens {
        try await client.refreshToken(refreshToken).tokens
    }

    public func userInfo(accessToken: String) async throws -> MALUserInfo {
        try await client.userInfo(accessToken: accessToken)
    }
}
