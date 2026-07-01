import Foundation

// MARK: - Stored session

/// Persisted after a successful Last.fm connection. The session key never
/// expires (Last.fm ties it to the API account + user until revoked), so there is
/// no refresh token — the key alone authenticates every scrobble.
public struct LastFmTokens: Codable, Sendable, Equatable {
    public var sessionKey: String
    public var username: String

    public init(sessionKey: String, username: String) {
        self.sessionKey = sessionKey
        self.username = username
    }
}

// MARK: - Auth DTOs

/// Response to `auth.getToken` — an unauthorized request token the user then
/// approves on the web.
struct LastFmTokenResponse: Decodable, Equatable {
    let token: String
}

/// Response to `auth.getSession` — the durable session key + the account name.
struct LastFmSessionResponse: Decodable, Equatable {
    let session: Session

    struct Session: Decodable, Equatable {
        let name: String
        let key: String
    }
}

// MARK: - Errors

/// A Last.fm API error envelope (`{ "error": 14, "message": "…" }`). Last.fm
/// returns these both as HTTP 200 bodies and behind 403 responses.
public struct LastFmAPIError: Error, Equatable {
    public let code: Int
    public let message: String

    /// The request token has not yet been authorized by the user — keep polling.
    public var isPendingAuthorization: Bool { code == 14 }
    /// The request token has expired — a fresh `auth.getToken` is required.
    public var isTokenExpired: Bool { code == 4 || code == 15 }
}
