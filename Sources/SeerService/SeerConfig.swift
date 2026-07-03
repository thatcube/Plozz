import Foundation

/// Connection details for a Seerr (Overseerr / Jellyseerr) instance.
///
/// Unlike the OAuth trackers, Seerr is a **self-hosted** service, so its config
/// is *user-supplied at runtime* (server URL + admin API key) rather than baked
/// into the build. The values are persisted per-profile in the Keychain (see
/// ``SeerCredentialStore``); this struct is the in-memory, decoded view the
/// service and client operate on.
///
/// Phase 1 auth is the **admin API key** sent as `X-Api-Key`. An optional
/// `userId` (sent as `X-API-User`) lets requests be attributed to a specific
/// Seerr user instead of the admin (user id 1); it's off by default.
public struct SeerConfig: Sendable, Equatable {
    /// Base URL of the Seerr server, e.g. `https://requests.example.com`. The
    /// `/api/v1` path is appended by the client, so this is the bare origin
    /// (optionally with a reverse-proxy base path).
    public var baseURL: URL?
    /// The admin API key from Seerr → Settings → General.
    public var apiKey: String?
    /// Optional Seerr user id to act on behalf of (`X-API-User`). `nil` acts as
    /// the admin (user 1).
    public var userId: Int?

    public init(baseURL: URL? = nil, apiKey: String? = nil, userId: Int? = nil) {
        self.baseURL = baseURL
        self.apiKey = Self.sanitize(apiKey)
        self.userId = userId
    }

    /// Whether both a server URL and an API key resolved, so the feature can run.
    public var isConfigured: Bool {
        baseURL != nil && apiKey != nil
    }

    /// Normalizes a raw API key: trims whitespace, rejects empty strings.
    private static func sanitize(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    /// Parses a user-entered server string into a normalized base `URL`.
    ///
    /// Accepts bare hosts (`requests.example.com`), hosts with a port or path,
    /// and full URLs. Defaults the scheme to `https` when omitted and strips any
    /// trailing slash so path joining in the client stays predictable. Returns
    /// `nil` for input that can't form a host-bearing URL.
    public static func normalizedBaseURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: withScheme),
              let host = components.host, !host.isEmpty
        else { return nil }
        // Drop a trailing slash on the path so `baseURL + "/api/v1/..."` never
        // doubles up separators.
        if components.path.hasSuffix("/") {
            components.path = String(components.path.dropLast())
        }
        return components.url
    }
}
