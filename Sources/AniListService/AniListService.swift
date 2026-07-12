import Foundation
import Observation
import CoreModels
import CoreNetworking

/// Connection phase for AniList.
///
/// AniList doesn't support device-code flow, so we use a "token entry" approach:
/// show the user a URL/QR code to authorize, and they paste the resulting token
/// back on the TV.
public enum AniListConnectionPhase: Equatable, Sendable {
    case unknown
    case unavailable
    case disconnected
    /// Waiting for the user to enter their token from the authorization page.
    case awaitingToken(authorizationURL: String)
    case connected(username: String)
    case error(String)
}

/// App-level façade for the AniList integration.
@MainActor
@Observable
public final class AniListService {
    public private(set) var phase: AniListConnectionPhase

    @ObservationIgnored public let scrobbler: any AniListScrobbling

    @ObservationIgnored private let config: AniListConfig
    @ObservationIgnored private let tokenStore: AniListTokenStoring
    @ObservationIgnored private let http: HTTPClient
    @ObservationIgnored private var pendingSession: String?
    @ObservationIgnored private var profileGeneration: UInt64 = 0

    public init(config: AniListConfig, http: HTTPClient = URLSessionHTTPClient(), tokenStore: AniListTokenStoring) {
        self.config = config
        self.http = http
        self.tokenStore = tokenStore
        if config.isConfigured {
            self.scrobbler = AniListScrobbler(config: config, http: http, tokenStore: tokenStore)
            self.phase = .unknown
        } else {
            self.scrobbler = DisabledAniListScrobbler()
            self.phase = .unavailable
        }
    }

    public var isConfigured: Bool { config.isConfigured }

    public func setActiveProfile(namespace: String?) async {
        profileGeneration &+= 1
        let generation = profileGeneration
        tokenStore.setNamespace(namespace)
        phase = config.isConfigured ? .unknown : .unavailable
        await refreshStatus(generation: generation)
    }

    public func refreshStatus() async {
        await refreshStatus(generation: profileGeneration)
    }

    private func refreshStatus(generation: UInt64) async {
        guard config.isConfigured else { phase = .unavailable; return }
        guard let tokens = tokenStore.load() else { phase = .disconnected; return }
        let client = AniListClient(config: config, http: http)
        do {
            let user = try await client.viewer(accessToken: tokens.accessToken)
            guard generation == profileGeneration else { return }
            phase = .connected(username: user.name)
        } catch {
            guard generation == profileGeneration else { return }
            try? tokenStore.clear()
            phase = .disconnected
        }
    }

    /// Begins the connection flow: shows the authorization URL for the user to visit.
    public func connect() {
        guard config.isConfigured else { phase = .unavailable; return }
        guard let url = config.authorizationURL else { phase = .unavailable; return }
        profileGeneration &+= 1
        // Mint a 32-char TV session so the short redeem code is bound to this TV.
        let session = Self.randomSession()
        pendingSession = session
        phase = .awaitingToken(authorizationURL: "\(url)?s=\(session)")
    }

    /// Completes the connection by redeeming a short code from the auth relay.
    public func submitToken(_ input: String) async {
        profileGeneration &+= 1
        let generation = profileGeneration
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            phase = .error("Code cannot be empty")
            return
        }

        do {
            var redeemString = "\(config.relayBaseURL)/api/redeem?code=\(trimmed)"
            if let session = pendingSession {
                redeemString += "&session=\(session)"
            }
            let redeemURL = URL(string: redeemString)!
            let (data, _) = try await URLSession.shared.data(from: redeemURL)
            guard generation == profileGeneration else { return }
            let result = try JSONDecoder().decode(RelayRedeemResponse.self, from: data)

            let accessToken = result.accessToken
            let client = AniListClient(config: config, http: http)
            let user = try await client.viewer(accessToken: accessToken)
            guard generation == profileGeneration else { return }
            let tokens = AniListTokens(accessToken: accessToken)
            try? tokenStore.save(tokens)
            pendingSession = nil
            phase = .connected(username: user.name)
        } catch {
            guard generation == profileGeneration else { return }
            phase = .error("Invalid or expired code — please try again")
        }
    }

    /// 32-char URL-safe session id binding a redeem code to this TV.
    private static func randomSession() -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<32).map { _ in chars.randomElement()! })
    }

    /// Cancels an in-flight connection attempt.
    public func cancelConnect() {
        profileGeneration &+= 1
        pendingSession = nil
        phase = config.isConfigured ? .disconnected : .unavailable
    }

    /// Disconnects: clears the stored token.
    public func disconnect() async {
        profileGeneration &+= 1
        pendingSession = nil
        try? tokenStore.clear()
        phase = config.isConfigured ? .disconnected : .unavailable
    }
}

/// Factory for building AniListService.
public enum AniListServiceFactory {
    @MainActor
    public static func make(
        config: AniListConfig = .resolved(),
        http: HTTPClient = URLSessionHTTPClient(),
        tokenStore: AniListTokenStoring? = nil,
        namespace: String? = nil
    ) -> AniListService {
        let store = tokenStore ?? defaultTokenStore()
        store.setNamespace(namespace)
        return AniListService(config: config, http: http, tokenStore: store)
    }

    public static func defaultTokenStore() -> AniListTokenStoring {
        #if canImport(Security)
        return KeychainAniListTokenStore()
        #else
        return InMemoryAniListTokenStore()
        #endif
    }
}

/// Response from the auth relay's /api/redeem endpoint.
private struct RelayRedeemResponse: Decodable {
    let service: String
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case service
        case accessToken
        case refreshToken
        case expiresIn
    }
}
