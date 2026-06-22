import Foundation
import CoreModels
import CoreNetworking

/// Low-level Plex Media Server REST client.
///
/// One instance is bound to a single server `baseURL` + `token`. It deals only
/// in DTOs; mapping to `CoreModels` happens in `PlexProvider`. Mirrors the role
/// of `JellyfinClient` for the Plex backend.
public struct PlexClient: Sendable {
    public let baseURL: URL
    private let deviceProfile: PlexDeviceProfile
    private let token: String
    private let http: HTTPClient

    public init(
        baseURL: URL,
        deviceProfile: PlexDeviceProfile,
        token: String,
        http: HTTPClient = URLSessionHTTPClient()
    ) {
        self.baseURL = baseURL
        self.deviceProfile = deviceProfile
        self.token = token
        self.http = http
    }

    private var headers: [String: String] { deviceProfile.headers(token: token) }

    // MARK: Browsing

    /// `GET /library/sections` — top-level libraries.
    func sections() async throws -> [PlexDirectory] {
        let endpoint = Endpoint(path: "/library/sections", headers: headers)
        return try await http.decode(PlexMediaContainerResponse.self, from: endpoint, baseURL: baseURL)
            .MediaContainer.Directory ?? []
    }

    /// `GET /library/onDeck` — Continue Watching.
    func onDeck(limit: Int) async throws -> [PlexMetadata] {
        let endpoint = Endpoint(
            path: "/library/onDeck",
            queryItems: containerQuery(start: 0, size: limit),
            headers: headers
        )
        return try await http.decode(PlexMediaContainerResponse.self, from: endpoint, baseURL: baseURL)
            .MediaContainer.Metadata ?? []
    }

    /// `GET /library/recentlyAdded` — newest items across libraries.
    func recentlyAdded(limit: Int) async throws -> [PlexMetadata] {
        let endpoint = Endpoint(
            path: "/library/recentlyAdded",
            queryItems: containerQuery(start: 0, size: limit),
            headers: headers
        )
        return try await http.decode(PlexMediaContainerResponse.self, from: endpoint, baseURL: baseURL)
            .MediaContainer.Metadata ?? []
    }

    /// `GET /library/metadata/{ratingKey}` — full detail for one item.
    func metadata(ratingKey: String) async throws -> PlexMetadata {
        let endpoint = Endpoint(path: "/library/metadata/\(ratingKey)", headers: headers)
        let container = try await http.decode(PlexMediaContainerResponse.self, from: endpoint, baseURL: baseURL).MediaContainer
        guard let item = container.Metadata?.first else { throw AppError.notFound }
        return item
    }

    /// `GET /library/metadata/{ratingKey}/children` — seasons of a show,
    /// episodes of a season, …
    func children(ratingKey: String) async throws -> [PlexMetadata] {
        let endpoint = Endpoint(path: "/library/metadata/\(ratingKey)/children", headers: headers)
        return try await http.decode(PlexMediaContainerResponse.self, from: endpoint, baseURL: baseURL)
            .MediaContainer.Metadata ?? []
    }

    /// `GET /library/sections/{id}/all` — one page of a library section, paged
    /// server-side with `X-Plex-Container-Start` / `X-Plex-Container-Size`.
    func sectionItems(
        sectionID: String,
        type: Int?,
        start: Int,
        size: Int
    ) async throws -> PlexMediaContainer {
        var query = containerQuery(start: start, size: size)
        if let type {
            query.append(URLQueryItem(name: "type", value: String(type)))
        }
        query.append(URLQueryItem(name: "sort", value: "titleSort"))
        let endpoint = Endpoint(path: "/library/sections/\(sectionID)/all", queryItems: query, headers: headers)
        return try await http.decode(PlexMediaContainerResponse.self, from: endpoint, baseURL: baseURL).MediaContainer
    }

    /// `GET /search?query=…` — global server search across libraries. Returns a
    /// flat `Metadata` list of matching movies/shows/episodes.
    func search(query: String, limit: Int) async throws -> [PlexMetadata] {
        var items = containerQuery(start: 0, size: limit)
        items.append(URLQueryItem(name: "query", value: query))
        let endpoint = Endpoint(path: "/search", queryItems: items, headers: headers)
        return try await http.decode(PlexMediaContainerResponse.self, from: endpoint, baseURL: baseURL)
            .MediaContainer.Metadata ?? []
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
        _ = try await http.send(endpoint, baseURL: baseURL)
    }

    // MARK: URLs

    /// Builds an absolute, token-bearing stream URL for a part `key` (which is
    /// already a server-relative `/library/parts/…/file.…` path). Used for
    /// direct play of a container/codec tvOS can demux natively.
    func streamURL(forPartKey key: String) -> URL? {
        absoluteURL(serverPath: key, extraQuery: [URLQueryItem(name: "X-Plex-Token", value: token)])
    }

    /// Resolves the playable URL for a media item, choosing **direct play** when
    /// tvOS/AVFoundation can demux the original container/codecs, and otherwise a
    /// server-side **HLS transcode** (Plex's universal transcoder).
    ///
    /// This mirrors what Jellyfin does server-side: a file in an unsupported
    /// container (e.g. MKV) or codec must be remuxed/transcoded to HLS, because
    /// AVPlayer cannot play it directly. Handing AVPlayer the raw MKV part was
    /// why Plex items "didn't play" while the same files played via Jellyfin.
    func playbackURL(ratingKey: String, media: PlexMedia, part: PlexPart, sessionID: String, forceTranscode: Bool = false) -> (url: URL, isTranscoding: Bool)? {
        // Forcing a transcode (player fallback after a failed direct play): skip
        // the direct-play path entirely and go straight to the universal
        // transcoder. If even that can't be built, fail rather than silently
        // handing back the same direct URL that just failed.
        if forceTranscode {
            if let transcode = transcodeURL(ratingKey: ratingKey, sessionID: sessionID) {
                return (transcode, true)
            }
            return nil
        }
        if Self.canDirectPlay(media: media, part: part), let key = part.key, let direct = streamURL(forPartKey: key) {
            return (direct, false)
        }
        if let transcode = transcodeURL(ratingKey: ratingKey, sessionID: sessionID) {
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
    func transcodeURL(ratingKey: String, sessionID: String) -> URL? {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "path", value: "/library/metadata/\(ratingKey)"),
            URLQueryItem(name: "mediaIndex", value: "0"),
            URLQueryItem(name: "partIndex", value: "0"),
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
    private static let directPlayContainers: Set<String> = ["mp4", "m4v", "mov"]
    /// Video codecs AVFoundation decodes on Apple TV.
    private static let directPlayVideoCodecs: Set<String> = ["h264", "hevc", "h265"]
    /// Audio codecs Apple TV can play (incl. passthrough).
    private static let directPlayAudioCodecs: Set<String> = ["aac", "ac3", "eac3", "mp3", "alac"]

    /// True only when we can prove the original file plays natively in AVPlayer.
    /// Unknown/missing container or codec info is treated as not direct-playable
    /// so we fall back to a server transcode (matching server-side decisioning).
    static func canDirectPlay(media: PlexMedia, part: PlexPart) -> Bool {
        let container = (media.container ?? part.container ?? containerExtension(fromKey: part.key))?.lowercased()
        guard let container, directPlayContainers.contains(container) else { return false }
        if let video = media.videoCodec?.lowercased(), !directPlayVideoCodecs.contains(video) { return false }
        if let audio = media.audioCodec?.lowercased(), !directPlayAudioCodecs.contains(audio) { return false }
        return true
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
            URLQueryItem(name: "X-Plex-Container-Size", value: String(size))
        ]
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
