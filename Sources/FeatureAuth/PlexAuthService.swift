import Foundation
import CoreModels
import CoreNetworking
import ProviderPlex

/// Orchestrates the Plex.tv PIN-link sign-in end-to-end:
/// create PIN → display code → poll until linked → list the account's servers →
/// build a `UserSession` for the chosen server.
///
/// Polling honours both an overall timeout and Swift task cancellation so the UI
/// can offer Cancel/Retry cleanly, mirroring `QuickConnectService`.
public struct PlexAuthService: Sendable {
    public struct Configuration: Sendable {
        public var pollInterval: TimeInterval
        public var timeout: TimeInterval
        public init(pollInterval: TimeInterval = 5, timeout: TimeInterval = 300) {
            self.pollInterval = pollInterval
            self.timeout = timeout
        }
    }

    private let deviceID: String
    private let http: HTTPClient
    private let config: Configuration
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    public init(
        deviceID: String,
        http: HTTPClient = URLSessionHTTPClient(),
        config: Configuration = Configuration(),
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) {
        self.deviceID = deviceID
        self.http = http
        self.config = config
        self.now = now
        self.sleep = sleep
    }

    /// How long an issued code stays valid before it expires.
    public var timeout: TimeInterval { config.timeout }
    /// Base delay between polls for one challenge.
    public var pollInterval: TimeInterval { config.pollInterval }

    private var client: PlexAuthClient {
        PlexAuthClient(deviceProfile: PlexDeviceProfile(clientIdentifier: deviceID), http: http)
    }

    /// Issues either a short manual-entry PIN or the strong challenge required
    /// by Plex's hosted authorization page.
    public func begin(strong: Bool = false) async throws -> PlexPinChallenge {
        try await client.createPin(strong: strong)
    }

    /// Hosted Plex authorization page for the issued PIN. The QR code uses this
    /// instead of `plex.tv/link`, whose query string does not pre-fill the code.
    public func authorizationURL(for pin: PlexPinChallenge) -> URL {
        client.authorizationURL(for: pin)
    }

    /// Polls until the user links the code, returning the account auth token.
    ///
    /// - Throws: `.quickConnectExpired` on timeout, `.cancelled` if the task is
    ///   cancelled, or any transport error.
    public func awaitLink(
        for pin: PlexPinChallenge,
        initialDelay: TimeInterval = 0
    ) async throws -> String {
        let deadline = now().addingTimeInterval(config.timeout)
        let client = self.client
        var nextDelay = config.pollInterval
        var consecutiveTransientFailures = 0
        if initialDelay > 0 {
            try await sleep(initialDelay)
        }
        while now() < deadline {
            try Task.checkCancellation()
            do {
                if case let .claimed(token) = try await client.pollPin(id: pin.id) {
                    return token
                }
                nextDelay = config.pollInterval
                consecutiveTransientFailures = 0
            } catch let error as PlexPinError {
                switch error {
                case let .rateLimited(retryAfter):
                    nextDelay = min(max(retryAfter ?? nextDelay * 2, config.pollInterval), 30)
                }
            } catch let error as AppError
                where error == .invalidResponse
                    || error == .serverUnreachable
                    || error == .decoding {
                consecutiveTransientFailures += 1
                guard consecutiveTransientFailures < 3 else { throw error }
                nextDelay = min(max(nextDelay * 2, config.pollInterval), 30)
            }
            try await sleep(nextDelay)
        }
        throw AppError.quickConnectExpired
    }

    /// The servers the linked account can reach (each with its best connection).
    public func servers(authToken: String) async throws -> [PlexServerCandidate] {
        try await client.servers(authToken: authToken)
    }

    /// Builds a `UserSession` for the chosen server, resolving the account user.
    public func makeSession(for candidate: PlexServerCandidate, authToken: String) async throws -> UserSession {
        let user = try await client.user(authToken: authToken)
        return UserSession(
            server: MediaServer(
                id: candidate.id,
                name: candidate.name,
                baseURL: candidate.baseURL,
                provider: .plex,
                connectionURLs: candidate.connectionURLs
            ),
            userID: user.id,
            userName: user.userName,
            avatarURL: user.avatarURL,
            deviceID: deviceID,
            accessToken: candidate.accessToken
        )
    }
}
