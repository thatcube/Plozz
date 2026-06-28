import Foundation

/// Configuration for the AniList integration.
///
/// AniList auth is handled by the plozz.app relay worker. The TV app shows
/// the relay URL and a text field for the short redeem code.
public struct AniListConfig: Sendable, Equatable {
    public var clientID: String?
    public var clientSecret: String?
    public var relayBaseURL: String
    public var apiBaseURL: URL

    public init(
        clientID: String? = nil,
        clientSecret: String? = nil,
        relayBaseURL: String = "https://plozz.app",
        apiBaseURL: URL = URL(string: "https://graphql.anilist.co")!
    ) {
        self.clientID = Self.sanitize(clientID)
        self.clientSecret = Self.sanitize(clientSecret)
        self.relayBaseURL = relayBaseURL
        self.apiBaseURL = apiBaseURL
    }

    public var isConfigured: Bool {
        clientID != nil
    }

    /// The relay auth URL the user visits (QR code target).
    public var authorizationURL: String? {
        guard clientID != nil else { return nil }
        return "\(relayBaseURL)/auth/anilist"
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
