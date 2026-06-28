import Foundation

/// Configuration for the MyAnimeList integration.
///
/// MAL supports OAuth 2.0 authorization code with PKCE for public clients. TV
/// clients can show the authorization URL as text/QR and let the user type the
/// returned short code on another device.
public struct MALConfig: Sendable, Equatable {
    public var clientID: String?
    public var redirectURI: String
    public var apiBaseURL: URL
    public var authBaseURL: URL

    public init(
        clientID: String? = nil,
        redirectURI: String = "http://localhost",
        apiBaseURL: URL = URL(string: "https://api.myanimelist.net/v2")!,
        authBaseURL: URL = URL(string: "https://myanimelist.net")!
    ) {
        self.clientID = Self.sanitize(clientID)
        self.redirectURI = Self.sanitize(redirectURI) ?? "http://localhost"
        self.apiBaseURL = apiBaseURL
        self.authBaseURL = authBaseURL
    }

    /// MAL only requires a client ID for PKCE in public TV/mobile apps.
    public var isConfigured: Bool {
        clientID != nil
    }

    public static func resolved(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> MALConfig {
        let plistID = bundle.object(forInfoDictionaryKey: "MALClientID") as? String
        let plistRedirectURI = bundle.object(forInfoDictionaryKey: "MALRedirectURI") as? String
        return MALConfig(
            clientID: sanitize(plistID) ?? sanitize(environment["MAL_CLIENT_ID"]),
            redirectURI: sanitize(plistRedirectURI) ?? sanitize(environment["MAL_REDIRECT_URI"]) ?? "http://localhost"
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
