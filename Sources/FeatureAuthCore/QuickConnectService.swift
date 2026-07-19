import Foundation
import CoreModels
import CoreNetworking
import ProviderJellyfin

/// Orchestrates the Jellyfin Quick Connect handshake end-to-end:
/// initiate → display code → poll → exchange secret → build `UserSession`.
///
/// Polling honours both an overall timeout and Swift task cancellation so the
/// UI can offer Cancel/Retry cleanly (a Phase 1 requirement).
public struct QuickConnectService: Sendable {
    public struct Configuration: Sendable {
        public var pollInterval: TimeInterval
        public var timeout: TimeInterval
        public init(pollInterval: TimeInterval = 3, timeout: TimeInterval = 120) {
            self.pollInterval = pollInterval
            self.timeout = timeout
        }
    }

    private let server: MediaServer
    private let deviceID: String
    private let http: HTTPClient
    private let config: Configuration
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    public init(
        server: MediaServer,
        deviceID: String,
        http: HTTPClient = URLSessionHTTPClient(),
        config: Configuration = Configuration(),
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) {
        self.server = server
        self.deviceID = deviceID
        self.http = http
        self.config = config
        self.now = now
        self.sleep = sleep
    }

    /// How long a freshly issued code remains valid before it expires.
    public var timeout: TimeInterval { config.timeout }

    private var client: JellyfinClient {
        JellyfinClient(baseURL: server.baseURL, deviceProfile: JellyfinDeviceProfile(deviceID: deviceID), http: http)
    }

    /// Begins a Quick Connect request. Throws `.quickConnectUnavailable` if the
    /// server has the feature disabled.
    public func begin() async throws -> QuickConnectChallenge {
        guard try await client.quickConnectEnabled() else {
            throw AppError.quickConnectUnavailable
        }
        return try await client.quickConnectInitiate()
    }

    /// Polls until the user approves the request, then exchanges the secret for
    /// a full `UserSession`.
    ///
    /// - Throws: `.quickConnectExpired` on timeout, `.cancelled` if the task is
    ///   cancelled, or any transport error.
    public func awaitApproval(for challenge: QuickConnectChallenge) async throws -> UserSession {
        let deadline = now().addingTimeInterval(config.timeout)
        let client = self.client

        while now() < deadline {
            try Task.checkCancellation()
            let state = try await client.quickConnectState(secret: challenge.secret)
            if state.isAuthenticated {
                let auth = try await client.authenticate(withSecret: challenge.secret)
                let resolvedServer = MediaServer(
                    id: auth.serverID ?? server.id,
                    name: server.name,
                    baseURL: server.baseURL,
                    provider: .jellyfin,
                    version: server.version
                )
                return UserSession(
                    server: resolvedServer,
                    userID: auth.userID,
                    userName: auth.userName,
                    avatarURL: client.userAvatarURL(userID: auth.userID, maxWidth: 120, token: auth.token),
                    deviceID: deviceID,
                    accessToken: auth.token
                )
            }
            try await sleep(config.pollInterval)
        }
        throw AppError.quickConnectExpired
    }
}
