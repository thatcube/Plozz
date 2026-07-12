import Foundation
import Observation
import CoreModels
import CoreNetworking

/// Connection phase for Simkl (mirrors Trakt's pattern).
public enum SimklConnectionPhase: Equatable, Sendable {
    case unknown
    case unavailable
    case disconnected
    case connecting(userCode: String, verificationURL: String, expiresAt: Date)
    case connected(username: String)
    case error(String)
}

/// App-level façade for the Simkl integration.
@MainActor
@Observable
public final class SimklService {
    public private(set) var phase: SimklConnectionPhase
    public private(set) var codeLifetime: TimeInterval = 900

    @ObservationIgnored public let scrobbler: any SimklScrobbling

    @ObservationIgnored private let config: SimklConfig
    @ObservationIgnored private let auth: SimklAuthService
    @ObservationIgnored private let tokenStore: SimklTokenStoring
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var profileGeneration: UInt64 = 0

    public init(config: SimklConfig, http: HTTPClient = URLSessionHTTPClient(), tokenStore: SimklTokenStoring) {
        self.config = config
        self.auth = SimklAuthService(config: config, http: http)
        self.tokenStore = tokenStore
        if config.isConfigured {
            self.scrobbler = SimklScrobbler(config: config, http: http, tokenStore: tokenStore)
            self.phase = .unknown
        } else {
            self.scrobbler = DisabledSimklScrobbler()
            self.phase = .unavailable
        }
    }

    public var isConfigured: Bool { config.isConfigured }

    public func setActiveProfile(namespace: String?) async {
        profileGeneration &+= 1
        let generation = profileGeneration
        connectTask?.cancel()
        connectTask = nil
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
        do {
            let settings = try await auth.userSettings(accessToken: tokens.accessToken)
            guard generation == profileGeneration else { return }
            phase = .connected(username: settings.displayName)
        } catch {
            guard generation == profileGeneration else { return }
            try? tokenStore.clear()
            phase = .disconnected
        }
    }

    public func connect() {
        guard config.isConfigured else { phase = .unavailable; return }
        connectTask?.cancel()
        profileGeneration &+= 1
        let generation = profileGeneration
        connectTask = Task { [weak self] in
            guard let self else { return }
            do {
                while true {
                    try Task.checkCancellation()
                    let code = try await self.auth.beginDeviceCode()
                    try Task.checkCancellation()
                    guard generation == self.profileGeneration else { return }
                    self.codeLifetime = code.expiresIn
                    self.phase = .connecting(
                        userCode: code.userCode,
                        verificationURL: code.verificationURL,
                        expiresAt: Date().addingTimeInterval(code.expiresIn)
                    )
                    do {
                        let tokens = try await self.auth.awaitToken(for: code)
                        try Task.checkCancellation()
                        guard generation == self.profileGeneration else { return }
                        try? self.tokenStore.save(tokens)
                        let settings = try? await self.auth.userSettings(accessToken: tokens.accessToken)
                        guard generation == self.profileGeneration else { return }
                        self.phase = .connected(username: settings?.displayName ?? "Simkl")
                        return
                    } catch let error as AppError where error == .quickConnectExpired {
                        continue
                    }
                }
            } catch is CancellationError {
                // Cancelled by user.
            } catch let error as AppError {
                if error == .cancelled { return }
                guard generation == self.profileGeneration else { return }
                self.phase = .error(error.userMessage)
            } catch {
                guard generation == self.profileGeneration else { return }
                self.phase = .error(AppError.unknown("").userMessage)
            }
        }
    }

    public func cancelConnect() {
        profileGeneration &+= 1
        connectTask?.cancel()
        connectTask = nil
        phase = config.isConfigured ? .disconnected : .unavailable
    }

    public func disconnect() async {
        profileGeneration &+= 1
        connectTask?.cancel()
        connectTask = nil
        try? tokenStore.clear()
        phase = config.isConfigured ? .disconnected : .unavailable
    }
}

/// Factory for building SimklService.
public enum SimklServiceFactory {
    @MainActor
    public static func make(
        config: SimklConfig = .resolved(),
        http: HTTPClient = URLSessionHTTPClient(),
        tokenStore: SimklTokenStoring? = nil,
        namespace: String? = nil
    ) -> SimklService {
        let store = tokenStore ?? defaultTokenStore()
        store.setNamespace(namespace)
        return SimklService(config: config, http: http, tokenStore: store)
    }

    public static func defaultTokenStore() -> SimklTokenStoring {
        #if canImport(Security)
        return KeychainSimklTokenStore()
        #else
        return InMemorySimklTokenStore()
        #endif
    }
}
