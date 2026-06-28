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
        tokenStore.setNamespace(namespace)
        phase = config.isConfigured ? .unknown : .unavailable
        await refreshStatus()
    }

    public func refreshStatus() async {
        guard config.isConfigured else { phase = .unavailable; return }
        guard let tokens = tokenStore.load() else { phase = .disconnected; return }
        let client = AniListClient(config: config, http: http)
        do {
            let user = try await client.viewer(accessToken: tokens.accessToken)
            phase = .connected(username: user.name)
        } catch {
            try? tokenStore.clear()
            phase = .disconnected
        }
    }

    /// Begins the connection flow: shows the authorization URL for the user to visit.
    public func connect() {
        guard config.isConfigured else { phase = .unavailable; return }
        guard let url = config.authorizationURL else { phase = .unavailable; return }
        phase = .awaitingToken(authorizationURL: url)
    }

    /// Completes the connection with the access token from AniList's PIN page.
    ///
    /// Handles multiple input formats:
    /// - The raw access token (copied from the PIN page)
    /// - A full URL containing `access_token=...` (if user copies the whole URL)
    public func submitToken(_ input: String) async {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            phase = .error("Token cannot be empty")
            return
        }

        let accessToken = Self.extractToken(from: trimmed)
        let client = AniListClient(config: config, http: http)

        do {
            let user = try await client.viewer(accessToken: accessToken)
            let tokens = AniListTokens(accessToken: accessToken)
            try? tokenStore.save(tokens)
            phase = .connected(username: user.name)
        } catch {
            phase = .error("Invalid token — please try again")
        }
    }

    /// Extracts an access token from a redirect URL fragment like
    /// `http://localhost#access_token=XYZ&token_type=Bearer`
    private static func extractToken(from input: String) -> String {
        if input.contains("access_token=") {
            let fragment = input.components(separatedBy: "access_token=").last ?? ""
            return fragment.components(separatedBy: "&").first ?? input
        }
        return input
    }

    /// Cancels an in-flight connection attempt.
    public func cancelConnect() {
        phase = config.isConfigured ? .disconnected : .unavailable
    }

    /// Disconnects: clears the stored token.
    public func disconnect() async {
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
