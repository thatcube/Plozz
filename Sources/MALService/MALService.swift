import Foundation
import Observation
import CoreModels
import CoreNetworking

/// Connection phase for MAL.
public enum MALConnectionPhase: Equatable, Sendable {
    case unknown
    case unavailable
    case disconnected
    case awaitingAuthorizationCode(authorizationURL: String)
    case connected(username: String)
    case error(String)
}

/// App-level façade for the MyAnimeList integration.
@MainActor
@Observable
public final class MALService {
    public private(set) var phase: MALConnectionPhase

    @ObservationIgnored public let scrobbler: any MALScrobbling

    @ObservationIgnored private let config: MALConfig
    @ObservationIgnored private let auth: MALAuthService
    @ObservationIgnored private let tokenStore: MALTokenStoring
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    /// Per-attempt secret carried in the auth QR and required to redeem, so the
    /// 4-digit code alone can't be brute-forced against the relay.
    @ObservationIgnored private var tvSecret = ""

    public init(config: MALConfig, http: HTTPClient = URLSessionHTTPClient(), tokenStore: MALTokenStoring) {
        self.config = config
        self.auth = MALAuthService(config: config, http: http)
        self.tokenStore = tokenStore
        if config.isConfigured {
            self.scrobbler = MALScrobbler(config: config, http: http, tokenStore: tokenStore)
            self.phase = .unknown
        } else {
            self.scrobbler = DisabledMALScrobbler()
            self.phase = .unavailable
        }
    }

    public var isConfigured: Bool { config.isConfigured }

    public func setActiveProfile(namespace: String?) async {
        connectTask?.cancel()
        connectTask = nil
        tokenStore.setNamespace(namespace)
        phase = config.isConfigured ? .unknown : .unavailable
        await refreshStatus()
    }

    public func refreshStatus() async {
        guard config.isConfigured else { phase = .unavailable; return }
        guard let tokens = tokenStore.load() else { phase = .disconnected; return }
        do {
            let access = try await validAccessToken(tokens)
            let user = try await auth.userInfo(accessToken: access)
            phase = .connected(username: user.name)
        } catch {
            try? tokenStore.clear()
            phase = .disconnected
        }
    }

    public func connect() {
        guard config.isConfigured else { phase = .unavailable; return }
        connectTask?.cancel()
        connectTask = nil
        // Show the relay auth URL — Worker handles PKCE and exchange
        tvSecret = RelaySecret.generate()
        phase = .awaitingAuthorizationCode(authorizationURL: "\(config.relayBaseURL)/myanimelist?tv=\(tvSecret)")
    }

    /// Redeems a short code from the auth relay to get the access token.
    public func submitAuthorizationCode(_ input: String) {
        guard config.isConfigured else { phase = .unavailable; return }

        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            phase = .error("Code cannot be empty")
            return
        }

        connectTask?.cancel()
        connectTask = Task { [weak self] in
            guard let self else { return }
            do {
                let redeemURL = URL(string: "\(self.config.relayBaseURL)/api/redeem?code=\(trimmed)&tv=\(self.tvSecret)")!
                let (data, _) = try await URLSession.shared.data(from: redeemURL)
                let result = try JSONDecoder().decode(RelayRedeemResponse.self, from: data)

                let tokens = MALTokens(
                    accessToken: result.accessToken,
                    refreshToken: result.refreshToken ?? "",
                    expiresAt: Date().addingTimeInterval(Double(result.expiresIn ?? 3600))
                )
                try Task.checkCancellation()
                try? self.tokenStore.save(tokens)
                let user = try? await self.auth.userInfo(accessToken: tokens.accessToken)
                self.connectTask = nil
                self.phase = .connected(username: user?.name ?? "MyAnimeList")
            } catch is CancellationError {
                self.connectTask = nil
            } catch {
                self.connectTask = nil
                self.phase = .error("Invalid or expired code — please try again")
            }
        }
    }

    public func cancelConnect() {
        connectTask?.cancel()
        connectTask = nil
        phase = config.isConfigured ? .disconnected : .unavailable
    }

    public func disconnect() async {
        connectTask?.cancel()
        connectTask = nil
        try? tokenStore.clear()
        phase = config.isConfigured ? .disconnected : .unavailable
    }

    private func validAccessToken(_ tokens: MALTokens) async throws -> String {
        guard tokens.isExpired else { return tokens.accessToken }
        let refreshed = try await auth.refresh(tokens.refreshToken)
        try? tokenStore.save(refreshed)
        return refreshed.accessToken
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

/// Factory for building MALService.
public enum MALServiceFactory {
    @MainActor
    public static func make(
        config: MALConfig = .resolved(),
        http: HTTPClient = URLSessionHTTPClient(),
        tokenStore: MALTokenStoring? = nil,
        namespace: String? = nil
    ) -> MALService {
        let store = tokenStore ?? defaultTokenStore()
        store.setNamespace(namespace)
        return MALService(config: config, http: http, tokenStore: store)
    }

    public static func defaultTokenStore() -> MALTokenStoring {
        #if canImport(Security)
        return KeychainMALTokenStore()
        #else
        return InMemoryMALTokenStore()
        #endif
    }
}
