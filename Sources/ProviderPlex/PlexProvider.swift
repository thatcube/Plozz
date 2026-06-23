import Foundation
import CoreModels
import CoreNetworking

/// `MediaProvider` conformer for Plex.
///
/// Holds an authenticated `PlexClient` and maps Plex `Metadata`/`Directory`
/// onto the provider-agnostic `CoreModels` types. Feature modules depend only on
/// `MediaProvider`; this is the single place Plex specifics live.
public struct PlexProvider: MediaProvider {
    public let kind: ProviderKind = .plex
    public let session: UserSession
    private let client: PlexClient

    public init(
        session: UserSession,
        http: HTTPClient = URLSessionHTTPClient(),
        hybridEngineEnabled: Bool = false,
        connectionRefresh: PlexConnectionResolver.Refresh? = nil,
        probe: HTTPClient = URLSessionHTTPClient(session: .plozzDiscovery)
    ) {
        self.session = session
        let deviceProfile = PlexDeviceProfile(clientIdentifier: session.deviceID)
        // Probe the persisted connection list (or the single saved URL) and stay
        // on whichever is reachable. With only one candidate and no refresh this
        // is a no-op — behaviour matches a fixed URL.
        let candidates = session.server.connectionURLs?.isEmpty == false
            ? session.server.connectionURLs!
            : [session.server.baseURL]
        let resolver = PlexConnectionResolver(
            candidates: candidates,
            deviceProfile: deviceProfile,
            token: session.accessToken,
            probe: probe,
            refresh: connectionRefresh
        )
        self.client = PlexClient(
            resolver: resolver,
            deviceProfile: deviceProfile,
            token: session.accessToken,
            http: http,
            hybridEngineEnabled: hybridEngineEnabled
        )
    }

    /// Builds the plex.tv connection-refresh closure for a session: when every
    /// connection Plozz knows about for this server is unreachable, re-fetch the
    /// account's current (reachable-ordered) connection list from plex.tv. Lets a
    /// server that has changed networks since the account was added heal itself
    /// without the user re-adding it. Returns `[]` on any failure so the resolver
    /// falls back gracefully.
    public static func connectionRefresh(for session: UserSession) -> PlexConnectionResolver.Refresh {
        let serverID = session.server.id
        let token = session.accessToken
        let deviceID = session.deviceID
        return {
            let client = PlexAuthClient(deviceProfile: PlexDeviceProfile(clientIdentifier: deviceID))
            return (try? await client.connectionURLs(forServerID: serverID, authToken: token)) ?? []
        }
    }

    // MARK: Browsing

    public func libraries() async throws -> [MediaLibrary] {
        try await client.sections().compactMap { dir in
            guard let id = dir.key else { return nil }
            return MediaLibrary(
                id: id,
                title: dir.title ?? "Library",
                kind: Self.kind(forSectionType: dir.type),
                imageURL: client.imageURL(path: dir.thumb ?? dir.composite, maxWidth: 400)
            )
        }
    }

    public func continueWatching(limit: Int) async throws -> [MediaItem] {
        try await client.onDeck(limit: limit).map(map(metadata:))
    }

    public func latest(limit: Int) async throws -> [MediaItem] {
        try await client.recentlyAdded(limit: limit).map(map(metadata:))
    }

    public func item(id: String) async throws -> MediaItem {
        map(metadata: try await client.metadata(ratingKey: id))
    }

    public func trailers(for itemID: String) async throws -> [MediaItem] {
        try await client.extras(ratingKey: itemID)
            .filter { ($0.subtype ?? "").lowercased() == "trailer" }
            .map(map(metadata:))
    }

    public func children(of itemID: String) async throws -> [MediaItem] {
        try await client.children(ratingKey: itemID).map(map(metadata:))
    }

    public func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        let type = Self.sectionType(forContainerKind: kind)
        PlozzLog.networking.info(
            "Plex library browse: section=\(containerID) kind=\(kind.rawValue) type=\(type.map(String.init) ?? "-") start=\(page.startIndex) size=\(page.limit)"
        )
        do {
            let container = try await client.sectionItems(
                sectionID: containerID,
                type: type,
                start: page.startIndex,
                size: page.limit
            )
            let items = (container.Metadata ?? []).map(map(metadata:))
            let total = container.totalSize ?? container.size ?? (page.startIndex + items.count)
            PlozzLog.networking.info("Plex library browse: section=\(containerID) returned=\(items.count) total=\(total)")
            return MediaPage(items: items, startIndex: page.startIndex, totalCount: total)
        } catch {
            PlozzLog.networking.error("Plex library browse failed: section=\(containerID) error=\(String(describing: error))")
            throw error
        }
    }

    // MARK: Search

    public func search(query: String, limit: Int) async throws -> [MediaItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return try await client.search(query: trimmed, limit: limit)
            .map(map(metadata:))
            .filter { $0.kind == .movie || $0.kind == .series || $0.kind == .episode }
    }

    // MARK: Playback

    public func playbackInfo(for itemID: String) async throws -> PlaybackRequest {
        try await playbackInfo(for: itemID, forceTranscode: false)
    }

    public func playbackInfo(for itemID: String, forceTranscode: Bool) async throws -> PlaybackRequest {
        let detail = try await client.metadata(ratingKey: itemID)
        guard let media = detail.Media?.first,
              let part = media.Part?.first else {
            throw AppError.notFound
        }
        // A stable per-(device,item) session id ties the transcode m3u8 to its
        // segments; deterministic so it's traceable and testable.
        let transcodeSessionID = "plozz-\(session.deviceID)-\(itemID)"
        guard let resolved = client.playbackURL(
            ratingKey: itemID,
            media: media,
            part: part,
            sessionID: transcodeSessionID,
            forceTranscode: forceTranscode
        ) else {
            throw AppError.notFound
        }
        let mappedItem = map(metadata: detail)
        let streams = part.Stream ?? []
        let audio = streams.filter { $0.streamType == 2 }.map(map(stream:))
        let subs = streams.filter { $0.streamType == 3 }.map(map(stream:))

        return PlaybackRequest(
            item: mappedItem,
            streamURL: resolved.url,
            // Plex correlates timeline reports by ratingKey; a per-play session
            // id isn't required, so reuse the item id for traceability.
            playSessionID: itemID,
            audioTracks: audio,
            subtitleTracks: subs,
            startPosition: mappedItem.resumePosition ?? 0,
            isTranscoding: resolved.isTranscoding,
            sourceMetadata: Self.sourceMetadata(
                container: media.container ?? part.container,
                streams: streams
            )
        )
    }

    /// Plex reports bitrates in kbps; the diagnostics model wants bits/sec.
    private static func bps(fromKbps kbps: Int?) -> Int? {
        guard let kbps, kbps > 0 else { return nil }
        return kbps * 1000
    }

    /// Builds provider-agnostic source facts from a Plex part's streams so the
    /// diagnostics overlay matches what a direct-play client (e.g. Infuse) shows.
    static func sourceMetadata(container: String?, streams: [PlexStream]) -> MediaSourceMetadata? {
        let video = streams.first { $0.streamType == 1 }
        let audio = streams.first { ($0.streamType == 2) && ($0.selected ?? $0.default ?? false) }
            ?? streams.first { $0.streamType == 2 }
        let subtitle = streams.first { ($0.streamType == 3) && ($0.selected ?? false) }
            ?? streams.first { $0.streamType == 3 }

        let videoStream = video.map { v in
            // Plex only surfaces Dolby Vision explicitly (`DOVIPresent`); infer
            // HDR10/HLG from the transfer characteristics so non-DV HDR still
            // earns a badge. `smpte2084` is the PQ (HDR10) curve; `arib-std-b67`
            // is HLG.
            let dovi = v.DOVIPresent ?? false
            let trc = (v.colorTrc ?? "").lowercased()
            let rangeType: String?
            if dovi {
                rangeType = "DOVI"
            } else if trc.contains("2084") || trc.contains("pq") {
                rangeType = "HDR10"
            } else if trc.contains("b67") || trc.contains("hlg") {
                rangeType = "HLG"
            } else {
                rangeType = nil
            }
            return MediaSourceMetadata.VideoStream(
                codec: v.codec,
                profile: v.profile,
                width: v.width,
                height: v.height,
                bitrate: bps(fromKbps: v.bitrate),
                frameRate: v.frameRate,
                videoRange: rangeType == nil ? nil : (dovi ? "DOVI" : "HDR"),
                videoRangeType: rangeType,
                colorTransfer: v.colorTrc
            )
        }
        let audioStream = audio.map { a in
            // Plex doesn't expose an explicit object-based-audio flag on basic
            // metadata; Atmos/DTS:X only appear in the (extended) display title,
            // e.g. "Dolby TrueHD Atmos 7.1" or "DTS-HD MA → DTS:X 7.1". Fold that
            // hint into the profile so the shared badge logic can surface the
            // Dolby Atmos / DTS:X headline badge.
            let title = (a.extendedDisplayTitle ?? a.displayTitle ?? "").lowercased()
            var profileParts = [a.profile].compactMap { $0 }
            if title.contains("atmos") { profileParts.append("Atmos") }
            if title.contains("dts:x") || title.contains("dts-x") || title.contains("dtsx") {
                profileParts.append("DTS:X")
            }
            let profile = profileParts.isEmpty ? nil : profileParts.joined(separator: " ")
            return MediaSourceMetadata.AudioStream(
                codec: a.codec,
                profile: profile,
                channels: a.channels,
                channelLayout: a.audioChannelLayout,
                sampleRate: a.samplingRate,
                bitrate: bps(fromKbps: a.bitrate),
                language: a.languageTag ?? a.language
            )
        }
        let subtitleStream = subtitle.map { s in
            MediaSourceMetadata.SubtitleStream(
                codec: s.codec,
                language: s.languageTag ?? s.language,
                title: s.extendedDisplayTitle ?? s.displayTitle
            )
        }

        let metadata = MediaSourceMetadata(
            container: container,
            video: videoStream,
            audio: audioStream,
            subtitle: subtitleStream
        )
        return metadata.isEmpty ? nil : metadata
    }

    public func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {
        let state: String
        switch event {
        case .pause: state = "paused"
        case .stop: state = "stopped"
        default: state = "playing"
        }
        try await client.reportTimeline(
            ratingKey: progress.itemID,
            state: state,
            timeMs: PlexTime.milliseconds(fromSeconds: progress.positionSeconds),
            durationMs: nil
        )
    }

    public func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? {
        // Plex serves art by URL path, not by item id alone, so a standalone
        // lookup isn't possible here — artwork URLs are resolved during mapping.
        nil
    }

    // MARK: - Mapping

    private func map(metadata dto: PlexMetadata) -> MediaItem {
        let kind = Self.kind(forItemType: dto.type)
        let isEpisode = kind == .episode
        // For an episode, the series title is the grandparent; otherwise the
        // immediate parent (e.g. a season's show, a movie has none).
        let parentTitle = isEpisode ? (dto.grandparentTitle ?? dto.parentTitle) : dto.parentTitle
        let posterPath = isEpisode ? (dto.grandparentThumb ?? dto.thumb) : dto.thumb
        let viewCount = dto.viewCount ?? 0

        let runtime = PlexTime.seconds(fromMilliseconds: dto.duration)
        let resume = PlexTime.seconds(fromMilliseconds: dto.viewOffset)
        let percentage: Double?
        if let runtime, runtime > 0, let resume {
            percentage = min(1, max(0, resume / runtime))
        } else if viewCount > 0 {
            percentage = 1
        } else {
            percentage = nil
        }

        return MediaItem(
            id: dto.ratingKey ?? "",
            title: dto.title ?? "Untitled",
            kind: kind,
            overview: dto.summary,
            parentTitle: parentTitle,
            seasonNumber: isEpisode ? dto.parentIndex : nil,
            episodeNumber: isEpisode ? dto.index : nil,
            productionYear: dto.year,
            officialRating: dto.contentRating,
            genres: dto.Genre?.compactMap(\.tag) ?? [],
            seriesID: isEpisode ? dto.grandparentRatingKey : nil,
            seasonID: isEpisode ? dto.parentRatingKey : nil,
            runtime: runtime,
            resumePosition: resume,
            playedPercentage: percentage,
            isPlayed: viewCount > 0 && (resume ?? 0) == 0,
            posterURL: client.imageURL(path: posterPath, maxWidth: 500),
            seriesPosterURL: isEpisode ? client.imageURL(path: dto.grandparentThumb, maxWidth: 500) : nil,
            backdropURL: client.imageURL(path: dto.art, maxWidth: 1280),
            heroBackdropURL: client.imageURL(path: dto.art, maxWidth: 3840),
            ratings: Self.ratings(from: dto),
            providerIDs: Self.providerIDs(from: dto),
            mediaInfo: Self.sourceMetadata(from: dto)
        )
    }

    /// Maps Plex `Guid` values (`imdb://...`, `tmdb://...`, …) into the shared
    /// `MediaItem.providerIDs` shape used by artwork and ratings enrichment. The
    /// keys mirror Jellyfin's casing (`Imdb`, `Tmdb`, `AniList`, …) so the
    /// content classifier and `ArtworkRouter` resolve Plex and Jellyfin items the
    /// same way.
    static func providerIDs(from dto: PlexMetadata) -> [String: String] {
        var ids: [String: String] = [:]
        for guid in dto.Guid ?? [] {
            guard let raw = guid.id?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let schemeRange = raw.range(of: "://")
            else { continue }
            let scheme = raw[..<schemeRange.lowerBound].lowercased()
            let value = String(raw[schemeRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            switch scheme {
            case "imdb":
                if ids["Imdb"] == nil { ids["Imdb"] = value }
            case "tmdb", "themoviedb":
                if ids["Tmdb"] == nil { ids["Tmdb"] = value }
            case "tvdb", "thetvdb":
                if ids["Tvdb"] == nil { ids["Tvdb"] = value }
            case "tvmaze":
                if ids["Tvmaze"] == nil { ids["Tvmaze"] = value }
            case "anidb":
                if ids["AniDB"] == nil { ids["AniDB"] = value }
            case "anilist":
                if ids["AniList"] == nil { ids["AniList"] = value }
            case "myanimelist", "mal":
                if ids["Mal"] == nil { ids["Mal"] = value }
            case "mbid":
                if ids["MusicBrainzRelease"] == nil { ids["MusicBrainzRelease"] = value }
            default:
                continue
            }
        }
        return ids
    }

    /// Builds the playable source's technical metadata from an item's first
    /// media part, so movie/episode detail heroes can show resolution/HDR/audio
    /// badges. Returns `nil` for containers (shows/seasons) that have no part.
    static func sourceMetadata(from dto: PlexMetadata) -> MediaSourceMetadata? {
        guard let media = dto.Media?.first else { return nil }
        let part = media.Part?.first
        let streams = part?.Stream ?? []
        if !streams.isEmpty {
            return sourceMetadata(container: part?.container ?? media.container, streams: streams)
        }
        // List/children responses can omit the per-stream array; fall back to the
        // coarser Media-level facts so episode rails still earn resolution/audio
        // badges (HDR/Atmos need the stream detail and are simply absent here).
        return mediaLevelMetadata(from: media)
    }

    /// A coarse `MediaSourceMetadata` from Plex's Media-element attributes, used
    /// when the richer per-stream data isn't present in a listing.
    static func mediaLevelMetadata(from media: PlexMedia) -> MediaSourceMetadata? {
        let lines: Int?
        switch (media.videoResolution ?? "").lowercased() {
        case "4k": lines = 2160
        case "1080": lines = 1080
        case "720": lines = 720
        case "480", "576", "sd": lines = 480
        default: lines = media.height
        }
        let video: MediaSourceMetadata.VideoStream?
        if media.width != nil || lines != nil || media.videoCodec != nil {
            video = MediaSourceMetadata.VideoStream(
                codec: media.videoCodec,
                profile: media.videoProfile,
                width: media.width,
                height: lines
            )
        } else {
            video = nil
        }
        let audio: MediaSourceMetadata.AudioStream?
        if media.audioCodec != nil || media.audioChannels != nil {
            audio = MediaSourceMetadata.AudioStream(
                codec: media.audioCodec,
                channels: media.audioChannels
            )
        } else {
            audio = nil
        }
        let metadata = MediaSourceMetadata(container: media.container, video: video, audio: audio)
        return metadata.isEmpty ? nil : metadata
    }

    /// Maps Plex's native rating fields onto provider-agnostic ratings. Plex
    /// normalises every source to a 0–10 scale and names the source via the
    /// rating image (`rottentomatoes://…`, `imdb://…`). Rotten Tomatoes scores
    /// are rendered as the familiar percentage; user/critic scores stay 0–10.
    static func ratings(from dto: PlexMetadata) -> [ExternalRating] {
        var ratings: [ExternalRating] = []
        if let critic = dto.rating {
            let image = (dto.ratingImage ?? "").lowercased()
            if image.contains("rottentomatoes") {
                ratings.append(ExternalRating(source: .rottenTomatoes, value: critic * 10, scale: .percent))
            } else if image.contains("imdb") {
                ratings.append(ExternalRating(source: .imdb, value: critic, scale: .outOfTen))
            } else {
                ratings.append(ExternalRating(source: .critic, value: critic, scale: .outOfTen))
            }
        }
        if let audience = dto.audienceRating {
            let image = (dto.audienceRatingImage ?? "").lowercased()
            if image.contains("rottentomatoes") {
                ratings.append(ExternalRating(source: .rottenTomatoesAudience, value: audience * 10, scale: .percent))
            } else if image.contains("imdb") {
                ratings.append(ExternalRating(source: .imdb, value: audience, scale: .outOfTen))
            } else {
                ratings.append(ExternalRating(source: .community, value: audience, scale: .outOfTen))
            }
        }
        return ratings
    }

    private func map(stream dto: PlexStream) -> MediaTrack {
        let language = dto.languageTag ?? dto.language
        let isSubtitle = dto.streamType == 3
        // External/sidecar subtitles expose a `key` we can fetch as text and
        // normalise to WebVTT for the native picker. Embedded subs (no key) and
        // image-based subs can't be delivered this way.
        let deliveryURL: URL? = (isSubtitle && isTextSubtitleCodec(dto.codec))
            ? dto.key.flatMap { client.streamURL(forPartKey: $0) }
            : nil
        return MediaTrack(
            id: dto.index ?? dto.id ?? 0,
            kind: isSubtitle ? .subtitle : .audio,
            displayTitle: dto.extendedDisplayTitle ?? dto.displayTitle ?? language ?? dto.codec ?? "Track",
            language: language,
            isDefault: dto.default ?? dto.selected ?? false,
            isForced: dto.forced ?? false,
            deliveryURL: deliveryURL
        )
    }

    /// Whether a Plex subtitle codec token is text-based (deliverable as WebVTT).
    private func isTextSubtitleCodec(_ codec: String?) -> Bool {
        guard let codec = codec?.lowercased() else { return false }
        return ["srt", "subrip", "ass", "ssa", "webvtt", "vtt", "mov_text", "text", "ttml", "smi", "sami"].contains(codec)
    }

    private static func kind(forItemType type: String?) -> MediaItemKind {
        switch type {
        case "movie": return .movie
        case "show": return .series
        case "season": return .season
        case "episode": return .episode
        case "clip", "video": return .video
        case "collection": return .collection
        default: return .unknown
        }
    }

    private static func kind(forSectionType type: String?) -> MediaItemKind {
        switch type {
        case "movie": return .movie
        case "show": return .series
        default: return .folder
        }
    }

    /// Plex `type` query value for a library section's content kind, used by the
    /// paged `/all` query (1 = movie, 2 = show).
    private static func sectionType(forContainerKind kind: MediaItemKind) -> Int? {
        switch kind {
        case .movie: return 1
        case .series: return 2
        default: return nil
        }
    }
}

// MARK: - Watched state

extension PlexProvider: WatchStateProviding {
    /// Toggles an item's watched state via Plex scrobble/unscrobble. Scrobbling a
    /// season or series ratingKey marks the contained episodes too.
    public func setPlayed(_ played: Bool, itemID: String) async throws {
        try await client.setWatched(played, ratingKey: itemID)
    }
}
