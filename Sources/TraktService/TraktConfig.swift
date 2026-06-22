import Foundation

/// Configuration for the Trakt integration.
///
/// Trakt OAuth requires a registered application's **client id** and **client
/// secret**. These are read from configuration only and are **never committed**:
/// the app supplies them via Info.plist (`TraktClientID` / `TraktClientSecret`,
/// substituted from the `TRAKT_CLIENT_ID` / `TRAKT_CLIENT_SECRET` build settings
/// in the gitignored `Config/Secrets.local.xcconfig`), falling back to the
/// process environment for `swift test` / CI / local runs.
///
/// When the credentials don't resolve, Trakt sync is disabled: the Settings
/// panel shows an "unavailable" state and scrobbling becomes a no-op.
public struct TraktConfig: Sendable, Equatable {
    /// Trakt application client id (also sent as the `trakt-api-key` header).
    public var clientID: String?
    /// Trakt application client secret (used only for the OAuth token exchange).
    public var clientSecret: String?
    /// Trakt API base URL.
    public var apiBaseURL: URL

    public init(
        clientID: String? = nil,
        clientSecret: String? = nil,
        apiBaseURL: URL = URL(string: "https://api.trakt.tv")!
    ) {
        self.clientID = Self.sanitize(clientID)
        self.clientSecret = Self.sanitize(clientSecret)
        self.apiBaseURL = apiBaseURL
    }

    /// Whether both credentials resolved, so the feature can be offered.
    public var isConfigured: Bool {
        clientID != nil && clientSecret != nil
    }

    /// Resolves configuration from the app bundle's Info.plist, falling back to
    /// process-environment variables (handy for tests/CI and local runs).
    public static func resolved(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TraktConfig {
        let plistID = bundle.object(forInfoDictionaryKey: "TraktClientID") as? String
        let plistSecret = bundle.object(forInfoDictionaryKey: "TraktClientSecret") as? String
        return TraktConfig(
            clientID: sanitize(plistID) ?? sanitize(environment["TRAKT_CLIENT_ID"]),
            clientSecret: sanitize(plistSecret) ?? sanitize(environment["TRAKT_CLIENT_SECRET"])
        )
    }

    /// Normalizes a raw value: trims whitespace and rejects empty strings and the
    /// unsubstituted build-setting placeholder (`$(TRAKT_CLIENT_ID)`).
    private static func sanitize(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !trimmed.contains("$(")
        else { return nil }
        return trimmed
    }
}
