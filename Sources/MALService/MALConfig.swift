import Foundation

/// Configuration for the MyAnimeList integration.
///
/// MAL uses OAuth 2.0 with device-code grant (like Trakt). Requires a registered
/// application's client id. MAL's device code flow does NOT require a client secret
/// for public apps (mobile/TV), only the client ID.
public struct MALConfig: Sendable, Equatable {
    public var clientID: String?
    public var apiBaseURL: URL
    public var authBaseURL: URL

    public init(
        clientID: String? = nil,
        apiBaseURL: URL = URL(string: "https://api.myanimelist.net/v2")!,
        authBaseURL: URL = URL(string: "https://myanimelist.net")!
    ) {
        self.clientID = Self.sanitize(clientID)
        self.apiBaseURL = apiBaseURL
        self.authBaseURL = authBaseURL
    }

    /// MAL only requires a client ID for the device-code flow.
    public var isConfigured: Bool {
        clientID != nil
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
