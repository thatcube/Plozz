import Foundation
import Observation
import CoreModels
import CoreNetworking

/// Connection phase for MAL (device-code flow like Trakt).
public enum MALConnectionPhase: Equatable, Sendable {
    case unknown
    case unavailable
    case disconnected
    case connecting(userCode: String, verificationURL: String, expiresAt: Date)
    case connected(username: String)
    case error(String)
}

/// App-level façade for the MyAnimeList integration.
@MainActor
@Observable
public final class MALService {
    public private(set) var phase: MALConnectionPhase
    public private(set) var codeLifetime: TimeInterval = 600

    @ObservationIgnored public let scrobbler: any MALScrobbling

    @ObservationIgnored private let config: MALConfig
    @ObservationIgnored private let auth: MALAuthService
    @ObservationIgnored private let tokenStore: MALTokenStoring
    @ObservationIgnored private var connectTask: Task<Void, Never>?

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
        connectTask = Task { [weak self] in
            guard let self else { return }
            do {
                while true {
                    try Task.checkCancellation()
                    let code = try await self.auth.beginDeviceCode()
                    try Task.checkCancellation()
                    self.codeLifetime = code.expiresIn
                    self.phase = .connecting(
                        userCode: code.userCode,
                        verificationURL: code.verificationURL,
                        expiresAt: Date().addingTimeInterval(code.expiresIn)
                    )
                    do {
                        let tokens = try await self.auth.awaitToken(for: code)
                        try Task.checkCancellation()
                        try? self.tokenStore.save(tokens)
                        let user = try? await self.auth.userInfo(accessToken: tokens.accessToken)
                        self.phase = .connected(username: user?.name ?? "MyAnimeList")
                        return
                    } catch let error as AppError where error == .quickConnectExpired {
                        continue
                    }
                }
            } catch is CancellationError {
                // Cancelled by user.
            } catch let error as AppError {
                if error == .cancelled { return }
                self.phase = .error(error.userMessage)
            } catch {
                self.phase = .error(AppError.unknown("").userMessage)
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
