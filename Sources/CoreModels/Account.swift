import Foundation

/// A non-secret, random identity for one immutable set of account credentials.
///
/// Connection and provider caches key by this value rather than by tokens,
/// passwords, or hashes derived from either. Replacing credentials creates a
/// new revision so state authenticated under the old material cannot be reused.
public struct CredentialRevision: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// A persisted, **non-secret** account identity.
///
/// Plozz supports multiple simultaneous accounts (one per signed-in
/// server/user). An `Account` holds only the metadata safe to write to
/// `UserDefaults`; the access **token is never a field here** — it lives in the
/// Keychain keyed by `id` (see `FeatureAuth.AccountStore`). At runtime an
/// account is paired with its resolved token to form a `UserSession`, and with
/// its provider to form a `ResolvedAccount`.
///
/// `id` is a stable, app-minted UUID (distinct from the backend's server id, so
/// the same server can host two accounts) and doubles as the Keychain key
/// suffix for the token.
public struct Account: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var server: MediaServer
    public var userID: String
    public var userName: String
    /// Provider-supplied profile image URL for this account user, when available.
    public var avatarURL: URL?
    /// Stable per-install device identifier sent on every authenticated request.
    public var deviceID: String
    /// Random identity of the Keychain credential currently active for this
    /// account. This is safe to persist and log; it contains no credential data.
    public var credentialRevision: CredentialRevision
    /// When the account was first added — used for stable ordering.
    public var addedAt: Date

    public init(
        id: String = UUID().uuidString,
        server: MediaServer,
        userID: String,
        userName: String,
        avatarURL: URL? = nil,
        deviceID: String,
        credentialRevision: CredentialRevision = CredentialRevision(),
        addedAt: Date = Date()
    ) {
        self.id = id
        self.server = server
        self.userID = userID
        self.userName = userName
        self.avatarURL = avatarURL
        self.deviceID = deviceID
        self.credentialRevision = credentialRevision
        self.addedAt = addedAt
    }

    /// Derives an `Account` identity from a freshly authenticated session.
    public init(id: String = UUID().uuidString, from session: UserSession, addedAt: Date = Date()) {
        self.init(
            id: id,
            server: session.server,
            userID: session.userID,
            userName: session.userName,
            avatarURL: session.avatarURL,
            deviceID: session.deviceID,
            credentialRevision: CredentialRevision(),
            addedAt: addedAt
        )
    }

    /// Rehydrates the runtime `UserSession` by pairing this identity with the
    /// secret `token` resolved from the Keychain.
    public func session(token: String) -> UserSession {
        UserSession(
            server: server,
            userID: userID,
            userName: userName,
            avatarURL: avatarURL,
            deviceID: deviceID,
            accessToken: token
        )
    }
}

extension Account: CustomStringConvertible {
    /// Account identities carry no secret, but keep logging terse and stable.
    public var description: String {
        "Account(id: \(id), server: \(server.name), user: \(userName))"
    }
}
