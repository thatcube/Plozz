import Foundation
import Observation
import CoreModels
import CoreNetworking

/// The state of the device's Trakt connection, rendered by Settings.
public enum TraktConnectionPhase: Equatable, Sendable {
    /// Status not yet determined (initial).
    case unknown
    /// No Trakt client credentials are configured in this build.
    case unavailable
    /// Configured but the user hasn't connected an account.
    case disconnected
    /// Device-code issued; waiting for the user to approve it on the web.
    case connecting(userCode: String, verificationURL: String, expiresAt: Date)
    /// Connected to `username`'s Trakt account.
    case connected(username: String)
    /// A connection attempt failed.
    case error(String)
}

/// App-level façade for the Trakt integration.
///
/// Owns the connection lifecycle (device-code OAuth, status, disconnect) for the
/// Settings UI and exposes the `scrobbler` the player uses to sync watches. The
/// connection model and the scrobbler share one `TraktTokenStoring`, so a
/// connection made in Settings is immediately usable by playback and vice-versa.
@MainActor
@Observable
public final class TraktService {
    public private(set) var phase: TraktConnectionPhase

    /// The scrobbler injected into playback. A no-op when Trakt is unconfigured.
    @ObservationIgnored public let scrobbler: any TraktScrobbling

    @ObservationIgnored private let config: TraktConfig
    @ObservationIgnored private let auth: TraktAuthService
    @ObservationIgnored private let tokenStore: TraktTokenStoring
    @ObservationIgnored private var connectTask: Task<Void, Never>?

    public init(config: TraktConfig, http: HTTPClient = URLSessionHTTPClient(), tokenStore: TraktTokenStoring) {
        self.config = config
        self.auth = TraktAuthService(config: config, http: http)
        self.tokenStore = tokenStore
        if config.isConfigured {
            self.scrobbler = TraktScrobbler(config: config, http: http, tokenStore: tokenStore)
            self.phase = .unknown
        } else {
            self.scrobbler = DisabledTraktScrobbler()
            self.phase = .unavailable
        }
    }

    /// Whether the feature is offered at all (client credentials present).
    public var isConfigured: Bool { config.isConfigured }

    /// Switches the service (and its shared scrobbler) to a household profile's
    /// own Trakt connection. Each profile connects/disconnects independently;
    /// the default profile uses `nil` (legacy un-namespaced storage). Cancels any
    /// in-flight connect, repoints the shared token store, then re-resolves status.
    public func setActiveProfile(namespace: String?) async {
        connectTask?.cancel()
        connectTask = nil
        tokenStore.setNamespace(namespace)
        phase = config.isConfigured ? .unknown : .unavailable
        await refreshStatus()
    }

    /// Resolves the current connection status: verifies any stored token (and
    /// refreshes it if expired), then loads the username for display. Safe to
    /// call repeatedly (e.g. when Settings appears).
    public func refreshStatus() async {
        guard config.isConfigured else { phase = .unavailable; return }
        guard let tokens = tokenStore.load() else { phase = .disconnected; return }
        do {
            let access = try await validAccessToken(tokens)
            let settings = try await auth.userSettings(accessToken: access)
            phase = .connected(username: settings.displayName)
        } catch {
            // Token rejected/unusable — surface as disconnected so the user can
            // reconnect. The stale token is cleared so the scrobbler no-ops.
            try? tokenStore.clear()
            phase = .disconnected
        }
    }

    /// Starts (or restarts) the device-code flow: shows a code, then polls until
    /// the user approves it at `trakt.tv/activate`.
    public func connect() {
        guard config.isConfigured else { phase = .unavailable; return }
        connectTask?.cancel()
        connectTask = Task { [weak self] in
            guard let self else { return }
            do {
                let code = try await self.auth.beginDeviceCode()
                try Task.checkCancellation()
                self.phase = .connecting(
                    userCode: code.userCode,
                    verificationURL: code.verificationURL,
                    expiresAt: Date().addingTimeInterval(code.expiresIn)
                )
                let tokens = try await self.auth.awaitToken(for: code)
                try Task.checkCancellation()
                try? self.tokenStore.save(tokens)
                let settings = try? await self.auth.userSettings(accessToken: tokens.accessToken)
                self.phase = .connected(username: settings?.displayName ?? "Trakt")
            } catch is CancellationError {
                // Cancelled by the user; `cancelConnect()` set the phase.
            } catch let error as AppError {
                if error == .cancelled { return }
                self.phase = .error(error.userMessage)
            } catch {
                self.phase = .error(AppError.unknown("").userMessage)
            }
        }
    }

    /// Aborts an in-flight connection attempt.
    public func cancelConnect() {
        connectTask?.cancel()
        connectTask = nil
        phase = config.isConfigured ? .disconnected : .unavailable
    }

    /// Disconnects: revokes the token server-side (best-effort) and clears it.
    public func disconnect() async {
        connectTask?.cancel()
        connectTask = nil
        if let tokens = tokenStore.load() {
            try? await auth.revoke(accessToken: tokens.accessToken)
        }
        try? tokenStore.clear()
        phase = config.isConfigured ? .disconnected : .unavailable
    }

    /// Returns a usable access token, refreshing + persisting an expired one.
    private func validAccessToken(_ tokens: TraktTokens) async throws -> String {
        guard tokens.isExpired else { return tokens.accessToken }
        let refreshed = try await auth.refresh(tokens.refreshToken)
        try? tokenStore.save(refreshed)
        return refreshed.accessToken
    }
}

/// Builds the app's `TraktService` from configuration, choosing a Keychain-backed
/// token store on Apple platforms and an in-memory one elsewhere.
public enum TraktServiceFactory {
    @MainActor
    public static func make(
        config: TraktConfig = .resolved(),
        http: HTTPClient = URLSessionHTTPClient(),
        tokenStore: TraktTokenStoring? = nil,
        namespace: String? = nil
    ) -> TraktService {
        let store = tokenStore ?? defaultTokenStore()
        store.setNamespace(namespace)
        return TraktService(config: config, http: http, tokenStore: store)
    }

    public static func defaultTokenStore() -> TraktTokenStoring {
        #if canImport(Security)
        return KeychainTraktTokenStore()
        #else
        return InMemoryTraktTokenStore()
        #endif
    }
}
