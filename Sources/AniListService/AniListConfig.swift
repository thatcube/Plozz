import Foundation

/// Configuration for the AniList integration.
///
/// AniList uses OAuth 2.0 Authorization Code grant. For a tvOS app without a
/// redirect capability, we use the "implicit" grant (`response_type=token`) which
/// shows the user a token they can enter on the TV. Only a client id is required
/// (no client secret needed for implicit grant).
public struct AniListConfig: Sendable, Equatable {
    public var clientID: String?
    public var apiBaseURL: URL
    public var authBaseURL: URL

    public init(
        clientID: String? = nil,
        apiBaseURL: URL = URL(string: "https://graphql.anilist.co")!,
        authBaseURL: URL = URL(string: "https://anilist.co")!
    ) {
        self.clientID = Self.sanitize(clientID)
        self.apiBaseURL = apiBaseURL
        self.authBaseURL = authBaseURL
    }

    /// AniList only requires a client ID for the implicit grant (no secret needed).
    public var isConfigured: Bool {
        clientID != nil
    }

    /// The authorization URL the user visits to grant access. Uses implicit grant
    /// so the token is shown directly to the user for manual entry on TV.
    public var authorizationURL: String? {
        guard let clientID else { return nil }
        return "\(authBaseURL)/api/v2/oauth/authorize?client_id=\(clientID)&response_type=token"
    }

    public static func resolved(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AniListConfig {
        let plistID = bundle.object(forInfoDictionaryKey: "AniListClientID") as? String
        return AniListConfig(
            clientID: sanitize(plistID) ?? sanitize(environment["ANILIST_CLIENT_ID"])
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
