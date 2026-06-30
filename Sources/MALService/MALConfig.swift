import Foundation

/// Configuration for the MyAnimeList integration.
///
/// MAL auth is handled by the plozz.app relay. The TV app just shows
/// the relay URL and a text field for the short redeem code.
public struct MALConfig: Sendable, Equatable {
    public var clientID: String?
    public var relayBaseURL: String
    public var apiBaseURL: URL
    public var authBaseURL: URL

    public init(
        clientID: String? = nil,
        relayBaseURL: String = "https://plozz.app",
        apiBaseURL: URL = URL(string: "https://api.myanimelist.net/v2")!,
        authBaseURL: URL = URL(string: "https://myanimelist.net")!
    ) {
        self.clientID = Self.sanitize(clientID)
        self.relayBaseURL = relayBaseURL
        self.apiBaseURL = apiBaseURL
        self.authBaseURL = authBaseURL
    }

    /// MAL only requires a client ID.
    public var isConfigured: Bool {
        clientID != nil
    }

    /// Redirect URI used by the relay for OAuth callbacks.
    public var redirectURI: String {
        "\(relayBaseURL)/auth/mal/callback"
    }

    public static func resolved(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> MALConfig {
        let plistID = bundle.object(forInfoDictionaryKey: "MALClientID") as? String
        return MALConfig(
            clientID: sanitize(plistID) ?? sanitize(environment["MAL_CLIENT_ID"])
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
