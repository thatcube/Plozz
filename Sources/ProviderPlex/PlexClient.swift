import Foundation
import CoreModels
import CoreNetworking

/// Low-level Plex Media Server REST client.
///
/// One instance is bound to a single server `baseURL` + `token`. It deals only
/// in DTOs; mapping to `CoreModels` happens in `PlexProvider`. Mirrors the role
/// of `JellyfinClient` for the Plex backend.
public struct PlexClient: Sendable {
    /// Resolves (and self-heals) the working server base URL. Browsing requests
    /// go through it so a saved-but-now-unreachable connection transparently
    /// fails over to a reachable one.
    private let resolver: PlexConnectionResolver
    private let deviceProfile: PlexDeviceProfile
    private let token: String
    private let http: HTTPClient
    /// Foreground/critical-path client with its own connection pool (see
    /// ``URLSession/plozzInteractive``) used only for the user-blocking `metadata()`
    /// fetch, so opening a detail page is never starved behind background
    /// enrichment traffic on the shared default pool.
    private let interactiveHTTP: HTTPClient
    /// What the running Apple TV + connected display/audio gear can actually
    /// decode and present. Drives `canDirectPlay` so the direct-play vs. Plex
    /// universal-transcode decision tracks the real hardware instead of fixed
    /// sets. Defaults to a live `.detected()` probe (which falls back to the
    /// conservative `.default` on Linux/CI).
    private let capabilities: MediaCapabilities
    /// Whether the dual-engine (VLCKit) build is active. When `true`,
    /// `canDirectPlay` additionally accepts the **extra** formats the on-device
    /// hybrid engine handles — the Matroska / WebM container (every display-
    /// supported range, including Dolby Vision, decoded on-device) and DTS / DTS-HD /
    /// TrueHD audio (decoded on-device, no passthrough required). Defaults to
    /// `false`, preserving today's native-only direct-play decisions. Must stay in
    /// lockstep with `EngineRouter`: every extra format accepted here is one the
    /// router sends to the hybrid engine.
    private let hybridEngineEnabled: Bool

    /// The server base URL currently in use (best-known reachable connection).
    /// Resolved lazily on the first request; this is the synchronous best guess
    /// used by URL builders after a request has settled it.
    public var baseURL: URL { resolver.current }

    /// Whether the resolver has a confirmed-reachable (or persisted last-known-good)
    /// connection, so `baseURL`'s locality can be trusted for best-source selection.
    /// See ``PlexConnectionResolver/hasConfirmedReachableConnection``.
    public var hasConfirmedReachableConnection: Bool { resolver.hasConfirmedReachableConnection }

    /// Fixed-URL initializer: the client always talks to `baseURL` (no probing).
    /// Used for manually-entered hosts and unit tests.
    public init(
        baseURL: URL,
        deviceProfile: PlexDeviceProfile,
        token: String,
        http: HTTPClient = URLSessionHTTPClient(),
        interactiveHTTP: HTTPClient? = nil,
        capabilities: MediaCapabilities = .detected(),
        hybridEngineEnabled: Bool = false
    ) {
        self.init(
            resolver: PlexConnectionResolver(candidates: [baseURL], deviceProfile: deviceProfile, token: token),
            deviceProfile: deviceProfile,
            token: token,
            http: http,
            interactiveHTTP: interactiveHTTP,
            capabilities: capabilities,
            hybridEngineEnabled: hybridEngineEnabled
        )
    }

    /// Self-healing initializer: `resolver` probes its candidate connections and
    /// keeps the client on whichever one is reachable.
    public init(
        resolver: PlexConnectionResolver,
        deviceProfile: PlexDeviceProfile,
        token: String,
        http: HTTPClient = URLSessionHTTPClient(),
        interactiveHTTP: HTTPClient? = nil,
        capabilities: MediaCapabilities = .detected(),
        hybridEngineEnabled: Bool = false
    ) {
        self.resolver = resolver
        self.deviceProfile = deviceProfile
        self.token = token
        self.http = http
        // Falls back to `http` when no dedicated foreground client is supplied, so
        // a test injecting a single stub for `http` routes the user-blocking
        // `metadata()` fetch through it too instead of hitting a live session. The
        // production foreground-pool isolation is opted into explicitly by the
        // provider (see AppState), which passes a real `plozzInteractive` client.
        self.interactiveHTTP = interactiveHTTP ?? http
        self.capabilities = capabilities
        self.hybridEngineEnabled = hybridEngineEnabled
    }

    private var headers: [String: String] { deviceProfile.headers(token: token) }

    // MARK: Request plumbing

    /// Sends `endpoint` against the resolved base URL, transparently re-resolving
    /// and retrying once if the chosen connection is unreachable (self-heal).
    private func send(_ endpoint: Endpoint, using client: HTTPClient? = nil) async throws -> (Data, HTTPURLResponse) {
        let client = client ?? http
        let base = await resolver.resolved()
        do {
            return try await client.send(endpoint, baseURL: base)
        } catch AppError.serverUnreachable {
            resolver.reportFailure(base)
            let retry = await resolver.resolved()
            guard retry != base else { throw AppError.serverUnreachable }
            return try await client.send(endpoint, baseURL: retry)
        }
    }

    /// Sends and decodes JSON, with the same self-healing retry as `send`.
    private func decode<T: Decodable>(_ type: T.Type, _ endpoint: Endpoint, using client: HTTPClient? = nil) async throws -> T {
        let (data, _) = try await send(endpoint, using: client)
        do {
            return try JSONDecoder.plozz.decode(T.self, from: data)
        } catch {
            PlozzLog.networking.error("Decoding \(String(describing: T.self)) failed")
            throw AppError.decoding
        }
    }

    /// Sends a list / `/children` request with Plex's `includeElements=Stream`
    /// flag — which inlines each item's `<Stream>` array so list and season cards
    /// can show DoVi/HDR badges — and transparently retries **once without** the
    /// flag if the server rejects the enriched request.
    ///
    /// Some PMS versions return HTTP 500 on `includeElements=Stream`, which would
    /// otherwise break library browsing and season views outright and silently
    /// empty the onDeck / recentlyAdded rails (their errors get swallowed into an
    /// empty rail). The flag only feeds list-card badges — detail and playback
    /// re-fetch the full Media/Part/Stream per item via `metadata()` — so the lean
    /// fallback costs nothing but those cosmetic badges, while capable servers pay
    /// zero overhead (the first, enriched request simply succeeds).
    private func decodeStreamEnriched<T: Decodable>(
        _ type: T.Type,
        path: String,
        query: [URLQueryItem]
    ) async throws -> T {
        let enriched = Endpoint(
            path: path,
            queryItems: query + [URLQueryItem(name: "includeElements", value: "Stream")],
            headers: headers
        )
        do {
            return try await decode(T.self, enriched)
        } catch AppError.invalidResponse {
            PlozzLog.networking.error("Plex rejected includeElements=Stream on \(path); retrying lean")
            let lean = Endpoint(path: path, queryItems: query, headers: headers)
            return try await decode(T.self, lean)
        }
    }

    // MARK: Browsing

    /// `GET /library/sections` — top-level libraries.
    func sections() async throws -> [PlexDirectory] {
        let endpoint = Endpoint(path: "/library/sections", headers: headers)
        return try await decode(PlexMediaContainerResponse.self, endpoint)
            .MediaContainer.Directory ?? []
    }

    /// `GET /library/onDeck` — Continue Watching.
    func onDeck(limit: Int) async throws -> [PlexMetadata] {
        try await decodeStreamEnriched(
            PlexMediaContainerResponse.self,
            path: "/library/onDeck",
            query: containerQuery(start: 0, size: limit)
        ).MediaContainer.Metadata ?? []
    }

    /// Shows across every section ordered by most-recently-viewed first — the Plex
    /// mirror of ``JellyfinClient/recentlyWatchedSeries(userID:limit:)``. A
    /// just-finished series' *next* episode arrives on `onDeck` with no
    /// `lastViewedAt` of its own (it's unwatched), so Continue Watching can't rank
    /// the show by real recency; this lets the provider stamp that episode with its
    /// series' `lastViewedAt`, keyed by the series `ratingKey` (an episode's
    /// `grandparentRatingKey`). `type=2` selects shows; never-viewed shows sort last
    /// (Plex omits `lastViewedAt`). Best-effort — a failure yields an empty map and
    /// Continue Watching falls back to unstamped ordering.
    func recentlyViewedShows(limit: Int) async throws -> [PlexMetadata] {
        let query = [
            URLQueryItem(name: "type", value: "2"),
            URLQueryItem(name: "X-Plex-Container-Start", value: "0"),
            URLQueryItem(name: "X-Plex-Container-Size", value: String(max(0, limit))),
            URLQueryItem(name: "sort", value: "lastViewedAt:desc")
        ]
        let endpoint = Endpoint(path: "/library/all", queryItems: query, headers: headers)
        return try await decode(PlexMediaContainerResponse.self, endpoint).MediaContainer.Metadata ?? []
    }

    /// `GET /library/recentlyAdded` — newest items across libraries.
    func recentlyAdded(limit: Int) async throws -> [PlexMetadata] {
        try await decodeStreamEnriched(
            PlexMediaContainerResponse.self,
            path: "/library/recentlyAdded",
            query: containerQuery(start: 0, size: limit)
        ).MediaContainer.Metadata ?? []
    }

    /// `GET /library/metadata/{ratingKey}` — full detail for one item.
    func metadata(ratingKey: String) async throws -> PlexMetadata {
        let endpoint = Endpoint(
            path: "/library/metadata/\(ratingKey)",
            queryItems: [URLQueryItem(name: "includeGuids", value: "1")],
            headers: headers
        )
        let container = try await decode(PlexMediaContainerResponse.self, endpoint, using: interactiveHTTP).MediaContainer
        guard let item = container.Metadata?.first else { throw AppError.notFound }
        return item
    }

    /// `GET /library/metadata/{ratingKey}?includeMarkers=1` — fetches the item's
    /// Plex Pass intro/credits markers. Returns an empty array on servers/items
    /// without markers (non-Plex-Pass, unanalysed, or movies without credits).
    func mediaSegments(ratingKey: String) async throws -> [PlexMarker] {
        let endpoint = Endpoint(
            path: "/library/metadata/\(ratingKey)",
            queryItems: [URLQueryItem(name: "includeMarkers", value: "1")],
            headers: headers
        )
        let container = try await decode(PlexMediaContainerResponse.self, endpoint, using: interactiveHTTP).MediaContainer
        return container.Metadata?.first?.Marker ?? []
    }

    /// `GET /library/metadata/{ratingKey}/subtitles?language=&hearingImpaired=&forced=`
    /// — searches Plex's on-demand subtitle source (OpenSubtitles.com, configured
    /// server-side) for the item. `language` is an ISO-639-1 (2-letter) code;
    /// `hearingImpaired`/`forced` are Plex's 0–3 preference levels
    /// (0 prefer-non · 1 prefer · 2 only · 3 only-non). Keyless from the client:
    /// the server owns the subtitle account. Returns `[]` when the server has no
    /// on-demand source configured.
    func remoteSubtitleSearch(
        ratingKey: String,
        language: String,
        hearingImpaired: Int = 0,
        forced: Int = 0
    ) async throws -> [PlexSubtitleSearchStream] {
        let lang = LanguageMatch.normalized(language) ?? language
        let endpoint = Endpoint(
            path: "/library/metadata/\(ratingKey)/subtitles",
            queryItems: [
                URLQueryItem(name: "language", value: lang),
                URLQueryItem(name: "hearingImpaired", value: String(hearingImpaired)),
                URLQueryItem(name: "forced", value: String(forced))
            ],
            headers: headers
        )
        return try await decode(PlexSubtitleSearchResponse.self, endpoint, using: interactiveHTTP)
            .MediaContainer.Stream ?? []
    }

    /// `PUT /library/metadata/{ratingKey}/subtitles?key={subtitleKey}` — tells the
    /// server to download the chosen on-demand subtitle and attach it to the item
    /// (which also selects it server-side for this user). Asynchronous: the server
    /// queues the fetch and returns before it completes, so callers must poll the
    /// item's streams to observe the new sidecar.
    func downloadRemoteSubtitle(ratingKey: String, key: String) async throws {
        let endpoint = Endpoint(
            method: .put,
            path: "/library/metadata/\(ratingKey)/subtitles",
            queryItems: [
                URLQueryItem(name: "key", value: key),
                URLQueryItem(name: "X-Plex-Token", value: token)
            ],
            headers: headers
        )
        _ = try await send(endpoint)
    }

    /// `GET /library/metadata/{ratingKey}/children` — seasons of a show,
    /// episodes of a season, …
    ///
    /// Requests `includeElements=Stream` so each child carries its `<Stream>`
    /// array (DoVi* / colorTrc → DoVi/HDR badges), with a transparent lean retry
    /// if the server rejects that flag (see ``decodeStreamEnriched``). By default
    /// Plex's /children response returns ZERO `<Stream>` elements — only the
    /// parent `<Media>` — so without the flag DoVi/HDR badges silently disappear
    /// (Atmos still works without it because it's a Media attribute, not a Stream
    /// field). `includeGuids=1` additionally inlines each child's external `Guid`
    /// array (imdb://, tmdb://, tvdb://) so the cross-server episode-twin step can
    /// match by id, not ordinal alone.
    func children(ratingKey: String) async throws -> [PlexMetadata] {
        try await decodeStreamEnriched(
            PlexMediaContainerResponse.self,
            path: "/library/metadata/\(ratingKey)/children",
            query: [URLQueryItem(name: "includeGuids", value: "1")]
        ).MediaContainer.Metadata ?? []
    }

    /// `GET /library/metadata/{ratingKey}/extras` — trailers and other extras
    /// (behind-the-scenes, deleted scenes, …) attached to an item. Each extra is
    /// a `clip` with its own ratingKey that streams through the normal playback
    /// path. Callers filter by `subtype` to keep only trailers.
    func extras(ratingKey: String) async throws -> [PlexMetadata] {
        let endpoint = Endpoint(path: "/library/metadata/\(ratingKey)/extras", headers: headers)
        return try await decode(PlexMediaContainerResponse.self, endpoint)
            .MediaContainer.Metadata ?? []
    }

    /// `GET /library/sections/{id}/all` — one page of a library section, paged
    /// server-side with `X-Plex-Container-Start` / `X-Plex-Container-Size`.
    func sectionItems(
        sectionID: String,
        type: Int?,
        start: Int,
        size: Int,
        sort: CoreModels.SortDescriptor
    ) async throws -> PlexMediaContainer {
        var query = containerQuery(start: start, size: size)
        if let type {
            query.append(URLQueryItem(name: "type", value: String(type)))
        }
        query.append(URLQueryItem(name: "sort", value: Self.sortQuery(for: sort)))
        return try await decodeStreamEnriched(
            PlexMediaContainerResponse.self,
            path: "/library/sections/\(sectionID)/all",
            query: query
        ).MediaContainer
    }

    /// `GET /hubs/sections/{id}` — the library's promoted "hubs" (Recently Added,
    /// On Deck, "More in <Genre>", "Because you watched…", Top Rated, …).
    ///
    /// `count` caps items **per hub** (Plex's `count` param). Uses the
    /// stream-enriched path so hub cards can show DoVi/HDR badges, with the same
    /// transparent lean retry as the other list endpoints. Returns the raw hubs in
    /// server order; the provider filters + maps them.
    func sectionHubs(sectionID: String, count: Int) async throws -> [PlexHub] {
        let query = [
            URLQueryItem(name: "count", value: String(max(1, count))),
            URLQueryItem(name: "includeGuids", value: "1")
        ]
        return try await decodeStreamEnriched(
            PlexMediaContainerResponse.self,
            path: "/hubs/sections/\(sectionID)",
            query: query
        ).MediaContainer.Hub ?? []
    }

    /// `GET /library/sections/{id}/firstCharacter` — the section's title
    /// first-character facet: one `Directory` per present letter (in ascending
    /// `titleSort` order) carrying its `titleSort` (`"A"`, `"1-9"`, `"#"`, …)
    /// and `size` (how many titles fall under it). Cumulating the sizes gives
    /// each letter's grid offset for the name-sorted browse, which drives the
    /// A–Z fast-scroll rail. `type` scopes the counts to the browsed content
    /// type so they match `sectionItems` in a mixed section.
    func firstCharacter(sectionID: String, type: Int?) async throws -> [PlexDirectory] {
        var query: [URLQueryItem] = []
        if let type {
            query.append(URLQueryItem(name: "type", value: String(type)))
        }
        let endpoint = Endpoint(
            path: "/library/sections/\(sectionID)/firstCharacter",
            queryItems: query,
            headers: headers
        )
        return try await decode(PlexMediaContainerResponse.self, endpoint)
            .MediaContainer.Directory ?? []
    }

    /// `GET /search?query=…` — global server search across libraries. Returns a
    /// flat `Metadata` list of matching movies/shows/episodes.
    func search(query: String, limit: Int) async throws -> [PlexMetadata] {
        var items = containerQuery(start: 0, size: limit)
        items.append(URLQueryItem(name: "query", value: query))
        return try await decodeStreamEnriched(
            PlexMediaContainerResponse.self,
            path: "/search",
            query: items
        ).MediaContainer.Metadata ?? []
    }

    // MARK: Music browsing

    /// One page of a music library section, filtered to a Plex content `type`
    /// (8 = artist, 9 = album, 10 = track). Unlike the video `sectionItems`,
    /// music browsing doesn't need the per-`Stream`/`Guid` inlining, so this uses
    /// a lean container query (just start/size + sort) to keep large artist/album
    /// pages light.
    func musicSectionItems(
        sectionID: String,
        type: Int,
        start: Int,
        size: Int,
        sort: CoreModels.SortDescriptor
    ) async throws -> PlexMediaContainer {
        let query = [
            URLQueryItem(name: "type", value: String(type)),
            URLQueryItem(name: "X-Plex-Container-Start", value: String(start)),
            URLQueryItem(name: "X-Plex-Container-Size", value: String(size)),
            URLQueryItem(name: "sort", value: Self.sortQuery(for: sort))
        ]
        let endpoint = Endpoint(path: "/library/sections/\(sectionID)/all", queryItems: query, headers: headers)
        return try await decode(PlexMediaContainerResponse.self, endpoint).MediaContainer
    }

    /// Albums in a music section ordered by most-recently-played first. Uses the
    /// raw Plex `sort=lastViewedAt:desc` key, which the shared `SortDescriptor`
    /// can't express. Never-played albums sort last (Plex reports them with no
    /// `lastViewedAt`), so callers filter to `viewCount >= 1` and take the head.
    func recentlyViewedAlbums(sectionID: String, type: Int, limit: Int) async throws -> [PlexMetadata] {
        let query = [
            URLQueryItem(name: "type", value: String(type)),
            URLQueryItem(name: "X-Plex-Container-Start", value: "0"),
            URLQueryItem(name: "X-Plex-Container-Size", value: String(max(0, limit))),
            URLQueryItem(name: "sort", value: "lastViewedAt:desc")
        ]
        let endpoint = Endpoint(path: "/library/sections/\(sectionID)/all", queryItems: query, headers: headers)
        return try await decode(PlexMediaContainerResponse.self, endpoint).MediaContainer.Metadata ?? []
    }

    /// `GET /library/sections/{id}/genre` — the genres present in a music
    /// section, returned as `Directory` entries (`key` = genre id, `title` =
    /// name).
    func musicGenres(sectionID: String) async throws -> [PlexDirectory] {
        let endpoint = Endpoint(path: "/library/sections/\(sectionID)/genre", headers: headers)
        return try await decode(PlexMediaContainerResponse.self, endpoint)
            .MediaContainer.Directory ?? []
    }

    /// `GET /playlists?playlistType=audio` — the user's audio playlists.
    func audioPlaylists() async throws -> [PlexMetadata] {
        let endpoint = Endpoint(
            path: "/playlists",
            queryItems: [URLQueryItem(name: "playlistType", value: "audio")],
            headers: headers
        )
        return try await decode(PlexMediaContainerResponse.self, endpoint)
            .MediaContainer.Metadata ?? []
    }

    /// `GET /playlists/{id}/items` — a playlist's tracks, in playlist order.
    func playlistItems(ratingKey: String) async throws -> [PlexMetadata] {
        let endpoint = Endpoint(path: "/playlists/\(ratingKey)/items", headers: headers)
        return try await decode(PlexMediaContainerResponse.self, endpoint)
            .MediaContainer.Metadata ?? []
    }

    /// Resolves a playable audio URL for a track's chosen media/part: **direct
    /// play** when AVPlayer can demux the container/codec natively (the common
    /// case for mp4/m4a/mp3/flac/wav), otherwise Plex's universal **music**
    /// transcoder (a progressive MP3 stream AVPlayer plays directly). Mirrors the
    /// video `playbackURL` decision, scoped to audio.
    func audioPlaybackURL(ratingKey: String, media: PlexMedia, part: PlexPart, sessionID: String) -> (url: URL, isTranscoding: Bool)? {
        if Self.canDirectPlayAudioFile(media: media, part: part), let key = part.key, let direct = streamURL(forPartKey: key) {
            return (direct, false)
        }
        if let transcode = audioTranscodeURL(ratingKey: ratingKey, sessionID: sessionID) {
            return (transcode, true)
        }
        // Last-resort: attempt direct play rather than failing outright.
        if let key = part.key, let direct = streamURL(forPartKey: key) {
            return (direct, false)
        }
        return nil
    }

    /// Containers + codecs AVFoundation demuxes/decodes natively from a plain
    /// audio file URL on tvOS. Anything outside this set (e.g. `opus`/`ogg`,
    /// `dsf`, `wma`) is routed through the server's music transcoder instead.
    private static let directPlayAudioContainers: Set<String> = ["mp4", "m4a", "m4b", "mp3", "flac", "wav", "aac", "aiff", "aif"]
    private static let directPlayAudioCodecs: Set<String> = ["aac", "mp3", "alac", "flac", "pcm", "lpcm"]

    static func canDirectPlayAudioFile(media: PlexMedia, part: PlexPart) -> Bool {
        let container = (media.container ?? part.container ?? containerExtension(fromKey: part.key))?.lowercased()
        guard let container, directPlayAudioContainers.contains(container) else { return false }
        // When Plex reports the codec, gate on it too; if it's absent, trust the
        // container (these audio containers carry only the listed codecs).
        if let codec = media.audioCodec?.lowercased() {
            return directPlayAudioCodecs.contains(codec)
        }
        return true
    }

    /// Builds Plex's universal **music** transcoder URL — a progressive MP3
    /// stream (`start.mp3`) that AVPlayer streams directly. Identity + token + a
    /// stable session id travel as query params, matching the video transcoder.
    func audioTranscodeURL(ratingKey: String, sessionID: String) -> URL? {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "path", value: "/library/metadata/\(ratingKey)"),
            URLQueryItem(name: "mediaIndex", value: "0"),
            URLQueryItem(name: "partIndex", value: "0"),
            URLQueryItem(name: "musicBitrate", value: "320"),
            URLQueryItem(name: "protocol", value: "http"),
            URLQueryItem(name: "session", value: sessionID),
            URLQueryItem(name: "X-Plex-Session-Identifier", value: sessionID)
        ]
        for (name, value) in deviceProfile.headers(token: token) where name.hasPrefix("X-Plex-") {
            query.append(URLQueryItem(name: name, value: value))
        }
        return absoluteURL(serverPath: "/music/:/transcode/universal/start.mp3", extraQuery: query)
    }

    // MARK: Playback

    /// `GET /:/timeline` — report progress so Plex keeps resume points in sync.
    func reportTimeline(ratingKey: String, state: String, timeMs: Int, durationMs: Int?) async throws {
        var query = [
            URLQueryItem(name: "ratingKey", value: ratingKey),
            URLQueryItem(name: "key", value: "/library/metadata/\(ratingKey)"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "time", value: String(timeMs)),
            URLQueryItem(name: "X-Plex-Token", value: token)
        ]
        if let durationMs {
            query.append(URLQueryItem(name: "duration", value: String(durationMs)))
        }
        let endpoint = Endpoint(path: "/:/timeline", queryItems: query, headers: headers)
        _ = try await send(endpoint)
    }

    /// `GET /:/progress` — set the saved resume point (`viewOffset`) **out-of-
    /// band**, without opening or closing a live `/:/timeline` session. Used by
    /// the convergence/durability path so a position write can't terminate a
    /// now-playing session the way `/:/timeline?state=stopped` does (which would
    /// zero the server's now-playing dashboard). Params mirror the Plex playstate
    /// API used by sync tools: `key`=ratingKey,
    /// `identifier`=`com.plexapp.plugins.library`, `time`=ms, `state`.
    func reportProgress(ratingKey: String, timeMs: Int, state: String = "stopped") async throws {
        let endpoint = Endpoint(
            path: "/:/progress",
            queryItems: [
                URLQueryItem(name: "key", value: ratingKey),
                URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
                URLQueryItem(name: "time", value: String(timeMs)),
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "X-Plex-Token", value: token)
            ],
            headers: headers
        )
        _ = try await send(endpoint)
    }

    /// `GET /:/scrobble` (watched) or `GET /:/unscrobble` (unwatched) — toggles
    /// an item's watched state. Scrobbling a season/series ratingKey marks the
    /// contained episodes too.
    func setWatched(_ watched: Bool, ratingKey: String) async throws {
        let endpoint = Endpoint(
            path: watched ? "/:/scrobble" : "/:/unscrobble",
            queryItems: [
                URLQueryItem(name: "key", value: ratingKey),
                URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
                URLQueryItem(name: "X-Plex-Token", value: token)
            ],
            headers: headers
        )
        _ = try await send(endpoint)
    }

    /// `PUT /library/metadata/{ratingKey}/refresh` — asks the PMS to re-scan the
    /// item's files and re-fetch metadata/artwork from its configured agents.
    /// The server queues the work and returns immediately.
    func refreshMetadata(ratingKey: String) async throws {
        let endpoint = Endpoint(
            method: .put,
            path: "/library/metadata/\(ratingKey)/refresh",
            queryItems: [URLQueryItem(name: "X-Plex-Token", value: token)],
            headers: headers
        )
        _ = try await send(endpoint)
    }

    // MARK: Watchlist (plex.tv Discover service)
    //
    // Plex's Watchlist is an **account-level** feature served by the global
    // Discover host `discover.provider.plex.tv` — NOT the per-server PMS API and
    // no longer the legacy `metadata.provider.plex.tv` read host (that now 404s;
    // reads were migrated to the Discover host). It's keyed by the item's global
    // `plex://` guid (its trailing id), so these requests bypass the connection
    // resolver and hit the fixed plex.tv host directly with the account token.
    // Failures surface to the caller, which reverts the optimistic UI.

    private static let watchlistBase = URL(string: "https://discover.provider.plex.tv")!

    /// The Discover metadata id for a `plex://<type>/<id>` guid — the trailing
    /// path component the watchlist endpoints key on. `nil` for a non-`plex://`
    /// guid or one missing its `<id>` tail (e.g. `plex://movie/`), so a bare type
    /// token is never mistaken for an id.
    static func watchlistMetadataID(fromGuid guid: String?) -> String? {
        guard let guid, guid.hasPrefix("plex://") else { return nil }
        // Format is `plex://<type>/<id>`: keep empty subsequences so a trailing
        // slash yields an empty id (→ nil) rather than collapsing onto the type.
        let parts = guid.dropFirst("plex://".count)
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.count >= 2 else { return nil }
        let id = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    /// The Discover metadata id for either a full `plex://<type>/<id>` guid or an
    /// id that is *already* a bare Discover id (the 24-char hex string Plex assigns
    /// account-level titles). Returns `nil` for a per-server PMS `ratingKey` (a
    /// plain integer) and any other token, so a library id is never mistaken for a
    /// Discover id.
    ///
    /// Watchlist tiles surface the Discover id both as the item's `ratingKey`
    /// (→ `MediaItem.id`) *and* inside its `plex://` guid, so detail opens arrive
    /// here as the bare hex id while the watchlist writer keys on the guid tail;
    /// both forms must resolve to the same Discover id.
    static func discoverMetadataID(from idOrGuid: String) -> String? {
        // A `plex://<type>/<id>` guid: reuse the watchlist tail extractor.
        if let fromGuid = watchlistMetadataID(fromGuid: idOrGuid) { return fromGuid }
        let trimmed = idOrGuid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // A bare Discover id is a hex string that (unlike a numeric PMS ratingKey)
        // contains at least one letter. Require hex-only + a letter so integer
        // ratingKeys stay on the library path and arbitrary slugs are ignored.
        let isHex = trimmed.allSatisfy(\.isHexDigit)
        let hasLetter = trimmed.contains { $0.isLetter }
        return (isHex && hasLetter) ? trimmed : nil
    }

    /// `GET https://discover.provider.plex.tv/library/metadata/{metadataID}` — the
    /// **full** Discover (plex.tv) metadata for an account-level title, keyed by its
    /// global Discover id. Used to render the Info body (overview / cast / ratings /
    /// art / runtime / genres) for a *watchlisted* title the user doesn't own on any
    /// server, since the per-server `metadata(ratingKey:)` 404s on a global id.
    ///
    /// Hits the fixed Discover host directly with the account token + the same
    /// X-Plex headers the watchlist calls use (bypassing the per-server connection
    /// resolver), mirroring `watchlist()`. The legacy `metadata.provider.plex.tv`
    /// read host now 404s — reads were migrated to `discover.provider.plex.tv`.
    /// `includeGuids=1` inlines the external ids (imdb/tmdb/tvdb) so the mapped item
    /// carries the provider ids cross-server discovery + the request path match on.
    func discoverMetadata(metadataID: String) async throws -> PlexMetadata {
        let endpoint = Endpoint(
            path: "/library/metadata/\(metadataID)",
            queryItems: [
                URLQueryItem(name: "X-Plex-Token", value: token),
                URLQueryItem(name: "includeGuids", value: "1")
            ],
            headers: headers
        )
        let (data, _) = try await http.send(endpoint, baseURL: Self.watchlistBase)
        do {
            guard let item = try JSONDecoder.plozz
                .decode(PlexMediaContainerResponse.self, from: data)
                .MediaContainer.Metadata?.first
            else { throw AppError.notFound }
            return item
        } catch let error as AppError {
            throw error
        } catch {
            PlozzLog.networking.error("Decoding Plex Discover metadata failed")
            throw AppError.decoding
        }
    }

    /// `PUT https://discover.provider.plex.tv/actions/{addToWatchlist|
    /// removeFromWatchlist}?ratingKey={metadataID}` — adds/removes the item from
    /// the account watchlist. `metadataID` is the guid tail (see
    /// `watchlistMetadataID(fromGuid:)`).
    func setWatchlisted(_ on: Bool, metadataID: String) async throws {
        let endpoint = Endpoint(
            method: .put,
            path: "/actions/\(on ? "addToWatchlist" : "removeFromWatchlist")",
            queryItems: [
                URLQueryItem(name: "ratingKey", value: metadataID),
                URLQueryItem(name: "X-Plex-Token", value: token)
            ],
            headers: headers
        )
        _ = try await http.send(endpoint, baseURL: Self.watchlistBase)
    }

    /// `GET https://discover.provider.plex.tv/library/sections/watchlist/all` —
    /// the account's current watchlist. Items carry global Discover ids that do
    /// not resolve against a specific PMS for playback (documented limitation).
    func watchlist() async throws -> [PlexMetadata] {
        let endpoint = Endpoint(
            path: "/library/sections/watchlist/all",
            queryItems: [
                URLQueryItem(name: "X-Plex-Token", value: token),
                URLQueryItem(name: "includeFields", value: "title,type,year,thumb,art,guid,ratingKey")
            ],
            headers: headers
        )
        let (data, _) = try await http.send(endpoint, baseURL: Self.watchlistBase)
        do {
            return try JSONDecoder.plozz.decode(PlexMediaContainerResponse.self, from: data)
                .MediaContainer.Metadata ?? []
        } catch {
            PlozzLog.networking.error("Decoding Plex watchlist failed")
            throw AppError.decoding
        }
    }

    // MARK: URLs

    /// Fetches the raw text of a lyrics (or other sidecar) stream by its
    /// server-relative `key` (e.g. `/library/streams/5555`). Plex serves an
    /// `.lrc` or plain-text body; `download=1` asks for the file itself rather
    /// than a transcoded view. Returns `nil` when the body isn't decodable text.
    func lyricsText(forStreamKey key: String) async throws -> String? {
        let endpoint = Endpoint(
            path: key,
            queryItems: [URLQueryItem(name: "download", value: "1")],
            headers: headers
        )
        let (data, _) = try await send(endpoint)
        // Most sidecars are UTF-8; fall back to Latin-1 so a non-UTF-8 `.lrc`
        // still decodes (Latin-1 maps any byte, so this won't return nil).
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    /// Builds an absolute, token-bearing stream URL for a part `key` (which is
    /// already a server-relative `/library/parts/…/file.…` path). Used for
    /// direct play of a container/codec tvOS can demux natively.
    func streamURL(forPartKey key: String) -> URL? {
        absoluteURL(serverPath: key, extraQuery: [URLQueryItem(name: "X-Plex-Token", value: token)])
    }

    /// Builds the absolute raw-file URL for a part `key`, explicitly asking Plex
    /// for the original file bytes (`download=1`). Used by the local-remux seam,
    /// which needs stable range-readable access to the untouched MKV.
    func downloadURL(forPartKey key: String) -> URL? {
        absoluteURL(
            serverPath: key,
            extraQuery: [
                URLQueryItem(name: "download", value: "1"),
                URLQueryItem(name: "X-Plex-Token", value: token)
            ]
        )
    }

    /// Resolves the playable URL for a media item, choosing **direct play** when
    /// tvOS/AVFoundation can demux the original container/codecs, and otherwise a
    /// server-side **HLS transcode** (Plex's universal transcoder).
    ///
    /// This mirrors what Jellyfin does server-side: a file in an unsupported
    /// container (e.g. MKV) or codec must be remuxed/transcoded to HLS, because
    /// AVPlayer cannot play it directly. Handing AVPlayer the raw MKV part was
    /// why Plex items "didn't play" while the same files played via Jellyfin.
    func playbackURL(
        ratingKey: String,
        media: PlexMedia,
        part: PlexPart,
        sessionID: String,
        mediaIndex: Int = 0,
        partIndex: Int = 0,
        forceTranscode: Bool = false
    ) -> (url: URL, isTranscoding: Bool)? {
        // Forcing a transcode (player fallback after a failed direct play): skip
        // the direct-play path entirely and go straight to the universal
        // transcoder. If even that can't be built, fail rather than silently
        // handing back the same direct URL that just failed.
        if forceTranscode {
            if let transcode = transcodeURL(
                ratingKey: ratingKey,
                sessionID: sessionID,
                mediaIndex: mediaIndex,
                partIndex: partIndex
            ) {
                return (transcode, true)
            }
            return nil
        }
        if canDirectPlay(media: media, part: part), let key = part.key, let direct = streamURL(forPartKey: key) {
            return (direct, false)
        }
        if let transcode = transcodeURL(
            ratingKey: ratingKey,
            sessionID: sessionID,
            mediaIndex: mediaIndex,
            partIndex: partIndex
        ) {
            return (transcode, true)
        }
        // Last-resort fallback: better to attempt direct play than fail outright.
        if let key = part.key, let direct = streamURL(forPartKey: key) {
            return (direct, false)
        }
        return nil
    }

    /// Builds Plex's universal-transcoder HLS URL for an item. The returned
    /// `start.m3u8` and its segments are produced on demand by the server and
    /// are fully seekable in AVPlayer. Identity + token travel as query params
    /// because the transcoder reads them from the query string for HLS sessions.
    func transcodeURL(
        ratingKey: String,
        sessionID: String,
        mediaIndex: Int = 0,
        partIndex: Int = 0
    ) -> URL? {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "path", value: "/library/metadata/\(ratingKey)"),
            URLQueryItem(name: "mediaIndex", value: String(mediaIndex)),
            URLQueryItem(name: "partIndex", value: String(partIndex)),
            URLQueryItem(name: "protocol", value: "hls"),
            URLQueryItem(name: "fastSeek", value: "1"),
            URLQueryItem(name: "directPlay", value: "0"),
            URLQueryItem(name: "directStream", value: "1"),
            URLQueryItem(name: "subtitleSize", value: "100"),
            URLQueryItem(name: "audioBoost", value: "100"),
            URLQueryItem(name: "location", value: "lan"),
            URLQueryItem(name: "autoAdjustQuality", value: "0"),
            URLQueryItem(name: "mediaBufferSize", value: "102400"),
            URLQueryItem(name: "session", value: sessionID),
            URLQueryItem(name: "X-Plex-Session-Identifier", value: sessionID)
        ]
        for (name, value) in deviceProfile.headers(token: token) where name.hasPrefix("X-Plex-") {
            query.append(URLQueryItem(name: name, value: value))
        }
        return absoluteURL(serverPath: "/video/:/transcode/universal/start.m3u8", extraQuery: query)
    }

    /// Builds an absolute, token-bearing image URL for a server-relative art
    /// path (`thumb`/`art`), routed through Plex's photo transcoder so tvOS gets
    /// an appropriately sized image.
    func imageURL(path: String?, maxWidth: Int?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        guard let width = maxWidth else {
            return absoluteURL(serverPath: path, extraQuery: [URLQueryItem(name: "X-Plex-Token", value: token)])
        }
        let height = Int(Double(width) * 1.5)
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = basePath + "/photo/:/transcode"
        // The inner `url` the transcoder fetches must carry its own token (the
        // photo transcoder makes an authenticated internal request) and must be
        // percent-encoded so its query string isn't merged into the outer one —
        // without the inner token the transcoder fetch is unauthorized and the
        // poster/background comes back blank.
        let innerURL = "\(path)?X-Plex-Token=\(token)"
        let encodedInner = innerURL.addingPercentEncoding(withAllowedCharacters: .plexQueryValueAllowed) ?? innerURL
        components.percentEncodedQueryItems = [
            URLQueryItem(name: "width", value: String(width)),
            URLQueryItem(name: "height", value: String(height)),
            URLQueryItem(name: "minSize", value: "1"),
            URLQueryItem(name: "upscale", value: "1"),
            URLQueryItem(name: "url", value: encodedInner),
            URLQueryItem(name: "X-Plex-Token", value: token)
        ]
        return components.url
    }

    // MARK: Direct-play capability

    /// Containers AVFoundation can demux from a direct file URL on tvOS.
    ///
    /// Kept to the MP4 family (`mp4`/`m4v`/`mov`) that AVFoundation demuxes
    /// reliably from a plain file URL. We deliberately do **not** add `mpegts`:
    /// AVFoundation's progressive-file demux of raw `.ts` is unreliable on tvOS
    /// (no index → broken seeking), so transport-stream parts are better served
    /// by Plex's HLS transcode, which repackages them into a seekable playlist.
    private static let directPlayContainers: Set<String> = ["mp4", "m4v", "mov"]

    /// Containers AVPlayer can't reliably direct-play from a raw file URL but the
    /// hybrid engine can decode on-device. Only eligible when
    /// `hybridEngineEnabled`.
    private static let hybridDirectPlayContainers: Set<String> = [
        "mkv", "webm", "matroska",
        "ts", "m2ts", "mts", "m2t", "mpegts", "bdav", "bdmv"
    ]

    /// Lossy audio codecs the Apple TV always decodes in software, regardless of
    /// the connected receiver. These never need passthrough, so they're always
    /// direct-playable. FLAC is lossless but AVFoundation has decoded it natively
    /// since tvOS 11, so it also belongs here.
    private static let alwaysDecodableAudioCodecs: Set<String> = ["aac", "mp3", "alac", "flac"]

    /// True only when we can prove the original file plays natively in AVPlayer
    /// on **this** device + display/audio route. Unknown/missing container or
    /// codec info, an unsupported codec for the current hardware, or HDR/Dolby
    /// Vision the display can't accept all fall back to a server transcode
    /// (matching server-side decisioning).
    ///
    /// When `hybridEngineEnabled`, also accepts the extra formats the on-device
    /// engine handles: hybrid-only containers (Matroska/WebM/TS-family),
    /// interlaced video, and DTS/DTS-HD/TrueHD/Opus/Vorbis audio (decoded
    /// on-device).
    func canDirectPlay(media: PlexMedia, part: PlexPart) -> Bool {
        let container = (media.container ?? part.container ?? Self.containerExtension(fromKey: part.key))?.lowercased()
        guard let container else { return false }

        let isAppleContainer = Self.directPlayContainers.contains(container)
        let isHybridContainer = hybridEngineEnabled && Self.hybridDirectPlayContainers.contains(container)
        guard isAppleContainer || isHybridContainer else { return false }

        let videoStream = part.Stream?.first(where: { $0.streamType == 1 })
        if Self.isInterlaced(videoStream), !hybridEngineEnabled {
            return false
        }

        // Video codec gate. Apple containers must be a hardware-decodable codec;
        // the hybrid engine demuxes/decodes the broad set inside hybrid-only
        // containers, so the
        // codec is left to VLCKit there (the SDR range gate below still applies).
        if !isHybridContainer, let video = media.videoCodec?.lowercased() {
            guard let mapped = Self.directPlayVideoCodec(forPlexCodec: video),
                  capabilities.allowedDirectPlayVideoCodecs.contains(mapped) else { return false }
        }

        if let audio = media.audioCodec?.lowercased(), !canDirectPlayAudio(codec: audio) {
            return false
        }

        if isHybridContainer {
            guard isHybridDirectPlayableRange(part: part) else { return false }
        } else {
            guard canDirectPlayVideoRange(part: part) else { return false }
        }

        return true
    }

    /// Maps a Plex `videoCodec` token onto a `MediaCapabilities` direct-play
    /// codec. Plex labels HEVC as either `hevc` or `h265`; both fold to `.hevc`.
    /// Returns `nil` for codecs that are never direct-playable (e.g. mpeg2,
    /// vc1), forcing a transcode.
    static func directPlayVideoCodec(forPlexCodec codec: String) -> DirectPlayVideoCodec? {
        switch codec {
        case "h264", "avc": return .h264
        case "hevc", "h265": return .hevc
        case "av1", "av01": return .av1
        default: return nil
        }
    }

    /// Whether an audio codec can be sent untouched to the output: either it's a
    /// codec the Apple TV always decodes itself (`aac`/`mp3`/`alac`), or it's a
    /// passthrough/bitstream codec the **current route** can carry. AC-3/E-AC-3
    /// are always passthrough-eligible; DTS / DTS-HD only when the route reports
    /// `supportsDTSPassthrough`, since Apple TV cannot decode DTS itself.
    ///
    /// When `hybridEngineEnabled`, DTS / DTS-HD / TrueHD are additionally accepted
    /// even without passthrough, because the on-device VLCKit engine decodes them
    /// (the router sends these to the hybrid engine).
    private func canDirectPlayAudio(codec: String) -> Bool {
        if Self.alwaysDecodableAudioCodecs.contains(codec) { return true }
        if hybridEngineEnabled, Self.isHybridDecodableAudio(codec) { return true }
        guard let passthrough = Self.passthroughAudioCodec(forPlexCodec: codec) else { return false }
        return capabilities.allowedPassthroughAudioCodecs.contains(passthrough)
    }

    /// DTS / DTS-HD / TrueHD / Opus / Vorbis: audio the on-device Plozzigen engine
    /// decodes regardless of the connected receiver's passthrough support.
    static func isHybridDecodableAudio(_ codec: String) -> Bool {
        let codec = codec.lowercased()
        return codec.contains("dts") || codec == "dca" || codec.hasPrefix("dca")
            || codec.contains("truehd") || codec == "mlp"
            || codec == "opus" || codec == "vorbis"   // Plozzigen decodes these; AVPlayer can't in Apple containers
    }

    /// Maps a Plex `audioCodec` token onto a `MediaCapabilities` passthrough
    /// codec. Plex labels DTS variants as `dca`/`dts` (core) and `dca-ma`/
    /// `dts-hd`/`dtshd` (lossless), so both fold onto the DTS cases. Returns
    /// `nil` for codecs that aren't passthrough-eligible.
    static func passthroughAudioCodec(forPlexCodec codec: String) -> PassthroughAudioCodec? {
        switch codec {
        case "ac3": return .ac3
        case "eac3", "ec3": return .eac3
        case "dts", "dca": return .dts
        case "dts-hd", "dtshd", "dca-ma": return .dtsHD
        default: return nil
        }
    }

    static func isInterlaced(_ stream: PlexStream?) -> Bool {
        guard let scanType = stream?.scanType?.lowercased(), !scanType.isEmpty else { return false }
        return scanType.contains("interlac")
    }

    /// Gates direct play on the video stream's HDR/Dolby Vision range against
    /// what the display can accept (`capabilities.allowedHDRRanges`).
    ///
    /// Policy (mirrors `MediaCapabilities`):
    ///   * Dolby Vision is direct-played only for single-layer **Profile 5** and
    ///     **Profile 8** *and* only when the display accepts Dolby Vision. An
    ///     unknown DoVi profile is treated conservatively (transcode) rather than
    ///     assumed to be P5/P8; Profile 7 (dual-layer) always transcodes.
    ///   * Plain HDR10 (PQ) / HLG are direct-played only when the display
    ///     advertises that range. We never special-case HDR10+ (it plays as its
    ///     HDR10 base, already covered by `.hdr10`).
    ///   * SDR or absent range info is always allowed (the codec gate already ran).
    private func canDirectPlayVideoRange(part: PlexPart) -> Bool {
        guard let video = part.Stream?.first(where: { $0.streamType == 1 }) else { return true }
        let allowed = Set(capabilities.allowedHDRRanges)

        if video.DOVIPresent == true {
            guard let profile = video.DOVIProfile else { return false }
            guard profile == 5 || profile == 8 else { return false }
            let doviRanges: Set<HDRRange> = [.dolbyVision, .dolbyVisionWithHDR10, .dolbyVisionWithHLG, .dolbyVisionWithSDR]
            return !allowed.isDisjoint(with: doviRanges)
        }

        switch video.colorTrc?.lowercased() {
        case "smpte2084", "pq":
            return allowed.contains(.hdr10)
        case "arib-std-b67", "hlg":
            return allowed.contains(.hlg)
        default:
            return true
        }
    }

    /// Range gate for a raw MKV sent to the on-device engine: allows SDR and any
    /// **display-supported** range, including HDR10 / HLG **and Dolby Vision** —
    /// the on-device engine decodes the HEVC base layer (HDR10/SDR base for
    /// Profile 8, tone-mapped for Profile 5), so DoVi-in-MKV plays without the
    /// unreliable server transcode AVPlayer would otherwise need (it can't demux
    /// MKV). Matches Infuse and mirrors `EngineRouter` (DoVi-in-MKV → hybrid).
    private func isHybridDirectPlayableRange(part: PlexPart) -> Bool {
        guard let video = part.Stream?.first(where: { $0.streamType == 1 }) else { return true }
        let allowed = Set(capabilities.allowedHDRRanges)
        if video.DOVIPresent == true {
            // Decoded on-device whenever the display supports Dolby Vision (which,
            // on an Apple TV 4K, tracks HEVC hardware decode — effectively always).
            let doviRanges: Set<HDRRange> = [.dolbyVision, .dolbyVisionWithHDR10, .dolbyVisionWithHLG, .dolbyVisionWithSDR]
            return !allowed.isDisjoint(with: doviRanges)
        }
        switch video.colorTrc?.lowercased() {
        case "smpte2084", "pq":
            return allowed.contains(.hdr10)
        case "arib-std-b67", "hlg":
            return allowed.contains(.hlg)
        default:
            return true
        }
    }

    /// Best-effort container guess from a part key's file extension
    /// (`/library/parts/2/16000/file.mkv` → `mkv`).
    static func containerExtension(fromKey key: String?) -> String? {
        guard let key,
              let lastSegment = key.split(separator: "/").last,
              lastSegment.contains("."),
              let ext = lastSegment.split(separator: ".").last else { return nil }
        return String(ext)
    }

    // MARK: Helpers

    private func containerQuery(start: Int, size: Int) -> [URLQueryItem] {
        [
            URLQueryItem(name: "X-Plex-Container-Start", value: String(start)),
            URLQueryItem(name: "X-Plex-Container-Size", value: String(size)),
            // Ask Plex to inline each item's external `Guid` array (imdb://,
            // tmdb://, anidb://, …) on list responses too — without this flag
            // list endpoints omit it, so rail/grid items would reach the
            // metadata router with no external ids to match (or detect anime) by.
            URLQueryItem(name: "includeGuids", value: "1")
            // NOTE: `includeElements=Stream` (which inlines the per-`<Stream>`
            // array for DoVi/HDR badges) is intentionally NOT added here. It is
            // appended per-request by `decodeStreamEnriched`, which retries
            // without it when a server rejects the flag (some PMS versions 500 on
            // it). Baking it into the shared query would make that single point of
            // failure poison every list endpoint with no fallback.
        ]
    }

    /// Maps provider-agnostic browse sorting to Plex's `sort` query language
    /// (`field:asc|desc`, with `random` as a standalone key).
    private static func sortQuery(for sort: CoreModels.SortDescriptor) -> String {
        let field: String
        switch sort.field {
        case .name:
            field = "titleSort"
        case .dateAdded:
            field = "addedAt"
        case .releaseDate:
            field = "originallyAvailableAt"
        case .communityRating:
            field = "rating"
        case .runtime:
            field = "duration"
        case .random:
            return "random"
        }
        let direction = (sort.direction == .ascending) ? "asc" : "desc"
        return "\(field):\(direction)"
    }

    private func absoluteURL(serverPath path: String, extraQuery: [URLQueryItem]) -> URL? {
        // An already-absolute path (rare) is returned as-is.
        if let absolute = URL(string: path), absolute.scheme != nil { return absolute }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        if let pathComponents = URLComponents(string: path) {
            components.path = basePath + pathComponents.path
            components.queryItems = (pathComponents.queryItems ?? []) + extraQuery
        } else {
            components.path = basePath + path
            components.queryItems = extraQuery
        }
        return components.url
    }
}

private extension CharacterSet {
    /// RFC 3986 unreserved characters only — used to fully percent-encode a value
    /// (including `/ ? & = :`) that is being nested inside another query string.
    static let plexQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}
