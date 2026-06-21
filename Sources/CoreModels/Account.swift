import Foundation

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
    /// Stable per-install device identifier sent on every authenticated request.
    public var deviceID: String
    /// When the account was first added — used for stable ordering.
    public var addedAt: Date

    public init(
        id: String = UUID().uuidString,
        server: MediaServer,
        userID: String,
        userName: String,
        deviceID: String,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.server = server
        self.userID = userID
        self.userName = userName
        self.deviceID = deviceID
        self.addedAt = addedAt
    }

    /// Derives an `Account` identity from a freshly authenticated session.
    public init(id: String = UUID().uuidString, from session: UserSession, addedAt: Date = Date()) {
        self.init(
            id: id,
            server: session.server,
            userID: session.userID,
            userName: session.userName,
            deviceID: session.deviceID,
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
