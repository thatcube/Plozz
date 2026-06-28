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

// MARK: - OAuth device-code DTOs

/// Response to `POST /v1/oauth2/device/code` (MAL's device authorization endpoint).
public struct MALDeviceCode: Sendable, Equatable {
    public let deviceCode: String
    public let userCode: String
    public let verificationURL: String
    public let expiresIn: TimeInterval
    public let interval: TimeInterval

    public init(deviceCode: String, userCode: String, verificationURL: String, expiresIn: TimeInterval, interval: TimeInterval) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURL = verificationURL
        self.expiresIn = expiresIn
        self.interval = interval
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

// MARK: - Anime list status

/// MAL anime watching status values.
public enum MALAnimeStatus: String, Sendable {
    case watching
    case completed
    case onHold = "on_hold"
    case dropped
    case planToWatch = "plan_to_watch"
}
