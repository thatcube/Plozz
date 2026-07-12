import Foundation

// MARK: - Discovery / Search

/// A page of discover/search results from Seerr. All the discovery endpoints
/// (`/discover/trending`, `/discover/movies`, `/discover/tv`, `/search`) share
/// this envelope.
struct SeerDiscoverPage: Decodable {
    var page: Int
    var totalPages: Int
    var totalResults: Int
    var results: [SeerDiscoverResult]
}

/// One discover/search result. Seerr returns a heterogeneous array of movies,
/// TV shows, and people discriminated by `mediaType`; this DTO decodes all of
/// them leniently (everything optional but `id`/`mediaType`) and the mapping
/// layer filters out `person` entries. Movies carry `title`/`releaseDate`; TV
/// carries `name`/`firstAirDate`.
struct SeerDiscoverResult: Decodable {
    var id: Int
    var mediaType: String
    var title: String?
    var name: String?
    var originalTitle: String?
    var originalName: String?
    var overview: String?
    var posterPath: String?
    var backdropPath: String?
    var releaseDate: String?
    var firstAirDate: String?
    var mediaInfo: SeerMediaInfo?

    enum CodingKeys: String, CodingKey {
        case id, mediaType, title, name, originalTitle, originalName
        case overview, posterPath, backdropPath, releaseDate, firstAirDate, mediaInfo
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        mediaType = try c.decodeIfPresent(String.self, forKey: .mediaType) ?? "movie"
        title = try c.decodeIfPresent(String.self, forKey: .title)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        originalTitle = try c.decodeIfPresent(String.self, forKey: .originalTitle)
        originalName = try c.decodeIfPresent(String.self, forKey: .originalName)
        overview = try c.decodeIfPresent(String.self, forKey: .overview)
        posterPath = try c.decodeIfPresent(String.self, forKey: .posterPath)
        backdropPath = try c.decodeIfPresent(String.self, forKey: .backdropPath)
        releaseDate = try c.decodeIfPresent(String.self, forKey: .releaseDate)
        firstAirDate = try c.decodeIfPresent(String.self, forKey: .firstAirDate)
        mediaInfo = try c.decodeIfPresent(SeerMediaInfo.self, forKey: .mediaInfo)
    }

    /// Test/mapping convenience initializer (no decoding).
    init(
        id: Int,
        mediaType: String,
        title: String? = nil,
        name: String? = nil,
        originalTitle: String? = nil,
        originalName: String? = nil,
        overview: String? = nil,
        posterPath: String? = nil,
        backdropPath: String? = nil,
        releaseDate: String? = nil,
        firstAirDate: String? = nil,
        mediaInfo: SeerMediaInfo? = nil
    ) {
        self.id = id
        self.mediaType = mediaType
        self.title = title
        self.name = name
        self.originalTitle = originalTitle
        self.originalName = originalName
        self.overview = overview
        self.posterPath = posterPath
        self.backdropPath = backdropPath
        self.releaseDate = releaseDate
        self.firstAirDate = firstAirDate
        self.mediaInfo = mediaInfo
    }
}

/// Seerr's per-title tracking record. `status` is the `MediaStatus` enum
/// (1=UNKNOWN … 6=DELETED). Absent `mediaInfo` on a result means the title is
/// untracked (treat as UNKNOWN). `downloadStatus` carries the live Radarr/Sonarr
/// queue items (present on discover/search results too — Overseerr populates it
/// via an `@AfterLoad` hook), letting us surface real download progress.
struct SeerMediaInfo: Decodable {
    var id: Int?
    var tmdbId: Int?
    var status: Int?
    var downloadStatus: [SeerDownloadingItem]?
    var seasons: [SeerMediaSeason]?
    var requests: [SeerMediaRequest]?

    init(
        id: Int? = nil,
        tmdbId: Int? = nil,
        status: Int? = nil,
        downloadStatus: [SeerDownloadingItem]? = nil,
        seasons: [SeerMediaSeason]? = nil,
        requests: [SeerMediaRequest]? = nil
    ) {
        self.id = id
        self.tmdbId = tmdbId
        self.status = status
        self.downloadStatus = downloadStatus
        self.seasons = seasons
        self.requests = requests
    }

    enum CodingKeys: String, CodingKey {
        case id, tmdbId, status, downloadStatus, seasons, requests
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int.self, forKey: .id)
        tmdbId = try c.decodeIfPresent(Int.self, forKey: .tmdbId)
        status = try c.decodeIfPresent(Int.self, forKey: .status)
        downloadStatus = try c.decodeIfPresent([SeerDownloadingItem].self, forKey: .downloadStatus)
        seasons = try c.decodeIfPresent([SeerMediaSeason].self, forKey: .seasons)
        requests = try c.decodeIfPresent([SeerMediaRequest].self, forKey: .requests)
    }
}

/// One season tracked by Seerr for a series. Seasons absent from this array are
/// untracked and therefore requestable when they exist in the TMDB season list.
struct SeerMediaSeason: Decodable {
    var seasonNumber: Int
    var status: Int?

    init(seasonNumber: Int, status: Int? = nil) {
        self.seasonNumber = seasonNumber
        self.status = status
    }
}

/// A TV request attached to `mediaInfo`. Active requests must be reconciled
/// separately from availability-scanner seasons or pending seasons look missing.
struct SeerMediaRequest: Decodable {
    var status: Int?
    var is4k: Bool?
    var seasons: [SeerRequestedSeason]

    init(status: Int? = nil, is4k: Bool? = nil, seasons: [SeerRequestedSeason] = []) {
        self.status = status
        self.is4k = is4k
        self.seasons = seasons
    }

    enum CodingKeys: String, CodingKey { case status, is4k, seasons }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decodeIfPresent(Int.self, forKey: .status)
        is4k = try c.decodeIfPresent(Bool.self, forKey: .is4k)
        seasons = try c.decodeIfPresent([SeerRequestedSeason].self, forKey: .seasons) ?? []
    }
}

struct SeerRequestedSeason: Decodable {
    var seasonNumber: Int
    var status: Int?

    init(seasonNumber: Int, status: Int? = nil) {
        self.seasonNumber = seasonNumber
        self.status = status
    }
}

/// One in-flight download from the Radarr/Sonarr queue, as surfaced by Seerr on a
/// title's `mediaInfo.downloadStatus`. `size`/`sizeLeft` are bytes; the fetched
/// fraction is `(size - sizeLeft) / size`. Everything is optional/lenient so a
/// partial or evolving Seerr payload never fails the whole discover decode.
struct SeerDownloadingItem: Decodable {
    var size: Double?
    var sizeLeft: Double?
    var status: String?

    init(size: Double? = nil, sizeLeft: Double? = nil, status: String? = nil) {
        self.size = size
        self.sizeLeft = sizeLeft
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case size, sizeLeft, status
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        size = try c.decodeIfPresent(Double.self, forKey: .size)
        sizeLeft = try c.decodeIfPresent(Double.self, forKey: .sizeLeft)
        status = try c.decodeIfPresent(String.self, forKey: .status)
    }
}

// MARK: - Status

/// `GET /api/v1/status` — a lightweight, admin-free health/version probe used to
/// validate connectivity when the user taps Connect/Test.
struct SeerStatus: Decodable {
    var version: String?
    var commitTag: String?
}

/// Minimal decode of `GET /api/v1/movie/{id}` and `/api/v1/tv/{id}`. TV details
/// include the complete TMDB season list while `mediaInfo.seasons` carries the
/// subset Seerr currently tracks.
struct SeerMediaDetails: Decodable {
    var mediaInfo: SeerMediaInfo?
    var seasons: [SeerSeasonSummary]

    init(mediaInfo: SeerMediaInfo? = nil, seasons: [SeerSeasonSummary] = []) {
        self.mediaInfo = mediaInfo
        self.seasons = seasons
    }

    enum CodingKeys: String, CodingKey { case mediaInfo, seasons }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mediaInfo = try c.decodeIfPresent(SeerMediaInfo.self, forKey: .mediaInfo)
        seasons = try c.decodeIfPresent([SeerSeasonSummary].self, forKey: .seasons) ?? []
    }
}

struct SeerSeasonSummary: Decodable {
    var name: String?
    var seasonNumber: Int

    init(name: String? = nil, seasonNumber: Int) {
        self.name = name
        self.seasonNumber = seasonNumber
    }
}

// MARK: - Radarr / Sonarr service defaults

/// One configured Radarr/Sonarr server from `GET /api/v1/service/{radarr|sonarr}`.
/// The default server's `id`/`activeProfileId`/`activeDirectory` seed a one-tap
/// request body (Seerr does not auto-apply them when omitted).
struct SeerServiceServer: Decodable {
    var id: Int
    var name: String?
    var is4k: Bool?
    var isDefault: Bool?
    var activeDirectory: String?
    var activeProfileId: Int?
    var activeLanguageProfileId: Int?

    init(
        id: Int,
        name: String? = nil,
        is4k: Bool? = nil,
        isDefault: Bool? = nil,
        activeDirectory: String? = nil,
        activeProfileId: Int? = nil,
        activeLanguageProfileId: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.is4k = is4k
        self.isDefault = isDefault
        self.activeDirectory = activeDirectory
        self.activeProfileId = activeProfileId
        self.activeLanguageProfileId = activeLanguageProfileId
    }
}

// MARK: - Requests

/// The seasons selector for a TV request: either an explicit list or Seerr's
/// server-side "all numbered seasons" shorthand.
enum SeerSeasons: Encodable {
    case all
    case list([Int])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .all:
            try container.encode("all")
        case let .list(numbers):
            try container.encode(numbers)
        }
    }
}

/// Body for `POST /api/v1/request`. `serverId`/`profileId`/`rootFolder` are the
/// resolved default Radarr/Sonarr values (Seerr won't apply defaults itself when
/// they're omitted).
struct SeerRequestBody: Encodable {
    var mediaType: String
    var mediaId: Int
    var seasons: SeerSeasons?
    var is4k: Bool?
    var serverId: Int?
    var profileId: Int?
    var rootFolder: String?
    var languageProfileId: Int?
}

/// Minimal decode of the `POST /api/v1/request` result — enough to reflect the
/// title's new availability back onto the UI.
struct SeerRequestResponse: Decodable {
    var id: Int?
    var media: SeerMediaInfo?
}

// MARK: - Users (request-as / per-user requests)

/// A page of Seerr users from `GET /api/v1/user`.
struct SeerUserPage: Decodable {
    var pageInfo: SeerPageInfo?
    var results: [SeerUserDTO]

    init(pageInfo: SeerPageInfo? = nil, results: [SeerUserDTO] = []) {
        self.pageInfo = pageInfo
        self.results = results
    }

    enum CodingKeys: String, CodingKey { case pageInfo, results }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pageInfo = try c.decodeIfPresent(SeerPageInfo.self, forKey: .pageInfo)
        results = try c.decodeIfPresent([SeerUserDTO].self, forKey: .results) ?? []
    }
}

/// Overseerr/Jellyseerr pagination envelope (`pageInfo`), used to page the user
/// list. Everything optional/lenient so a partial payload never fails the decode.
struct SeerPageInfo: Decodable {
    var pages: Int?
    var page: Int?
    var results: Int?

    init(pages: Int? = nil, page: Int? = nil, results: Int? = nil) {
        self.pages = pages
        self.page = page
        self.results = results
    }

    enum CodingKeys: String, CodingKey { case pages, page, results }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pages = try c.decodeIfPresent(Int.self, forKey: .pages)
        page = try c.decodeIfPresent(Int.self, forKey: .page)
        results = try c.decodeIfPresent(Int.self, forKey: .results)
    }
}

/// One Seerr user as returned by `GET /api/v1/user`. Overseerr computes a
/// `displayName`; the various `*username` fields are fallbacks. Lenient decode —
/// only `id` is required.
struct SeerUserDTO: Decodable {
    var id: Int
    var displayName: String?
    var username: String?
    var plexUsername: String?
    var jellyfinUsername: String?
    var email: String?
    var avatar: String?

    init(
        id: Int,
        displayName: String? = nil,
        username: String? = nil,
        plexUsername: String? = nil,
        jellyfinUsername: String? = nil,
        email: String? = nil,
        avatar: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.username = username
        self.plexUsername = plexUsername
        self.jellyfinUsername = jellyfinUsername
        self.email = email
        self.avatar = avatar
    }

    enum CodingKeys: String, CodingKey {
        case id, displayName, username, plexUsername, jellyfinUsername, email, avatar
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        username = try c.decodeIfPresent(String.self, forKey: .username)
        plexUsername = try c.decodeIfPresent(String.self, forKey: .plexUsername)
        jellyfinUsername = try c.decodeIfPresent(String.self, forKey: .jellyfinUsername)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        avatar = try c.decodeIfPresent(String.self, forKey: .avatar)
    }
}

/// Overseerr's JSON error envelope (`{ "message": "..." }`), decoded from a
/// non-2xx request response so we can turn it into a specific ``SeerRequestFailure``.
struct SeerErrorBody: Decodable {
    var message: String?

    enum CodingKeys: String, CodingKey { case message }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        message = try c.decodeIfPresent(String.self, forKey: .message)
    }
}
