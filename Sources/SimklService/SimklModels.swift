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

/// Response to `GET /oauth/pin?client_id=...`.
public struct SimklDeviceCode: Decodable, Sendable, Equatable {
    public let userCode: String
    public let verificationURL: String
    public let expiresIn: TimeInterval
    public let interval: TimeInterval

    enum CodingKeys: String, CodingKey {
        case userCode = "user_code"
        case verificationURL = "verification_url"
        case expiresIn = "expires_in"
        case interval
    }
}

// MARK: - User

/// Subset of Simkl user settings for display.
public struct SimklUserSettings: Decodable, Sendable, Equatable {
    public let account: Account

    public struct Account: Decodable, Sendable, Equatable {
        public let id: Int?
    }

    public let user: User

    public struct User: Decodable, Sendable, Equatable {
        public let name: String
    }

    /// The actual username from the API.
    public var displayName: String { user.name }
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

// MARK: - Real-time scrobble DTOs (POST /scrobble/{start,pause,stop})

/// Body for `POST /scrobble/{start,pause,stop}`.
struct SimklScrobbleBody: Encodable, Equatable {
    var movie: SimklScrobbleMovieRef?
    var show: SimklScrobbleShowRef?
    var episode: SimklScrobbleEpisodeRef?
    var progress: Double
}

struct SimklScrobbleMovieRef: Encodable, Equatable {
    var title: String?
    var year: Int?
    var ids: SimklIDs
}

struct SimklScrobbleShowRef: Encodable, Equatable {
    var title: String?
    var year: Int?
    var ids: SimklIDs
}

struct SimklScrobbleEpisodeRef: Encodable, Equatable {
    var season: Int?
    var number: Int?
}
