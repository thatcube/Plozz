import Foundation

// MARK: - Stored tokens

/// OAuth tokens persisted after a successful MAL connection.
public struct MALTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    /// Expired with a 5-minute early margin.
    public var isExpired: Bool {
        Date() >= expiresAt.addingTimeInterval(-300)
    }
}

// MARK: - OAuth authorization-code DTOs

/// State needed to complete a PKCE authorization-code flow.
public struct MALAuthorizationRequest: Sendable, Equatable {
    public let authorizationURL: String
    public let codeVerifier: String
    public let redirectURI: String

    public init(authorizationURL: String, codeVerifier: String, redirectURI: String) {
        self.authorizationURL = authorizationURL
        self.codeVerifier = codeVerifier
        self.redirectURI = redirectURI
    }
}

/// Response to the token exchange.
public struct MALTokenResponse: Decodable, Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresIn: TimeInterval

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }

    public var tokens: MALTokens {
        MALTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(expiresIn)
        )
    }
}

// MARK: - User

/// Subset of MAL user info for display.
public struct MALUserInfo: Decodable, Sendable, Equatable {
    public let id: Int
    public let name: String
}

/// Minimal decode of `GET /v2/anime?q=…` for title-based id lookup.
public struct MALAnimeSearchResponse: Decodable, Sendable, Equatable {
    public struct Entry: Decodable, Sendable, Equatable {
        public struct Node: Decodable, Sendable, Equatable { public let id: Int }
        public let node: Node
    }
    public let data: [Entry]
}

// MARK: - Anime list status

/// MAL anime watching status values.
public enum MALAnimeStatus: String, Sendable {
    case watching
    case completed
    case onHold = "on_hold"
    case dropped
    case planToWatch = "plan_to_watch"
}

// MARK: - Plan-to-watch list DTOs

struct MALAnimeListSeason: Decodable, Equatable {
    var year: Int?
}

struct MALAnimeListNode: Decodable, Equatable {
    var id: Int?
    var title: String?

    enum CodingKeys: String, CodingKey {
        case id, title
        case startSeason = "start_season"
    }

    var startSeason: MALAnimeListSeason?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        startSeason = try c.decodeIfPresent(
            MALAnimeListSeason.self, forKey: .startSeason
        )
    }
}

struct MALAnimeListEntry: Decodable, Equatable {
    var node: MALAnimeListNode?
}

struct MALAnimeListResponse: Decodable, Equatable {
    var data: [MALAnimeListEntry]?
}
