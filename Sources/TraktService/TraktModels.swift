import CoreModels
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
    public var accountIdentity: String?
    /// Absolute expiry instant (createdAt + expiresIn).
    public var expiresAt: Date

    public init(
        accessToken: String,
        refreshToken: String,
        expiresAt: Date,
        accountIdentity: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.accountIdentity = accountIdentity
    }

    /// Treated as expired a few minutes early so a scrobble never races the
    /// deadline with a token the server is about to reject.
    public var isExpired: Bool {
        Date() >= expiresAt.addingTimeInterval(-300)
    }

    public var stableAccountIdentity: String {
        accountIdentity ?? WatchlistReconciliationIdentity.credential(
            refreshToken.isEmpty ? accessToken : refreshToken
        )
    }

    public func inheritingAccountIdentity(from previous: Self) -> Self {
        var value = self
        value.accountIdentity = previous.stableAccountIdentity
        return value
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

    /// Prefer the username over the display name.
    public var displayName: String {
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
    var title: String?  // l10n:content — media title sent to Trakt, sourced from our own item metadata
    var year: Int?
    var ids: TraktIDs
}

struct TraktShowRef: Encodable, Equatable {
    var title: String?  // l10n:content — media title sent to Trakt, sourced from our own item metadata
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

// MARK: - Watchlist DTOs

public struct TraktWatchlistIDs: Codable, Hashable, Sendable {
    public var trakt: Int?
    public var imdb: String?
    public var tmdb: Int?
    public var tvdb: Int?

    public init(
        trakt: Int? = nil,
        imdb: String? = nil,
        tmdb: Int? = nil,
        tvdb: Int? = nil
    ) {
        self.trakt = trakt
        self.imdb = imdb
        self.tmdb = tmdb
        self.tvdb = tvdb
    }

    public var isEmpty: Bool {
        trakt == nil && imdb == nil && tmdb == nil && tvdb == nil
    }
}

public struct TraktWatchlistTitle: Codable, Hashable, Sendable {
    public var title: String?   // l10n:content — provider-supplied media title
    public var year: Int?
    public var ids: TraktWatchlistIDs

    public init(
        title: String? = nil,   // l10n:content — provider-supplied media title
        year: Int? = nil,
        ids: TraktWatchlistIDs
    ) {
        self.title = title
        self.year = year
        self.ids = ids
    }
}

struct TraktWatchlistMovieEntry: Decodable, Sendable {
    let id: Int
    let listedAt: String
    let movie: TraktWatchlistTitle

    enum CodingKeys: String, CodingKey {
        case id
        case listedAt = "listed_at"
        case movie
    }
}

struct TraktWatchlistShowEntry: Decodable, Sendable {
    let id: Int
    let listedAt: String
    let show: TraktWatchlistTitle

    enum CodingKeys: String, CodingKey {
        case id
        case listedAt = "listed_at"
        case show
    }
}

struct TraktWatchlistItem: Sendable {
    let id: Int
    let listedAt: Date
    let kind: MediaItemKind
    let title: TraktWatchlistTitle
    let providerOrder: Int
}

struct TraktWatchlistMutationBody: Encodable, Sendable {
    var movies: [TraktWatchlistTitle]?
    var shows: [TraktWatchlistTitle]?
}
