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

    init(id: Int? = nil, tmdbId: Int? = nil, status: Int? = nil, downloadStatus: [SeerDownloadingItem]? = nil) {
        self.id = id
        self.tmdbId = tmdbId
        self.status = status
        self.downloadStatus = downloadStatus
    }

    enum CodingKeys: String, CodingKey {
        case id, tmdbId, status, downloadStatus
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int.self, forKey: .id)
        tmdbId = try c.decodeIfPresent(Int.self, forKey: .tmdbId)
        status = try c.decodeIfPresent(Int.self, forKey: .status)
        downloadStatus = try c.decodeIfPresent([SeerDownloadingItem].self, forKey: .downloadStatus)
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

/// Minimal decode of `GET /api/v1/movie/{id}` and `/api/v1/tv/{id}`: only the
/// `mediaInfo` (request status + live download queue) needed to refresh a
/// discovery title's request/availability state when its detail page is
/// (re)opened — so a title requested earlier reads "Requested"/"Downloading"
/// instead of a stale "Request".
struct SeerMediaDetails: Decodable {
    var mediaInfo: SeerMediaInfo?

    init(mediaInfo: SeerMediaInfo? = nil) { self.mediaInfo = mediaInfo }

    enum CodingKeys: String, CodingKey { case mediaInfo }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mediaInfo = try c.decodeIfPresent(SeerMediaInfo.self, forKey: .mediaInfo)
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
