import Foundation

// MARK: - Stored tokens

/// AniList access token (no refresh; implicit grant tokens are long-lived ~1 year).
public struct AniListTokens: Codable, Sendable, Equatable {
    public var accessToken: String

    public init(accessToken: String) {
        self.accessToken = accessToken
    }
}

// MARK: - User

/// The authenticated AniList user's profile.
public struct AniListUser: Sendable, Equatable {
    public let id: Int
    public let name: String

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }
}

// MARK: - GraphQL response wrappers

struct AniListGraphQLResponse<T: Decodable>: Decodable {
    let data: T?
    let errors: [AniListGraphQLError]?
}

struct AniListGraphQLError: Decodable {
    let message: String
    let status: Int?
}

struct AniListViewerData: Decodable {
    let Viewer: AniListViewerUser?
}

struct AniListViewerUser: Decodable {
    let id: Int
    let name: String
}

struct AniListSaveMediaListData: Decodable {
    let SaveMediaListEntry: AniListMediaListEntry?
}

struct AniListMediaListEntry: Decodable {
    let id: Int
    let status: String?
    let progress: Int?
}

/// Search result for looking up anime by external IDs.
struct AniListSearchData: Decodable {
    let Media: AniListMediaResult?
}

struct AniListMediaResult: Decodable {
    let id: Int
    let title: AniListTitle?
    let episodes: Int?
}

struct AniListTitle: Decodable {
    let romaji: String?
    let english: String?
}

// MARK: - Media list status

/// AniList media list status values.
public enum AniListMediaListStatus: String, Sendable {
    case current = "CURRENT"
    case completed = "COMPLETED"
    case paused = "PAUSED"
    case dropped = "DROPPED"
    case planning = "PLANNING"
    case repeating = "REPEATING"
}
