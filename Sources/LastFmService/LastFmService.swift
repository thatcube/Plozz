import Foundation
import Observation
import CoreModels
import CoreNetworking

/// Connection phase for Last.fm (mirrors the Trakt/Simkl tracker pattern, but the
/// connecting case carries the approval URL to render as a QR — Last.fm's
/// desktop-auth flow has the user approve on their phone, no code typed on the TV).
public enum LastFmConnectionPhase: Equatable, Sendable {
    case unknown
    case unavailable
    case disconnected
    case connecting(authURL: String, expiresAt: Date)
    case connected(username: String)
    case error(String)
}

/// App-level façade for the Last.fm music-scrobbling integration.
@MainActor
@Observable
public final class LastFmService {
    public private(set) var phase: LastFmConnectionPhase

    /// Stable scrobbler handle. Captured ONCE by the audio controller — it is
    /// never rebuilt on profile switch (only the token store's namespace changes),
    /// so the controller keeps scrobbling to whichever profile is active.
    @ObservationIgnored public let scrobbler: any LastFmScrobbling

    @ObservationIgnored private let config: LastFmConfig
    @ObservationIgnored private let auth: LastFmAuthService
    @ObservationIgnored private let tokenStore: LastFmTokenStoring
    @ObservationIgnored private var connectTask: Task<Void, Never>?

    public init(config: LastFmConfig, http: HTTPClient = URLSessionHTTPClient(), tokenStore: LastFmTokenStoring) {
        self.config = config
        self.auth = LastFmAuthService(config: config, http: http)
        self.tokenStore = tokenStore
        if config.isConfigured {
            self.scrobbler = LastFmScrobbler(config: config, http: http, tokenStore: tokenStore)
            self.phase = .unknown
        } else {
            self.scrobbler = DisabledLastFmScrobbler()
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

    /// The Last.fm session key never expires, so a stored token means connected;
    /// there is no cheap validation call to make (and staying offline-friendly is
    /// preferable). A revoked key surfaces as a scrobble failure, not here.
    public func refreshStatus() async {
        guard config.isConfigured else { phase = .unavailable; return }
        guard let tokens = tokenStore.load() else { phase = .disconnected; return }
        phase = .connected(username: tokens.username)
    }

    public func connect() {
        guard config.isConfigured, let apiKey = config.apiKey else { phase = .unavailable; return }
        connectTask?.cancel()
        connectTask = Task { [weak self] in
            guard let self else { return }
            do {
                while true {
                    try Task.checkCancellation()
                    let token = try await self.auth.beginToken()
                    try Task.checkCancellation()
                    let url = self.auth.authURL(token: token, apiKey: apiKey, base: self.config.authPageURL)
                    self.phase = .connecting(
                        authURL: url.absoluteString,
                        expiresAt: Date().addingTimeInterval(LastFmAuthService.tokenLifetime)
                    )
                    do {
                        let tokens = try await self.auth.awaitSession(token: token)
                        try Task.checkCancellation()
                        try? self.tokenStore.save(tokens)
                        self.phase = .connected(username: tokens.username)
                        return
                    } catch let error as AppError where error == .quickConnectExpired {
                        // Request token expired before approval — mint a new one.
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
}

/// Factory for building `LastFmService`.
public enum LastFmServiceFactory {
    @MainActor
    public static func make(
        config: LastFmConfig = .resolved(),
        http: HTTPClient = URLSessionHTTPClient(),
        tokenStore: LastFmTokenStoring? = nil,
        namespace: String? = nil
    ) -> LastFmService {
        let store = tokenStore ?? defaultTokenStore()
        store.setNamespace(namespace)
        return LastFmService(config: config, http: http, tokenStore: store)
    }

    public static func defaultTokenStore() -> LastFmTokenStoring {
        #if canImport(Security)
        return KeychainLastFmTokenStore()
        #else
        return InMemoryLastFmTokenStore()
        #endif
    }
}
