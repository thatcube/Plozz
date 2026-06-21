import Foundation
import CoreModels
import CoreNetworking

/// Low-level Jellyfin REST client.
///
/// One instance is bound to a single server `baseURL` + `deviceProfile`. It is
/// used both *before* auth (system info, Quick Connect) and *after* auth (with
/// a token) for browsing/playback. It deals only in DTOs; mapping to
/// `CoreModels` happens in `JellyfinProvider`.
public struct JellyfinClient: Sendable {
    public let baseURL: URL
    public let deviceProfile: JellyfinDeviceProfile
    private let token: String?
    private let http: HTTPClient
    private let capabilityProfile: JellyfinCapabilityProfile

    public init(
        baseURL: URL,
        deviceProfile: JellyfinDeviceProfile,
        token: String? = nil,
        http: HTTPClient = URLSessionHTTPClient(),
        capabilityProfile: JellyfinCapabilityProfile = .detected()
    ) {
        self.baseURL = baseURL
        self.deviceProfile = deviceProfile
        self.token = token
        self.http = http
        self.capabilityProfile = capabilityProfile
    }

    /// Returns a copy of this client carrying an auth token.
    public func authenticated(token: String) -> JellyfinClient {
        JellyfinClient(baseURL: baseURL, deviceProfile: deviceProfile, token: token, http: http, capabilityProfile: capabilityProfile)
    }

    // MARK: Header

    private var authHeaders: [String: String] {
        ["Authorization": deviceProfile.authorizationHeaderValue(token: token)]
    }

    // MARK: System

    /// `GET /System/Info/Public` — used to validate a manual URL and read the
    /// server's identity/name. No auth required.
    public func publicSystemInfo() async throws -> MediaServer {
        let endpoint = Endpoint(path: "/System/Info/Public", headers: authHeaders)
        let info = try await http.decode(PublicSystemInfo.self, from: endpoint, baseURL: baseURL)
        return MediaServer(
            id: info.Id ?? baseURL.absoluteString,
            name: info.ServerName ?? baseURL.host ?? "Jellyfin Server",
            baseURL: baseURL,
            provider: .jellyfin,
            version: info.Version
        )
    }

    // MARK: Quick Connect

    /// `GET /QuickConnect/Enabled`.
    public func quickConnectEnabled() async throws -> Bool {
        let endpoint = Endpoint(path: "/QuickConnect/Enabled", headers: authHeaders)
        do {
            return try await http.decode(Bool.self, from: endpoint, baseURL: baseURL)
        } catch AppError.notFound {
            return false
        }
    }

    /// `POST /QuickConnect/Initiate` → secret + code.
    public func quickConnectInitiate() async throws -> QuickConnectChallenge {
        let endpoint = Endpoint(method: .post, path: "/QuickConnect/Initiate", headers: authHeaders)
        do {
            let dto = try await http.decode(QuickConnectResultDTO.self, from: endpoint, baseURL: baseURL)
            return QuickConnectChallenge(secret: dto.Secret, userCode: dto.Code, isAuthenticated: dto.Authenticated)
        } catch AppError.unauthorized {
            throw AppError.quickConnectUnavailable
        }
    }

    /// `GET /QuickConnect/Connect?secret=…` — poll for approval.
    /// Throws `.quickConnectExpired` when the server has forgotten the secret.
    public func quickConnectState(secret: String) async throws -> QuickConnectChallenge {
        let endpoint = Endpoint(
            path: "/QuickConnect/Connect",
            queryItems: [URLQueryItem(name: "secret", value: secret)],
            headers: authHeaders
        )
        do {
            let dto = try await http.decode(QuickConnectResultDTO.self, from: endpoint, baseURL: baseURL)
            return QuickConnectChallenge(secret: dto.Secret, userCode: dto.Code, isAuthenticated: dto.Authenticated)
        } catch AppError.notFound {
            throw AppError.quickConnectExpired
        }
    }

    /// `POST /Users/AuthenticateWithQuickConnect` — exchange an approved secret
    /// for an access token + user.
    public func authenticate(withSecret secret: String) async throws -> (token: String, userID: String, userName: String, serverID: String?) {
        var endpoint = Endpoint(method: .post, path: "/Users/AuthenticateWithQuickConnect", headers: authHeaders)
        endpoint = try endpoint.jsonBody(AuthenticateWithQuickConnectBody(Secret: secret))
        let dto = try await http.decode(AuthenticationResultDTO.self, from: endpoint, baseURL: baseURL)
        return (dto.AccessToken, dto.User.Id, dto.User.Name, dto.ServerId)
    }

    /// `POST /Users/AuthenticateByName` — exchange a username/password for an
    /// access token + user. Used as a lower-priority alternative to Quick
    /// Connect (and the only option when the server has Quick Connect disabled).
    /// Maps a rejected login (HTTP 401/403) to `.invalidCredentials`.
    public func authenticate(username: String, password: String) async throws -> (token: String, userID: String, userName: String, serverID: String?) {
        var endpoint = Endpoint(method: .post, path: "/Users/AuthenticateByName", headers: authHeaders)
        endpoint = try endpoint.jsonBody(AuthenticateByNameBody(Username: username, Pw: password))
        do {
            let dto = try await http.decode(AuthenticationResultDTO.self, from: endpoint, baseURL: baseURL)
            return (dto.AccessToken, dto.User.Id, dto.User.Name, dto.ServerId)
        } catch AppError.unauthorized {
            throw AppError.invalidCredentials
        }
    }

    // MARK: Items

    func userViews(userID: String) async throws -> [BaseItemDto] {
        let endpoint = Endpoint(path: "/Users/\(userID)/Views", headers: authHeaders)
        return try await http.decode(UserViewsResponse.self, from: endpoint, baseURL: baseURL).Items
    }

    func resumeItems(userID: String, limit: Int) async throws -> [BaseItemDto] {
        let endpoint = Endpoint(
            path: "/Users/\(userID)/Items/Resume",
            queryItems: [
                URLQueryItem(name: "Limit", value: String(limit)),
                URLQueryItem(name: "MediaTypes", value: "Video"),
                URLQueryItem(name: "Fields", value: "Overview,PrimaryImageAspectRatio")
            ],
            headers: authHeaders
        )
        return try await http.decode(ItemsResponse.self, from: endpoint, baseURL: baseURL).Items
    }

    func latestItems(userID: String, limit: Int) async throws -> [BaseItemDto] {
        let endpoint = Endpoint(
            path: "/Users/\(userID)/Items/Latest",
            queryItems: [
                URLQueryItem(name: "Limit", value: String(limit)),
                URLQueryItem(name: "Fields", value: "Overview")
            ],
            headers: authHeaders
        )
        // /Items/Latest returns a bare array, not an Items envelope.
        let items: [BaseItemDto] = try await http.decode([BaseItemDto].self, from: endpoint, baseURL: baseURL)
        return items
    }

    func item(userID: String, id: String) async throws -> BaseItemDto {
        let endpoint = Endpoint(
            path: "/Users/\(userID)/Items/\(id)",
            queryItems: [URLQueryItem(name: "Fields", value: "Overview,MediaStreams,MediaSources")],
            headers: authHeaders
        )
        return try await http.decode(BaseItemDto.self, from: endpoint, baseURL: baseURL)
    }

    func children(userID: String, parentID: String) async throws -> [BaseItemDto] {
        let endpoint = Endpoint(
            path: "/Users/\(userID)/Items",
            queryItems: [
                URLQueryItem(name: "ParentId", value: parentID),
                URLQueryItem(name: "SortBy", value: "SortName"),
                URLQueryItem(name: "Fields", value: "Overview")
            ],
            headers: authHeaders
        )
        return try await http.decode(ItemsResponse.self, from: endpoint, baseURL: baseURL).Items
    }

    /// One page of a container's direct children. Requests only `limit` items
    /// from `startIndex` and relies on `TotalRecordCount` so large libraries
    /// load a screenful quickly instead of fetching everything (which would
    /// time out). Non-recursive: returns the container's direct children, which
    /// is correct for flat libraries, folders, and collections.
    func items(userID: String, parentID: String, startIndex: Int, limit: Int) async throws -> ItemsResponse {
        let endpoint = Endpoint(
            path: "/Users/\(userID)/Items",
            queryItems: [
                URLQueryItem(name: "ParentId", value: parentID),
                URLQueryItem(name: "StartIndex", value: String(startIndex)),
                URLQueryItem(name: "Limit", value: String(limit)),
                URLQueryItem(name: "SortBy", value: "SortName"),
                URLQueryItem(name: "Fields", value: "Overview")
            ],
            headers: authHeaders
        )
        return try await http.decode(ItemsResponse.self, from: endpoint, baseURL: baseURL)
    }

    // MARK: Playback

    func playbackInfo(userID: String, itemID: String) async throws -> PlaybackInfoResponse {
        var endpoint = Endpoint(
            method: .post,
            path: "/Items/\(itemID)/PlaybackInfo",
            queryItems: [URLQueryItem(name: "UserId", value: userID)],
            headers: authHeaders
        )
        endpoint = try endpoint.jsonBody(PlaybackInfoBody(
            UserId: userID,
            MaxStreamingBitrate: capabilityProfile.maxStreamingBitrate,
            AutoOpenLiveStream: true,
            DeviceProfile: capabilityProfile
        ))
        return try await http.decode(PlaybackInfoResponse.self, from: endpoint, baseURL: baseURL)
    }

    func reportPlaybackProgress(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {
        let path: String
        switch event {
        case .start: path = "/Sessions/Playing"
        case .stop: path = "/Sessions/Playing/Stopped"
        default: path = "/Sessions/Playing/Progress"
        }
        var endpoint = Endpoint(method: .post, path: path, headers: authHeaders)
        endpoint = try endpoint.jsonBody(PlaybackProgressBody(
            ItemId: progress.itemID,
            PlaySessionId: progress.playSessionID,
            PositionTicks: JellyfinTicks.ticks(fromSeconds: progress.positionSeconds),
            IsPaused: progress.isPaused
        ))
        _ = try await http.send(endpoint, baseURL: baseURL)
    }

    /// Tells the server to tear down any active transcode/remux job for this
    /// play session. Harmless for direct-play sessions (no encoding exists), but
    /// essential for transcoded HLS so an ffmpeg job isn't left running on the
    /// server until it times out.
    func stopActiveEncoding(playSessionID: String) async throws {
        let endpoint = Endpoint(
            method: .delete,
            path: "/Videos/ActiveEncodings",
            queryItems: [
                URLQueryItem(name: "deviceId", value: deviceProfile.deviceID),
                URLQueryItem(name: "playSessionId", value: playSessionID)
            ],
            headers: authHeaders
        )
        _ = try await http.send(endpoint, baseURL: baseURL)
    }

    /// Builds an absolute image URL. Token is *not* required for images; the
    /// item id + image type is enough.
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? {
        let typeSegment: String
        switch kind {
        case .primary: typeSegment = "Primary"
        case .backdrop: typeSegment = "Backdrop"
        case .thumb: typeSegment = "Thumb"
        case .logo: typeSegment = "Logo"
        }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = basePath + "/Items/\(itemID)/Images/\(typeSegment)"
        if let maxWidth {
            components.queryItems = [URLQueryItem(name: "maxWidth", value: String(maxWidth))]
        }
        return components.url
    }
}

private struct PlaybackProgressBody: Encodable {
    let ItemId: String
    let PlaySessionId: String?
    let PositionTicks: Int64
    let IsPaused: Bool
}
