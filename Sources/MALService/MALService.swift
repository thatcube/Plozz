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
    @ObservationIgnored private var pendingAuthorization: MALAuthorizationRequest?

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
        pendingAuthorization = nil
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
        do {
            let authorization = try auth.beginAuthorization()
            pendingAuthorization = authorization
            phase = .awaitingAuthorizationCode(authorizationURL: authorization.authorizationURL)
        } catch let error as AppError {
            phase = .error(error.userMessage)
        } catch {
            phase = .error(AppError.unknown("").userMessage)
        }
    }

    public func submitAuthorizationCode(_ input: String) {
        guard config.isConfigured else { phase = .unavailable; return }
        guard let pendingAuthorization else {
            phase = .error("Start a new MyAnimeList connection and try again")
            return
        }

        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            phase = .error("Authorization code cannot be empty")
            return
        }

        let authorizationCode = Self.extractAuthorizationCode(from: trimmed)
        connectTask?.cancel()
        connectTask = Task { [weak self] in
            guard let self else { return }
            do {
                let tokens = try await self.auth.exchangeAuthorizationCode(
                    authorizationCode,
                    codeVerifier: pendingAuthorization.codeVerifier
                )
                try Task.checkCancellation()
                try? self.tokenStore.save(tokens)
                let user = try? await self.auth.userInfo(accessToken: tokens.accessToken)
                self.pendingAuthorization = nil
                self.connectTask = nil
                self.phase = .connected(username: user?.name ?? "MyAnimeList")
            } catch is CancellationError {
                self.connectTask = nil
            } catch {
                self.connectTask = nil
                self.phase = .error("Invalid authorization code — please try again")
            }
        }
    }

    public func cancelConnect() {
        connectTask?.cancel()
        connectTask = nil
        pendingAuthorization = nil
        phase = config.isConfigured ? .disconnected : .unavailable
    }

    public func disconnect() async {
        connectTask?.cancel()
        connectTask = nil
        pendingAuthorization = nil
        try? tokenStore.clear()
        phase = config.isConfigured ? .disconnected : .unavailable
    }

    private func validAccessToken(_ tokens: MALTokens) async throws -> String {
        guard tokens.isExpired else { return tokens.accessToken }
        let refreshed = try await auth.refresh(tokens.refreshToken)
        try? tokenStore.save(refreshed)
        return refreshed.accessToken
    }

    private static func extractAuthorizationCode(from input: String) -> String {
        if let components = URLComponents(string: input),
           let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
           !code.isEmpty {
            return code
        }

        if let range = input.range(of: "code=") {
            let remainder = input[range.upperBound...]
            return remainder.split(separator: "&", maxSplits: 1).first.map(String.init) ?? input
        }

        return input
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
