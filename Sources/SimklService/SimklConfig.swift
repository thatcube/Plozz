import Foundation

/// Configuration for the Simkl integration.
///
/// Like Trakt, Simkl OAuth requires a registered application's **client id** and
/// **client secret**. Read from Info.plist (`SimklClientID` / `SimklClientSecret`,
/// substituted from build settings in the gitignored `Config/Secrets.local.xcconfig`),
/// falling back to the process environment.
public struct SimklConfig: Sendable, Equatable {
    public var clientID: String?
    public var clientSecret: String?
    public var apiBaseURL: URL

    public init(
        clientID: String? = nil,
        clientSecret: String? = nil,
        apiBaseURL: URL = URL(string: "https://api.simkl.com")!
    ) {
        self.clientID = Self.sanitize(clientID)
        self.clientSecret = Self.sanitize(clientSecret)
        self.apiBaseURL = apiBaseURL
    }

    /// PIN flow only requires clientID — no secret needed.
    public var isConfigured: Bool {
        clientID != nil
    }

    public static func resolved(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SimklConfig {
        let plistID = bundle.object(forInfoDictionaryKey: "SimklClientID") as? String
        let plistSecret = bundle.object(forInfoDictionaryKey: "SimklClientSecret") as? String
        return SimklConfig(
            clientID: sanitize(plistID) ?? sanitize(environment["SIMKL_CLIENT_ID"]),
            clientSecret: sanitize(plistSecret) ?? sanitize(environment["SIMKL_CLIENT_SECRET"])
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
