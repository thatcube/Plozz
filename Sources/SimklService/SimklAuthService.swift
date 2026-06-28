import Foundation
import CoreModels
import CoreNetworking

/// Orchestrates the Simkl OAuth device-code flow (same pattern as Trakt).
public struct SimklAuthService: Sendable {
    private let client: SimklClient
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    public init(
        config: SimklConfig,
        http: HTTPClient = URLSessionHTTPClient(),
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
        }
    ) {
        self.client = SimklClient(config: config, http: http)
        self.sleep = sleep
    }

    public func beginDeviceCode() async throws -> SimklDeviceCode {
        try await client.requestDeviceCode()
    }

    /// Polls for approval, returning the token once the user authorizes.
    public func awaitToken(for code: SimklDeviceCode) async throws -> SimklTokens {
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

    public func userSettings(accessToken: String) async throws -> SimklUserSettings {
        try await client.userSettings(accessToken: accessToken)
    }
}
