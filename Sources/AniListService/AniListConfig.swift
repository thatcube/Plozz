import Foundation

/// Configuration for the AniList integration.
///
/// AniList uses OAuth 2.0. When both client ID and secret are available, we use
/// the Authorization Code grant (shorter code to type on TV). Falls back to
/// implicit grant (long token paste) if only the client ID is configured.
public struct AniListConfig: Sendable, Equatable {
    public var clientID: String?
    public var clientSecret: String?
    public var apiBaseURL: URL
    public var authBaseURL: URL

    public init(
        clientID: String? = nil,
        clientSecret: String? = nil,
        apiBaseURL: URL = URL(string: "https://graphql.anilist.co")!,
        authBaseURL: URL = URL(string: "https://anilist.co")!
    ) {
        self.clientID = Self.sanitize(clientID)
        self.clientSecret = Self.sanitize(clientSecret)
        self.apiBaseURL = apiBaseURL
        self.authBaseURL = authBaseURL
    }

    public var isConfigured: Bool {
        clientID != nil
    }

    /// Whether we can use the auth-code grant (requires secret).
    public var supportsCodeGrant: Bool {
        clientID != nil && clientSecret != nil
    }

    /// The authorization URL the user visits. Uses code grant if secret is
    /// available (shorter code to type), otherwise implicit grant (full token).
    public var authorizationURL: String? {
        guard let clientID else { return nil }
        if clientSecret != nil {
            return "\(authBaseURL)/api/v2/oauth/authorize?client_id=\(clientID)&response_type=code&redirect_uri=https://anilist.co/api/v2/oauth/pin"
        }
        return "\(authBaseURL)/api/v2/oauth/authorize?client_id=\(clientID)&response_type=token"
    }

    public static func resolved(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AniListConfig {
        let plistID = bundle.object(forInfoDictionaryKey: "AniListClientID") as? String
        let plistSecret = bundle.object(forInfoDictionaryKey: "AniListClientSecret") as? String
        return AniListConfig(
            clientID: sanitize(plistID) ?? sanitize(environment["ANILIST_CLIENT_ID"]),
            clientSecret: sanitize(plistSecret) ?? sanitize(environment["ANILIST_CLIENT_SECRET"])
        )
    }

    private static func sanitize(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !trimmed.contains("$(")
        else { return nil }
        return trimmed
    }
}
