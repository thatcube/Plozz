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

    public init(
        baseURL: URL,
        deviceProfile: PlexDeviceProfile,
        token: String,
        http: HTTPClient = URLSessionHTTPClient(),
        capabilities: MediaCapabilities = .detected(),
        hybridEngineEnabled: Bool = false
    ) {
        self.baseURL = baseURL
        self.deviceProfile = deviceProfile
        self.token = token
        self.http = http
        self.capabilities = capabilities
        self.hybridEngineEnabled = hybridEngineEnabled
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

    /// `GET /library/metadata/{ratingKey}/extras` — trailers and other extras
    /// (behind-the-scenes, deleted scenes, …) attached to an item. Each extra is
    /// a `clip` with its own ratingKey that streams through the normal playback
    /// path. Callers filter by `subtype` to keep only trailers.
    func extras(ratingKey: String) async throws -> [PlexMetadata] {
        let endpoint = Endpoint(path: "/library/metadata/\(ratingKey)/extras", headers: headers)
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
        if canDirectPlay(media: media, part: part), let key = part.key, let direct = streamURL(forPartKey: key) {
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
    ///
    /// Kept to the MP4 family (`mp4`/`m4v`/`mov`) that AVFoundation demuxes
    /// reliably from a plain file URL. We deliberately do **not** add `mpegts`:
    /// AVFoundation's progressive-file demux of raw `.ts` is unreliable on tvOS
    /// (no index → broken seeking), so transport-stream parts are better served
    /// by Plex's HLS transcode, which repackages them into a seekable playlist.
    private static let directPlayContainers: Set<String> = ["mp4", "m4v", "mov"]

    /// Matroska-family containers AVPlayer can't demux but the hybrid (VLCKit)
    /// engine can. Only eligible for direct play when `hybridEngineEnabled`.
    private static let matroskaContainers: Set<String> = ["mkv", "webm", "matroska"]

    /// Lossy audio codecs the Apple TV always decodes in software, regardless of
    /// the connected receiver. These never need passthrough, so they're always
    /// direct-playable.
    private static let alwaysDecodableAudioCodecs: Set<String> = ["aac", "mp3", "alac"]

    /// True only when we can prove the original file plays natively in AVPlayer
    /// on **this** device + display/audio route. Unknown/missing container or
    /// codec info, an unsupported codec for the current hardware, or HDR/Dolby
    /// Vision the display can't accept all fall back to a server transcode
    /// (matching server-side decisioning).
    ///
    /// When `hybridEngineEnabled`, also accepts the extra formats the on-device
    /// VLCKit engine handles: an SDR Matroska/WebM file, and DTS/DTS-HD/TrueHD
    /// audio (decoded on-device). DoVi/HDR in an MKV is deliberately rejected so
    /// it transcodes to HLS and renders on AVPlayer — the router routes exactly
    /// this advertised set to a working engine (advertise ⇔ route lockstep).
    func canDirectPlay(media: PlexMedia, part: PlexPart) -> Bool {
        let container = (media.container ?? part.container ?? Self.containerExtension(fromKey: part.key))?.lowercased()
        guard let container else { return false }

        let isAppleContainer = Self.directPlayContainers.contains(container)
        let isMatroska = hybridEngineEnabled && Self.matroskaContainers.contains(container)
        guard isAppleContainer || isMatroska else { return false }

        // Video codec gate. Apple containers must be a hardware-decodable codec;
        // the hybrid engine demuxes/decodes the broad set inside Matroska, so the
        // codec is left to VLCKit there (the SDR range gate below still applies).
        if !isMatroska, let video = media.videoCodec?.lowercased() {
            guard let mapped = Self.directPlayVideoCodec(forPlexCodec: video),
                  capabilities.allowedDirectPlayVideoCodecs.contains(mapped) else { return false }
        }

        if let audio = media.audioCodec?.lowercased(), !canDirectPlayAudio(codec: audio) {
            return false
        }

        // Range gate. A raw MKV is direct-played on the on-device engine for SDR
        // and display-supported HDR10/HLG, but Dolby Vision still transcodes so it
        // renders on AVPlayer. Apple containers use the display-aware HDR policy.
        if isMatroska {
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
        case "av1": return .av1
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

    /// DTS / DTS-HD / TrueHD audio the on-device VLCKit engine decodes regardless
    /// of the connected receiver's passthrough support.
    static func isHybridDecodableAudio(_ codec: String) -> Bool {
        let codec = codec.lowercased()
        return codec.contains("dts") || codec == "dca" || codec.hasPrefix("dca")
            || codec.contains("truehd") || codec == "mlp"
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
