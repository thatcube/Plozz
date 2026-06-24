import Foundation

// MARK: - Stored tokens

/// The OAuth tokens persisted after a successful Trakt connection.
///
/// Trakt access tokens are long-lived (currently ~3 months) but do expire, so
/// the refresh token is kept to silently renew them. `createdAt` + `expiresIn`
/// derive the absolute expiry used to decide when to refresh.
public struct TraktTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    /// Absolute expiry instant (createdAt + expiresIn).
    public var expiresAt: Date

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    /// Treated as expired a few minutes early so a scrobble never races the
    /// deadline with a token the server is about to reject.
    public var isExpired: Bool {
        Date() >= expiresAt.addingTimeInterval(-300)
    }
}

// MARK: - OAuth device-code DTOs

/// Response to `POST /oauth/device/code`: the code the user types plus polling
/// parameters.
public struct TraktDeviceCode: Decodable, Sendable, Equatable {
    public let deviceCode: String
    public let userCode: String
    public let verificationURL: String
    public let expiresIn: TimeInterval
    public let interval: TimeInterval

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURL = "verification_url"
        case expiresIn = "expires_in"
        case interval
    }
}

/// Response to the token endpoints (`/oauth/device/token`, `/oauth/token`).
public struct TraktTokenResponse: Decodable, Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresIn: TimeInterval
    public let createdAt: TimeInterval

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case createdAt = "created_at"
    }

    /// Converts the response into the persisted token shape.
    public var tokens: TraktTokens {
        TraktTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date(timeIntervalSince1970: createdAt).addingTimeInterval(expiresIn)
        )
    }
}

// MARK: - User

/// Subset of `GET /users/settings` we use to show who's connected.
public struct TraktUserSettings: Decodable, Sendable, Equatable {
    public let user: User

    public struct User: Decodable, Sendable, Equatable {
        public let username: String
        public let name: String?
    }

    /// A friendly display name, falling back to the username.
    public var displayName: String {
        if let name = user.name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            return name
        }
        return user.username
    }
}

// MARK: - Scrobble DTOs

/// External database ids for a movie/show/episode, as Trakt expects them.
/// Only the ids we can resolve are sent; the rest stay `nil` and are omitted.
struct TraktIDs: Encodable, Equatable {
    var trakt: Int?
    var imdb: String?
    var tmdb: Int?
    var tvdb: Int?

    var isEmpty: Bool { trakt == nil && imdb == nil && tmdb == nil && tvdb == nil }
}

struct TraktMovieRef: Encodable, Equatable {
    var title: String?
    var year: Int?
    var ids: TraktIDs
}

struct TraktShowRef: Encodable, Equatable {
    var title: String?
    var year: Int?
    var ids: TraktIDs
}

struct TraktEpisodeRef: Encodable, Equatable {
    var season: Int?
    var number: Int?
    var ids: TraktIDs
}

/// Body for `POST /scrobble/{start,pause,stop}`.
struct TraktScrobbleBody: Encodable, Equatable {
    var movie: TraktMovieRef?
    var show: TraktShowRef?
    var episode: TraktEpisodeRef?
    /// Watched percentage, 0...100.
    var progress: Double
}
