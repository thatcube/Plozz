import Foundation

// MARK: - Stored tokens

/// OAuth tokens persisted after a successful Simkl connection.
public struct SimklTokens: Codable, Sendable, Equatable {
    public var accessToken: String

    public init(accessToken: String) {
        self.accessToken = accessToken
    }
}

// MARK: - OAuth device-code DTOs

/// Response to `POST /oauth/device/code`.
public struct SimklDeviceCode: Decodable, Sendable, Equatable {
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

/// Response to the token exchange.
public struct SimklTokenResponse: Decodable, Sendable, Equatable {
    public let accessToken: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
    }

    public var tokens: SimklTokens {
        SimklTokens(accessToken: accessToken)
    }
}

// MARK: - User

/// Subset of Simkl user settings for display.
public struct SimklUserSettings: Decodable, Sendable, Equatable {
    public let user: User

    public struct User: Decodable, Sendable, Equatable {
        public let name: String
    }

    public var displayName: String { user.name }

    private enum CodingKeys: String, CodingKey {
        case user = "account"
    }
}

// MARK: - Scrobble DTOs

/// External ids Simkl accepts (mirrors Trakt's id namespaces).
struct SimklIDs: Encodable, Equatable {
    var simkl: Int?
    var imdb: String?
    var tmdb: Int?
    var tvdb: Int?
    var mal: Int?
    var anilist: Int?

    var isEmpty: Bool { simkl == nil && imdb == nil && tmdb == nil && tvdb == nil && mal == nil && anilist == nil }
}

struct SimklHistoryMovie: Encodable, Equatable {
    var title: String?
    var year: Int?
    var ids: SimklIDs
}

struct SimklHistoryShow: Encodable, Equatable {
    var title: String?
    var year: Int?
    var ids: SimklIDs
}

struct SimklHistoryEpisode: Encodable, Equatable {
    var ids: SimklIDs
}

/// Body for `POST /sync/history`.
struct SimklHistoryBody: Encodable, Equatable {
    var movies: [SimklHistoryMovieEntry]?
    var shows: [SimklHistoryShowEntry]?
}

struct SimklHistoryMovieEntry: Encodable, Equatable {
    var title: String?
    var year: Int?
    var ids: SimklIDs
    var watchedAt: String?

    enum CodingKeys: String, CodingKey {
        case title, year, ids
        case watchedAt = "watched_at"
    }
}

struct SimklHistoryShowEntry: Encodable, Equatable {
    var title: String?
    var year: Int?
    var ids: SimklIDs
    var seasons: [SimklSeasonEntry]

    enum CodingKeys: String, CodingKey {
        case title, year, ids, seasons
    }
}

struct SimklSeasonEntry: Encodable, Equatable {
    var number: Int
    var episodes: [SimklEpisodeEntry]
}

struct SimklEpisodeEntry: Encodable, Equatable {
    var number: Int
    var watchedAt: String?

    enum CodingKeys: String, CodingKey {
        case number
        case watchedAt = "watched_at"
    }
}
