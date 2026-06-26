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
    /// Foreground/critical-path client with its own connection pool (see
    /// ``URLSession/plozzInteractive``) used only for the user-blocking `item()`
    /// fetch, so opening a detail page is never starved behind background
    /// enrichment traffic on the shared default pool.
    private let interactiveHTTP: HTTPClient
    private let capabilityProfile: JellyfinCapabilityProfile

    public init(
        baseURL: URL,
        deviceProfile: JellyfinDeviceProfile,
        token: String? = nil,
        http: HTTPClient = URLSessionHTTPClient(),
        interactiveHTTP: HTTPClient? = nil,
        capabilityProfile: JellyfinCapabilityProfile = .detected()
    ) {
        self.baseURL = baseURL
        self.deviceProfile = deviceProfile
        self.token = token
        self.http = http
        // Falls back to `http` when no dedicated foreground client is supplied, so
        // a test (or any caller) that injects a single stub for `http` routes the
        // `item()` fetch through it too instead of silently hitting a live session.
        // The production foreground-pool isolation is opted into explicitly by the
        // provider (see AppState), which passes a real `plozzInteractive` client.
        self.interactiveHTTP = interactiveHTTP ?? http
        self.capabilityProfile = capabilityProfile
    }

    /// Returns a copy of this client carrying an auth token.
    public func authenticated(token: String) -> JellyfinClient {
        JellyfinClient(baseURL: baseURL, deviceProfile: deviceProfile, token: token, http: http, interactiveHTTP: interactiveHTTP, capabilityProfile: capabilityProfile)
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
                URLQueryItem(name: "Fields", value: "Overview,OriginalTitle,PrimaryImageAspectRatio,ProviderIds")
            ],
            headers: authHeaders
        )
        return try await http.decode(ItemsResponse.self, from: endpoint, baseURL: baseURL).Items
    }

    /// `GET /Shows/NextUp` — the next unwatched episode for each series the user
    /// has progressed through. `/Items/Resume` only returns *in-progress* items,
    /// so on its own it misses the "you finished an episode, here's the next one"
    /// case that Plex's `/library/onDeck` already includes. Fetching NextUp lets
    /// the provider fold both classes into one Continue Watching feed, matching
    /// Plex parity.
    ///
    /// `EnableResumable=false` keeps NextUp complementary rather than overlapping:
    /// in-progress episodes already come back from `/Items/Resume`, so NextUp is
    /// scoped to the next-after-completed episode. `EnableRewatching=false` avoids
    /// resurfacing fully-watched series.
    func nextUpItems(userID: String, limit: Int) async throws -> [BaseItemDto] {
        let endpoint = Endpoint(
            path: "/Shows/NextUp",
            queryItems: [
                URLQueryItem(name: "UserId", value: userID),
                URLQueryItem(name: "Limit", value: String(limit)),
                URLQueryItem(name: "MediaTypes", value: "Video"),
                URLQueryItem(name: "EnableResumable", value: "false"),
                URLQueryItem(name: "EnableRewatching", value: "false"),
                URLQueryItem(name: "Fields", value: "Overview,PrimaryImageAspectRatio,ProviderIds")
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
                URLQueryItem(name: "Fields", value: "Overview,OriginalTitle,ProviderIds")
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
            queryItems: [URLQueryItem(name: "Fields", value: "Overview,OriginalTitle,MediaStreams,MediaSources,ProviderIds,Trickplay,Genres,People,Studios,Tags,Taglines")],
            headers: authHeaders
        )
        let result = try await interactiveHTTP.decode(BaseItemDto.self, from: endpoint, baseURL: baseURL)
        return result
    }

    func children(userID: String, parentID: String) async throws -> [BaseItemDto] {
        let endpoint = Endpoint(
            path: "/Users/\(userID)/Items",
            queryItems: [
                URLQueryItem(name: "ParentId", value: parentID),
                URLQueryItem(name: "SortBy", value: "SortName"),
                URLQueryItem(name: "Fields", value: "Overview,MediaStreams,MediaSources,Genres")
            ],
            headers: authHeaders
        )
        return try await http.decode(ItemsResponse.self, from: endpoint, baseURL: baseURL).Items
    }

    /// `GET /Users/{userId}/Items/{itemId}/LocalTrailers` — the local trailer
    /// files Jellyfin detected alongside an item. Each is a fully playable
    /// `BaseItemDto` (its own item id), so it streams through the normal
    /// playback path. Returns a bare array, not an `Items` envelope. Online
    /// (e.g. YouTube) trailers come from a separate field — see
    /// ``remoteTrailers(userID:id:)``.
    func localTrailers(userID: String, id: String) async throws -> [BaseItemDto] {
        let endpoint = Endpoint(
            path: "/Users/\(userID)/Items/\(id)/LocalTrailers",
            queryItems: [URLQueryItem(name: "Fields", value: "Overview")],
            headers: authHeaders
        )
        return try await http.decode([BaseItemDto].self, from: endpoint, baseURL: baseURL)
    }

    /// The item's online trailer links (`BaseItemDto.RemoteTrailers`) — YouTube
    /// watch URLs the server resolved from its own metadata provider. Unlike
    /// local trailers these have no server item id; the caller extracts the
    /// YouTube video id and plays it through the keyless trailer path. Returns an
    /// empty array when the server has none.
    func remoteTrailers(userID: String, id: String) async throws -> [MediaUrlDto] {
        let endpoint = Endpoint(
            path: "/Users/\(userID)/Items/\(id)",
            queryItems: [URLQueryItem(name: "Fields", value: "RemoteTrailers")],
            headers: authHeaders
        )
        return try await http.decode(BaseItemDto.self, from: endpoint, baseURL: baseURL).RemoteTrailers ?? []
    }

    /// One page of a container's items for library browsing.
    ///
    /// For typed libraries (movies/series) this uses Jellyfin's **recursive,
    /// indexed** item query (`Recursive=true` + `IncludeItemTypes`), which is the
    /// fast path the official clients use and which paginates server-side. A
    /// plain `ParentId` folder enumeration over a large library is slow enough to
    /// exceed the request timeout even with a `Limit`, because the server still
    /// walks/sorts the whole folder before applying it. For untyped containers
    /// (folders/collections) it falls back to direct, non-recursive children.
    func items(
        userID: String,
        parentID: String,
        includeItemTypes: [String],
        recursive: Bool,
        startIndex: Int,
        limit: Int,
        sort: CoreModels.SortDescriptor
    ) async throws -> ItemsResponse {
        var queryItems = [
            URLQueryItem(name: "ParentId", value: parentID),
            URLQueryItem(name: "StartIndex", value: String(startIndex)),
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "SortBy", value: Self.sortBy(for: sort.field)),
            URLQueryItem(name: "SortOrder", value: Self.sortOrder(for: sort.direction)),
            // Minimal fields keep the first-page payload small for a fast grid;
            // ProviderIds is included so the aggregated cross-server library
            // browse can collapse a title that lives on multiple servers.
            URLQueryItem(name: "Fields", value: "PrimaryImageAspectRatio,ProviderIds"),
            URLQueryItem(name: "ImageTypeLimit", value: "1"),
            URLQueryItem(name: "EnableTotalRecordCount", value: "true")
        ]
        if recursive {
            queryItems.append(URLQueryItem(name: "Recursive", value: "true"))
        }
        if !includeItemTypes.isEmpty {
            queryItems.append(URLQueryItem(name: "IncludeItemTypes", value: includeItemTypes.joined(separator: ",")))
        }
        let endpoint = Endpoint(path: "/Users/\(userID)/Items", queryItems: queryItems, headers: authHeaders)
        return try await http.decode(ItemsResponse.self, from: endpoint, baseURL: baseURL)
    }

    /// Maps a provider-agnostic `SortField` onto Jellyfin's `SortBy` key.
    static func sortBy(for field: SortField) -> String {
        switch field {
        case .name: return "SortName"
        case .dateAdded: return "DateCreated"
        case .releaseDate: return "PremiereDate"
        case .communityRating: return "CommunityRating"
        case .runtime: return "Runtime"
        case .random: return "Random"
        }
    }

    /// Maps a provider-agnostic `SortDirection` onto Jellyfin's `SortOrder` key.
    static func sortOrder(for direction: SortDirection) -> String {
        switch direction {
        case .ascending: return "Ascending"
        case .descending: return "Descending"
        }
    }

    // MARK: Search

    /// `GET /Users/{userId}/Items?searchTerm=…` — a recursive, indexed search
    /// across the user's libraries for the given playable content types.
    func searchItems(
        userID: String,
        searchTerm: String,
        includeItemTypes: [String],
        limit: Int
    ) async throws -> [BaseItemDto] {
        let endpoint = Endpoint(
            path: "/Users/\(userID)/Items",
            queryItems: [
                URLQueryItem(name: "searchTerm", value: searchTerm),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "IncludeItemTypes", value: includeItemTypes.joined(separator: ",")),
                URLQueryItem(name: "Limit", value: String(limit)),
                URLQueryItem(name: "Fields", value: "Overview,OriginalTitle,ProviderIds"),
                URLQueryItem(name: "EnableTotalRecordCount", value: "false"),
                URLQueryItem(name: "ImageTypeLimit", value: "1")
            ],
            headers: authHeaders
        )
        return try await http.decode(ItemsResponse.self, from: endpoint, baseURL: baseURL).Items
    }

    // MARK: Playback

    /// How the server should deliver a media source: let it decide (`auto`),
    /// remux the container with codecs copied (`remux` — preserves Dolby Vision),
    /// or fully transcode (`transcode`).
    enum PlaybackStreamMode: Sendable {
        case auto
        case remux
        case transcode
    }

    func playbackInfo(userID: String, itemID: String, mediaSourceID: String? = nil, mode: PlaybackStreamMode = .auto) async throws -> PlaybackInfoResponse {
        var queryItems = [URLQueryItem(name: "UserId", value: userID)]
        // Target a specific version when one was chosen; otherwise the server
        // returns every source and picks its default.
        if let mediaSourceID {
            queryItems.append(URLQueryItem(name: "MediaSourceId", value: mediaSourceID))
        }
        switch mode {
        case .auto:
            // Let the server pick: DirectPlay > DirectStream > transcode.
            break
        case .remux:
            // Disable direct play but keep direct stream: the server remuxes the
            // container to seekable fMP4 HLS while **copying** the video/audio
            // codecs (no re-encode), which preserves Dolby Vision (RPU/dvcC,
            // tagged `dvh1`). Used to route a DoVi MKV to AVPlayer for true DoVi.
            queryItems.append(URLQueryItem(name: "EnableDirectPlay", value: "false"))
            queryItems.append(URLQueryItem(name: "EnableDirectStream", value: "true"))
        case .transcode:
            // Force a full transcode: neither direct play nor direct stream. Used
            // as the player's fallback when a direct stream fails to load.
            queryItems.append(URLQueryItem(name: "EnableDirectPlay", value: "false"))
            queryItems.append(URLQueryItem(name: "EnableDirectStream", value: "false"))
        }
        var endpoint = Endpoint(
            method: .post,
            path: "/Items/\(itemID)/PlaybackInfo",
            queryItems: queryItems,
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

    /// `POST`/`DELETE /Users/{userId}/PlayedItems/{itemId}` — marks an item
    /// played (POST) or unplayed (DELETE) for the user. For a season/series id
    /// Jellyfin cascades the change to the contained episodes.
    func setItemPlayed(_ played: Bool, userID: String, itemID: String) async throws {
        let endpoint = Endpoint(
            method: played ? .post : .delete,
            path: "/Users/\(userID)/PlayedItems/\(itemID)",
            headers: authHeaders
        )
        _ = try await http.send(endpoint, baseURL: baseURL)
    }

    /// `POST`/`DELETE /Users/{userId}/FavoriteItems/{itemId}` — adds (POST) or
    /// removes (DELETE) the item from the user's Favorites, which backs the
    /// unified Watchlist.
    func setFavorite(_ favorite: Bool, userID: String, itemID: String) async throws {
        let endpoint = Endpoint(
            method: favorite ? .post : .delete,
            path: "/Users/\(userID)/FavoriteItems/\(itemID)",
            headers: authHeaders
        )
        _ = try await http.send(endpoint, baseURL: baseURL)
    }

    /// `GET /Users/{userId}/Items?Filters=IsFavorite` — the user's favourited
    /// movies & series, newest first, for the Watchlist row. Requests the same
    /// card-level fields as other rows so artwork resolves.
    func favorites(userID: String, limit: Int = 60) async throws -> [BaseItemDto] {
        let endpoint = Endpoint(
            path: "/Users/\(userID)/Items",
            queryItems: [
                URLQueryItem(name: "Filters", value: "IsFavorite"),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series"),
                URLQueryItem(name: "SortBy", value: "DateCreated"),
                URLQueryItem(name: "SortOrder", value: "Descending"),
                URLQueryItem(name: "Limit", value: String(limit)),
                URLQueryItem(name: "Fields", value: "PrimaryImageAspectRatio,ProviderIds"),
                URLQueryItem(name: "ImageTypeLimit", value: "1"),
                URLQueryItem(name: "EnableTotalRecordCount", value: "false")
            ],
            headers: authHeaders
        )
        return try await http.decode(ItemsResponse.self, from: endpoint, baseURL: baseURL).Items
    }

    /// `POST /Items/{itemId}/Refresh` — asks the server to re-scan metadata &
    /// images for the item, replacing existing values so corrected data flows in.
    /// The server queues the work and returns immediately.
    func refreshMetadata(itemID: String) async throws {
        let endpoint = Endpoint(
            method: .post,
            path: "/Items/\(itemID)/Refresh",
            queryItems: [
                URLQueryItem(name: "MetadataRefreshMode", value: "FullRefresh"),
                URLQueryItem(name: "ImageRefreshMode", value: "FullRefresh"),
                URLQueryItem(name: "ReplaceAllMetadata", value: "true"),
                URLQueryItem(name: "ReplaceAllImages", value: "true")
            ],
            headers: authHeaders
        )
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

    // MARK: Remote subtitles

    /// `GET /Items/{itemId}/RemoteSearch/Subtitles/{language}` — search subtitle
    /// providers (OpenSubtitles, etc.) for the item. `language` must be a
    /// 3-letter ISO-639-2 code; callers pass whatever they have and we normalise.
    func remoteSubtitleSearch(itemID: String, language: String) async throws -> [RemoteSubtitleInfoDto] {
        let lang = LanguageMatch.alpha3(language)
        let endpoint = Endpoint(
            path: "/Items/\(itemID)/RemoteSearch/Subtitles/\(lang)",
            headers: authHeaders
        )
        return try await http.decode([RemoteSubtitleInfoDto].self, from: endpoint, baseURL: baseURL)
    }

    /// `POST /Items/{itemId}/RemoteSearch/Subtitles/{subtitleId}` — tells the
    /// server to download the chosen subtitle and attach it to the item.
    func downloadRemoteSubtitle(itemID: String, subtitleID: String) async throws {
        let endpoint = Endpoint(
            method: .post,
            path: "/Items/\(itemID)/RemoteSearch/Subtitles/\(subtitleID)",
            headers: authHeaders
        )
        _ = try await http.send(endpoint, baseURL: baseURL)
    }

    // MARK: Music

    /// One page of music items from a container, using an explicit Jellyfin
    /// `SortBy` (music needs multi-key sorts like `ParentIndexNumber,IndexNumber`
    /// for album track order that the video `SortField` enum can't express).
    func musicItems(
        userID: String,
        parentID: String?,
        includeItemTypes: [String],
        recursive: Bool,
        startIndex: Int,
        limit: Int,
        sortBy: String,
        sortOrder: String,
        albumArtistID: String? = nil,
        filters: [String] = []
    ) async throws -> ItemsResponse {
        var queryItems = [
            URLQueryItem(name: "StartIndex", value: String(startIndex)),
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "SortBy", value: sortBy),
            URLQueryItem(name: "SortOrder", value: sortOrder),
            URLQueryItem(name: "Fields", value: "Genres,ChildCount,PrimaryImageAspectRatio"),
            URLQueryItem(name: "ImageTypeLimit", value: "1"),
            URLQueryItem(name: "EnableTotalRecordCount", value: "true")
        ]
        if let parentID, !parentID.isEmpty {
            queryItems.append(URLQueryItem(name: "ParentId", value: parentID))
        }
        if let albumArtistID, !albumArtistID.isEmpty {
            queryItems.append(URLQueryItem(name: "AlbumArtistIds", value: albumArtistID))
        }
        if !filters.isEmpty {
            queryItems.append(URLQueryItem(name: "Filters", value: filters.joined(separator: ",")))
        }
        if recursive {
            queryItems.append(URLQueryItem(name: "Recursive", value: "true"))
        }
        if !includeItemTypes.isEmpty {
            queryItems.append(URLQueryItem(name: "IncludeItemTypes", value: includeItemTypes.joined(separator: ",")))
        }
        let endpoint = Endpoint(path: "/Users/\(userID)/Items", queryItems: queryItems, headers: authHeaders)
        return try await http.decode(ItemsResponse.self, from: endpoint, baseURL: baseURL)
    }

    /// `GET /Artists` — the indexed artist list (optionally scoped to a library).
    func artists(
        userID: String,
        parentID: String?,
        startIndex: Int,
        limit: Int,
        sortOrder: String = "Ascending"
    ) async throws -> ItemsResponse {
        var queryItems = [
            URLQueryItem(name: "UserId", value: userID),
            URLQueryItem(name: "StartIndex", value: String(startIndex)),
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "SortOrder", value: sortOrder),
            URLQueryItem(name: "Fields", value: "Genres,ChildCount"),
            URLQueryItem(name: "ImageTypeLimit", value: "1"),
            URLQueryItem(name: "EnableTotalRecordCount", value: "true")
        ]
        if let parentID, !parentID.isEmpty {
            queryItems.append(URLQueryItem(name: "ParentId", value: parentID))
        }
        let endpoint = Endpoint(path: "/Artists", queryItems: queryItems, headers: authHeaders)
        return try await http.decode(ItemsResponse.self, from: endpoint, baseURL: baseURL)
    }

    /// `GET /MusicGenres` — genres present in the music libraries.
    func musicGenres(
        userID: String,
        parentID: String?,
        startIndex: Int,
        limit: Int
    ) async throws -> ItemsResponse {
        var queryItems = [
            URLQueryItem(name: "UserId", value: userID),
            URLQueryItem(name: "StartIndex", value: String(startIndex)),
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending"),
            URLQueryItem(name: "EnableTotalRecordCount", value: "true")
        ]
        if let parentID, !parentID.isEmpty {
            queryItems.append(URLQueryItem(name: "ParentId", value: parentID))
        }
        let endpoint = Endpoint(path: "/MusicGenres", queryItems: queryItems, headers: authHeaders)
        return try await http.decode(ItemsResponse.self, from: endpoint, baseURL: baseURL)
    }

    /// `GET /Playlists/{id}/Items` — a playlist's tracks in playlist order.
    func playlistItems(userID: String, playlistID: String) async throws -> ItemsResponse {
        let endpoint = Endpoint(
            path: "/Playlists/\(playlistID)/Items",
            queryItems: [
                URLQueryItem(name: "UserId", value: userID),
                URLQueryItem(name: "Fields", value: "Genres,PrimaryImageAspectRatio"),
                URLQueryItem(name: "EnableTotalRecordCount", value: "true")
            ],
            headers: authHeaders
        )
        return try await http.decode(ItemsResponse.self, from: endpoint, baseURL: baseURL)
    }

    /// Builds the `/Audio/{id}/universal` stream URL. The universal endpoint lets
    /// the server pick direct-play vs an HLS transcode for the device, mirroring
    /// the video `playbackInfo` decision but resolvable without a round-trip — it
    /// is a deterministic, token-authenticated URL, so the audio engine can build
    /// stream URLs for a whole queue without N PlaybackInfo calls.
    func audioStreamURL(itemID: String, playSessionID: String) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = basePath + "/Audio/\(itemID)/universal"
        var query = [
            URLQueryItem(name: "DeviceId", value: deviceProfile.deviceID),
            URLQueryItem(name: "MaxStreamingBitrate", value: String(capabilityProfile.maxStreamingBitrate)),
            // Containers AVPlayer can direct-play; anything else the server
            // transcodes down the HLS/AAC fallback below.
            URLQueryItem(name: "Container", value: "mp3,aac,m4a,flac,alac,wav,m4b"),
            URLQueryItem(name: "TranscodingContainer", value: "ts"),
            URLQueryItem(name: "TranscodingProtocol", value: "hls"),
            URLQueryItem(name: "AudioCodec", value: "aac"),
            URLQueryItem(name: "PlaySessionId", value: playSessionID)
        ]
        if let token, !token.isEmpty {
            query.append(URLQueryItem(name: "api_key", value: token))
        }
        components.queryItems = query
        return components.url
    }

    /// `GET /Audio/{itemId}/Lyrics` — the track's lyrics, timestamped (ticks) or
    /// plain. Returns `nil` when the server has no lyrics (it answers 404), which
    /// is mapped to "no lyrics" rather than an error by the caller.
    func lyrics(itemID: String) async throws -> LyricDto {
        let endpoint = Endpoint(path: "/Audio/\(itemID)/Lyrics", headers: authHeaders)
        return try await http.decode(LyricDto.self, from: endpoint, baseURL: baseURL)
    }

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

    /// Builds an absolute profile-image URL for a Jellyfin user
    /// (`/Users/{id}/Images/Primary`). We attach `api_key` when available so the
    /// image loads even on servers that require auth for user avatars.
    public func userAvatarURL(userID: String, maxWidth: Int?, token: String?) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = basePath + "/Users/\(userID)/Images/Primary"
        var queryItems: [URLQueryItem] = []
        if let maxWidth {
            queryItems.append(URLQueryItem(name: "maxWidth", value: String(maxWidth)))
        }
        if let token, !token.isEmpty {
            queryItems.append(URLQueryItem(name: "api_key", value: token))
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components.url
    }

    /// Absolute URL for one trickplay tile image
    /// (`GET /Videos/{itemId}/Trickplay/{width}/{index}.jpg`). The endpoint
    /// requires auth, so we embed the token as `api_key` because image loaders
    /// (URLSession data tasks here) don't carry our auth headers.
    func trickplayTileURL(itemID: String, mediaSourceID: String?, width: Int, tileIndex: Int) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = basePath + "/Videos/\(itemID)/Trickplay/\(width)/\(tileIndex).jpg"
        var query = [URLQueryItem(name: "api_key", value: token ?? "")]
        if let mediaSourceID, !mediaSourceID.isEmpty {
            query.append(URLQueryItem(name: "mediaSourceId", value: mediaSourceID))
        }
        components.queryItems = query
        return components.url
    }
}

private struct PlaybackProgressBody: Encodable {
    let ItemId: String
    let PlaySessionId: String?
    let PositionTicks: Int64
    let IsPaused: Bool
}
