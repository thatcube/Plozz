import Foundation

/// An authenticated session against a `MediaServer`.
///
/// The `accessToken` is **never** persisted in plaintext — `SessionStore`
/// keeps it in the Keychain and only the non-secret metadata is written to
/// `UserDefaults`. See `FeatureAuth.SessionStore`.
public struct UserSession: Codable, Hashable, Sendable {
    public var server: MediaServer
    public var userID: String
    public var userName: String
    /// Provider-supplied profile image URL for this account user, when available.
    public var avatarURL: URL?
    /// Stable per-install device identifier sent on every authenticated request.
    public var deviceID: String
    /// Secret bearer token. Treat as sensitive; do not log.
    public var accessToken: String

    public init(
        server: MediaServer,
        userID: String,
        userName: String,
        avatarURL: URL? = nil,
        deviceID: String,
        accessToken: String
    ) {
        self.server = server
        self.userID = userID
        self.userName = userName
        self.avatarURL = avatarURL
        self.deviceID = deviceID
        self.accessToken = accessToken
    }
}

extension UserSession: CustomStringConvertible {
    /// Redacts the access token so a session can be logged safely.
    public var description: String {
        "UserSession(server: \(server.name), user: \(userName), token: <redacted>)"
    }
}
