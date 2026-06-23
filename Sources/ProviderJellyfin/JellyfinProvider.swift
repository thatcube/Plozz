import Foundation
import CoreModels
import CoreNetworking

/// `MediaProvider` conformer for Jellyfin.
///
/// Holds an authenticated `JellyfinClient` and maps Jellyfin DTOs onto the
/// provider-agnostic `CoreModels` types. Feature modules depend only on
/// `MediaProvider`; this is the single place Jellyfin specifics live.
public struct JellyfinProvider: MediaProvider {
    public let kind: ProviderKind = .jellyfin
    public let session: UserSession
    let client: JellyfinClient

    public init(
        session: UserSession,
        http: HTTPClient = URLSessionHTTPClient(),
        hybridEngineEnabled: Bool = false
    ) {
        self.session = session
        self.client = JellyfinClient(
            baseURL: session.server.baseURL,
            deviceProfile: JellyfinDeviceProfile(deviceID: session.deviceID),
            token: session.accessToken,
            http: http,
            capabilityProfile: .detected(hybridEngineEnabled: hybridEngineEnabled)
        )
    }

    // MARK: Browsing

    public func libraries() async throws -> [MediaLibrary] {
        try await client.userViews(userID: session.userID).map { dto in
            MediaLibrary(
                id: dto.Id,
                title: dto.Name ?? "Library",
                kind: Self.kind(forCollectionType: dto.CollectionType),
                imageURL: Self.imageURL(for: dto, kind: .primary, maxWidth: 400, client: client)
            )
        }
    }

    public func continueWatching(limit: Int) async throws -> [MediaItem] {
        try await client.resumeItems(userID: session.userID, limit: limit).map(map(item:))
    }

    public func latest(limit: Int) async throws -> [MediaItem] {
        try await client.latestItems(userID: session.userID, limit: limit).map(map(item:))
    }

    public func item(id: String) async throws -> MediaItem {
        map(item: try await client.item(userID: session.userID, id: id))
    }

    public func trailers(for itemID: String) async throws -> [MediaItem] {
        try await client.localTrailers(userID: session.userID, id: itemID).map(map(item:))
    }

    public func children(of itemID: String) async throws -> [MediaItem] {
        try await client.children(userID: session.userID, parentID: itemID).map(map(item:))
    }

    public func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        let (recursive, includeItemTypes) = Self.query(forContainerKind: kind)
        PlozzLog.networking.info(
            "Library browse: container=\(containerID) kind=\(kind.rawValue) recursive=\(recursive) types=\(includeItemTypes.joined(separator: ",")) start=\(page.startIndex) limit=\(page.limit) sort=\(page.sort.field.rawValue)/\(page.sort.direction.rawValue)"
        )
        do {
            let response = try await client.items(
                userID: session.userID,
                parentID: containerID,
                includeItemTypes: includeItemTypes,
                recursive: recursive,
                startIndex: page.startIndex,
                limit: page.limit,
                sort: page.sort
            )
            let items = response.Items.map(map(item:))
            PlozzLog.networking.info(
                "Library browse: container=\(containerID) returned=\(items.count) total=\(response.TotalRecordCount ?? -1)"
            )
            return MediaPage(
                items: items,
                startIndex: page.startIndex,
                totalCount: response.TotalRecordCount ?? (page.startIndex + items.count)
            )
        } catch {
            PlozzLog.networking.error("Library browse failed: container=\(containerID) error=\(String(describing: error))")
            throw error
        }
    }

    /// Picks the Jellyfin query strategy for a container kind. Typed libraries
    /// use the fast recursive/indexed path; folders/collections list direct
    /// children.
    private static func query(forContainerKind kind: MediaItemKind) -> (recursive: Bool, includeItemTypes: [String]) {
        switch kind {
        case .movie: return (true, ["Movie"])
        case .series: return (true, ["Series"])
        default: return (false, [])
        }
    }

    // MARK: Search

    public func search(query: String, limit: Int) async throws -> [MediaItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return try await client.searchItems(
            userID: session.userID,
            searchTerm: trimmed,
            includeItemTypes: ["Movie", "Series", "Episode"],
            limit: limit
        ).map(map(item:))
    }

    // MARK: Playback

    public func playbackInfo(for itemID: String) async throws -> PlaybackRequest {
        try await playbackInfo(for: itemID, forceTranscode: false)
    }

    public func playbackInfo(for itemID: String, forceTranscode: Bool) async throws -> PlaybackRequest {
        let detail = try await client.item(userID: session.userID, id: itemID)
        var info = try await client.playbackInfo(
            userID: session.userID,
            itemID: itemID,
            mode: forceTranscode ? .transcode : .auto
        )
        guard var source = info.MediaSources.first else { throw AppError.notFound }

        // Capture the original source facts (true container + DoVi/HDR range)
        // BEFORE any remux swap below, so diagnostics and the native engine's
        // Dolby Vision display switch see the real source even if the server's
        // remux response describes the output container instead.
        let originalContainer = source.Container
        let originalStreams = source.MediaStreams ?? detail.MediaStreams ?? []

        // Track whether we deliberately swapped to a server **remux** (DirectStream,
        // video stream-copied) so diagnostics can report it as a lossless remux
        // rather than a quality-reducing re-encode.
        var didRemux = false

        // Container-only remux to reach AVPlayer losslessly. Two cases:
        //  1. True Dolby Vision: a DoVi MKV the server would direct-play only
        //     reaches the on-device hybrid engine → HDR10. Remuxing to seekable
        //     fMP4 HLS with the video **copied** (DoVi RPU/dvcC preserved, tagged
        //     `dvh1`) reaches AVPlayer — the only tvOS engine that outputs true
        //     Dolby Vision.
        //  2. HEVC `hev1`: AVPlayer can't render HEVC tagged `hev1` (audio plays,
        //     black screen). Jellyfin's fMP4 remux re-tags the copied bitstream to
        //     `hvc1` (`-c copy -tag:v hvc1`), fixing it with no re-encode.
        // Both route to AVPlayer automatically via `isTranscoding`. Best-effort: if
        // the remux fails or the server offers no stream URL, fall back to direct
        // play (the router then sends `hev1` to the on-device engine as a net).
        if !forceTranscode, Self.shouldRequestDoViRemux(source) || Self.shouldRequestHvc1Remux(source) {
            if let remuxInfo = try? await client.playbackInfo(
                userID: session.userID,
                itemID: itemID,
                mode: .remux
            ), let remuxSource = remuxInfo.MediaSources.first,
               remuxSource.TranscodingUrl != nil {
                info = remuxInfo
                source = remuxSource
                didRemux = true
            }
        }

        let streamURL = try resolveStreamURL(itemID: itemID, source: source, playSessionID: info.PlaySessionId)
        let mappedItem = map(item: detail)

        let streams = source.MediaStreams ?? detail.MediaStreams ?? []
        let audio = streams.filter { $0.`Type` == "Audio" }.map(map(stream:))
        let sourceID = source.Id ?? itemID
        let subs = streams.filter { $0.`Type` == "Subtitle" }.map { stream in
            map(subtitleStream: stream, itemID: itemID, sourceID: sourceID)
        }

        return PlaybackRequest(
            item: mappedItem,
            streamURL: streamURL,
            playSessionID: info.PlaySessionId,
            audioTracks: audio,
            subtitleTracks: subs,
            startPosition: mappedItem.resumePosition ?? 0,
            isTranscoding: source.TranscodingUrl != nil,
            deliveryMode: Self.deliveryMode(transcoding: source.TranscodingUrl != nil, didRemux: didRemux),
            sourceMetadata: Self.sourceMetadata(container: originalContainer, streams: originalStreams),
            trickplay: trickplayManifest(itemID: itemID, source: source, trickplay: detail.Trickplay)
        )
    }

    /// Builds a provider-agnostic `TrickplayManifest` from Jellyfin's per-source,
    /// per-width trickplay metadata, picking the highest-resolution thumbnail set
    /// available and pre-resolving every tile-image URL. Returns `nil` whenever
    /// the server hasn't generated usable trickplay for the item.
    func trickplayManifest(
        itemID: String,
        source: MediaSourceInfo,
        trickplay: [String: [String: TrickplayInfoDto]]?
    ) -> TrickplayManifest? {
        guard let trickplay, !trickplay.isEmpty else { return nil }
        let sourceID = source.Id ?? itemID
        guard let widthMap = trickplay[sourceID] ?? trickplay.first?.value, !widthMap.isEmpty else {
            return nil
        }
        // Highest available thumbnail width = best preview quality (servers
        // usually generate just one, so this is a safe default).
        let chosen = widthMap
            .compactMap { key, info -> (width: Int, info: TrickplayInfoDto)? in
                guard let width = Int(key) else { return nil }
                return (width, info)
            }
            .max { $0.width < $1.width }
        guard let chosen,
              let thumbWidth = chosen.info.Width, thumbWidth > 0,
              let thumbHeight = chosen.info.Height, thumbHeight > 0,
              let tileColumns = chosen.info.TileWidth, tileColumns > 0,
              let tileRows = chosen.info.TileHeight, tileRows > 0,
              let count = chosen.info.ThumbnailCount, count > 0,
              let interval = chosen.info.Interval, interval > 0
        else { return nil }

        let perTile = tileColumns * tileRows
        let tileCount = (count + perTile - 1) / perTile
        let tileURLs = (0..<tileCount).compactMap {
            client.trickplayTileURL(itemID: itemID, mediaSourceID: sourceID, width: chosen.width, tileIndex: $0)
        }
        guard tileURLs.count == tileCount else { return nil }

        return TrickplayManifest(
            thumbnailWidth: thumbWidth,
            thumbnailHeight: thumbHeight,
            tileColumns: tileColumns,
            tileRows: tileRows,
            thumbnailCount: count,
            intervalMs: interval,
            tileURLs: tileURLs
        )
    }

    /// Classifies how the server is delivering the stream for the diagnostics
    /// overlay. We can only assert a **remux** (lossless, video stream-copied)
    /// when we deliberately requested DirectStream and the server honored it with
    /// a `TranscodingUrl` (`didRemux`). Any other `TranscodingUrl` came from the
    /// server's own `auto`/forced decision, which may re-encode — so we
    /// conservatively label it `transcode` rather than over-claiming "lossless".
    static func deliveryMode(transcoding: Bool, didRemux: Bool) -> PlaybackDiagnostics.PlaybackMode {
        if !transcoding { return .directPlay }
        return didRemux ? .remux : .transcode
    }

    /// Whether to ask the server to remux (rather than direct-play) this source so
    /// it reaches AVPlayer for true Dolby Vision. True only for a **Dolby Vision
    /// HEVC stream in a Matroska container with Apple-compatible audio** that the
    /// server currently wants to direct-play (no `TranscodingUrl`). Those are the
    /// sources where a container-only remux (video copied) lifts the file from the
    /// on-device hybrid engine's HDR10 ceiling to native DoVi, with no re-encode.
    /// HEVC + Apple-compatible audio is required so the server can stream-copy both
    /// tracks; otherwise forcing direct-play off would trigger a wasteful transcode.
    static func shouldRequestDoViRemux(_ source: MediaSourceInfo) -> Bool {
        // Only intervene when the server chose direct play (raw container).
        guard source.TranscodingUrl == nil else { return false }

        let container = (source.Container ?? "").lowercased()
        let isMatroska = container.contains("mkv")
            || container.contains("matroska")
            || container.contains("webm")
        guard isMatroska else { return false }

        let streams = source.MediaStreams ?? []
        let video = streams.first { $0.`Type` == "Video" }
        guard (video?.Codec ?? "").lowercased() == "hevc" else { return false }
        guard (video?.VideoRangeType ?? "").uppercased().hasPrefix("DOVI") else { return false }

        let audio = streams.first { $0.`Type` == "Audio" && ($0.IsDefault ?? false) }
            ?? streams.first { $0.`Type` == "Audio" }
        // No audio → still safe to remux video-only.
        guard let audioCodec = audio?.Codec?.lowercased() else { return true }
        let appleCompatibleAudio: Set<String> = ["aac", "ac3", "eac3", "alac", "mp3", "flac", "opus"]
        return appleCompatibleAudio.contains(audioCodec)
    }

    /// Whether to ask the server to remux (rather than direct-play) an HEVC source
    /// tagged `hev1`. AVPlayer/VideoToolbox only decode HEVC tagged `hvc1`; `hev1`
    /// (in-band parameter sets) plays audio with a **black screen**. Jellyfin's
    /// fMP4 HLS remux stream-copies the bitstream and re-tags it to `hvc1`
    /// (`-c copy -tag:v hvc1`) — lossless, no re-encode — which AVPlayer then
    /// renders. True only for a **`hev1` HEVC stream in an Apple/MP4-family
    /// container** the server currently wants to direct-play. `hev1` in Matroska
    /// is excluded: it routes to the on-device hybrid engine (which decodes `hev1`
    /// directly), so no remux is needed.
    static func shouldRequestHvc1Remux(_ source: MediaSourceInfo) -> Bool {
        // Only intervene when the server chose direct play (raw container).
        guard source.TranscodingUrl == nil else { return false }

        let container = (source.Container ?? "").lowercased()
        let isMatroska = container.contains("mkv")
            || container.contains("matroska")
            || container.contains("webm")
        guard !isMatroska else { return false }

        let streams = source.MediaStreams ?? []
        let video = streams.first { $0.`Type` == "Video" }
        let codec = (video?.Codec ?? "").lowercased()
        guard codec == "hevc" || codec == "h265" else { return false }
        guard (video?.CodecTag ?? "").lowercased() == "hev1" else { return false }

        let audio = streams.first { $0.`Type` == "Audio" && ($0.IsDefault ?? false) }
            ?? streams.first { $0.`Type` == "Audio" }
        // No audio → still safe to remux video-only.
        guard let audioCodec = audio?.Codec?.lowercased() else { return true }
        let appleCompatibleAudio: Set<String> = ["aac", "ac3", "eac3", "alac", "mp3", "flac", "opus"]
        return appleCompatibleAudio.contains(audioCodec)
    }

    /// Builds provider-agnostic source facts (codec/HDR/resolution/channels/…)
    /// from the original file's media streams, so the diagnostics overlay stays
    /// accurate even when the server transcodes to a metadata-poor HLS stream.
    static func sourceMetadata(container: String?, streams: [MediaStreamDto]) -> MediaSourceMetadata? {
        let video = streams.first { $0.`Type` == "Video" }
        let audio = streams.first { ($0.`Type` == "Audio") && ($0.IsDefault ?? false) }
            ?? streams.first { $0.`Type` == "Audio" }
        let subtitle = streams.first { ($0.`Type` == "Subtitle") && ($0.IsDefault ?? false) }
            ?? streams.first { $0.`Type` == "Subtitle" }

        let videoStream = video.map { v in
            MediaSourceMetadata.VideoStream(
                codec: v.Codec,
                codecTag: v.CodecTag,
                profile: v.Profile,
                width: v.Width,
                height: v.Height,
                bitDepth: v.BitDepth,
                bitrate: v.BitRate,
                frameRate: v.RealFrameRate ?? v.AverageFrameRate,
                videoRange: v.VideoRange,
                videoRangeType: v.VideoRangeType,
                colorTransfer: v.ColorTransfer
            )
        }
        let audioStream = audio.map { a in
            MediaSourceMetadata.AudioStream(
                codec: a.Codec,
                profile: a.Profile,
                channels: a.Channels,
                channelLayout: a.ChannelLayout,
                sampleRate: a.SampleRate,
                bitrate: a.BitRate,
                language: a.Language
            )
        }
        let subtitleStream = subtitle.map { s in
            MediaSourceMetadata.SubtitleStream(
                codec: s.Codec,
                language: s.Language,
                title: s.DisplayTitle
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
        try await client.reportPlaybackProgress(progress, event: event)
        // On stop, also release any server-side transcode job for this session.
        // Best-effort: cleanup failure must not surface as a playback error.
        if event == .stop, let playSessionID = progress.playSessionID, !playSessionID.isEmpty {
            try? await client.stopActiveEncoding(playSessionID: playSessionID)
        }
    }

    public func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? {
        client.imageURL(itemID: itemID, kind: kind, maxWidth: maxWidth)
    }

    // MARK: Subtitles
    public func remoteSubtitleSearch(itemID: String, language: String) async throws -> [RemoteSubtitle] {
        try await client.remoteSubtitleSearch(itemID: itemID, language: language).map(map(remoteSubtitle:))
    }

    public func downloadRemoteSubtitle(itemID: String, subtitleID: String) async throws {
        try await client.downloadRemoteSubtitle(itemID: itemID, subtitleID: subtitleID)
    }

    // MARK: - Mapping

    private func resolveStreamURL(itemID: String, source: MediaSourceInfo, playSessionID: String?) throws -> URL {
        // Prefer the server-provided HLS transcode/remux URL when present: the
        // server returns one whenever the file can't be direct-played for this
        // device profile (e.g. MKV, or an unsupported codec). HLS (fMP4 segments,
        // BreakOnNonKeyFrames) is fully seekable in AVPlayer, which fixes far
        // seeks that fail on non-fragmented direct streams.
        if let transcoding = source.TranscodingUrl, let url = absoluteURL(fromServerPath: transcoding) {
            return url
        }
        // DirectPlay: stream the original container as-is. Preferred for local
        // servers (no transcode, best quality).
        let container = source.Container ?? "mp4"
        let sourceID = source.Id ?? itemID
        guard var components = URLComponents(url: session.server.baseURL, resolvingAgainstBaseURL: false) else {
            throw AppError.invalidResponse
        }
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = basePath + "/Videos/\(itemID)/stream.\(container)"
        var query = [
            URLQueryItem(name: "static", value: "true"),
            URLQueryItem(name: "mediaSourceId", value: sourceID),
            URLQueryItem(name: "api_key", value: session.accessToken)
        ]
        if let playSessionID, !playSessionID.isEmpty {
            query.append(URLQueryItem(name: "playSessionId", value: playSessionID))
        }
        if let tag = source.ETag, !tag.isEmpty {
            query.append(URLQueryItem(name: "tag", value: tag))
        }
        components.queryItems = query
        guard let url = components.url else { throw AppError.invalidResponse }
        return url
    }

    private func absoluteURL(fromServerPath path: String) -> URL? {
        if let absolute = URL(string: path), absolute.scheme != nil { return absolute }
        guard var components = URLComponents(url: session.server.baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        if let pathComponents = URLComponents(string: path) {
            components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path) + pathComponents.path
            components.queryItems = pathComponents.queryItems
        }
        return components.url
    }

    private func map(item dto: BaseItemDto) -> MediaItem {
        MediaItem(
            id: dto.Id,
            title: dto.Name ?? "Untitled",
            kind: Self.kind(forItemType: dto.`Type`),
            overview: dto.Overview,
            parentTitle: dto.SeriesName ?? dto.SeasonName,
            seasonNumber: dto.ParentIndexNumber,
            episodeNumber: dto.IndexNumber,
            productionYear: dto.ProductionYear,
            officialRating: dto.OfficialRating,
            genres: dto.Genres ?? [],
            people: Self.people(from: dto, client: client),
            studios: dto.Studios?.compactMap(\.Name).filter { !$0.isEmpty } ?? [],
            tags: dto.Tags ?? [],
            taglines: dto.Taglines ?? [],
            seriesID: dto.SeriesId ?? (Self.kind(forItemType: dto.`Type`) == .season ? dto.ParentId : nil),
            seasonID: dto.SeasonId,
            runtime: JellyfinTicks.seconds(fromTicks: dto.RunTimeTicks),
            resumePosition: JellyfinTicks.seconds(fromTicks: dto.UserData?.PlaybackPositionTicks),
            playedPercentage: dto.UserData?.PlayedPercentage.map { $0 / 100.0 },
            isPlayed: dto.UserData?.Played ?? false,
            posterURL: Self.imageURL(for: dto, kind: .primary, maxWidth: 500, client: client),
            seriesPosterURL: dto.SeriesId.flatMap {
                client.imageURL(itemID: $0, kind: .primary, maxWidth: 500)
            },
            backdropURL: Self.imageURL(for: dto, kind: .backdrop, maxWidth: 1280, client: client),
            heroBackdropURL: Self.imageURL(for: dto, kind: .backdrop, maxWidth: 3840, client: client),
            fallbackArtworkURL: dto.SeriesId.flatMap {
                client.imageURL(itemID: $0, kind: .backdrop, maxWidth: 1280)
            },
            logoURL: Self.logoURL(for: dto, client: client),
            ratings: Self.ratings(from: dto),
            providerIDs: dto.ProviderIds ?? [:],
            mediaInfo: Self.sourceMetadata(
                container: dto.MediaSources?.first?.Container,
                streams: dto.MediaStreams ?? dto.MediaSources?.first?.MediaStreams ?? []
            )
        )
    }

    /// Maps Jellyfin `People` onto provider-agnostic `MediaPerson`s, preserving
    /// billing order. A headshot URL is built only when the person advertises a
    /// `PrimaryImageTag`, so we never point an avatar at a guaranteed 404.
    /// Entries without a usable id/name are dropped.
    private static func people(from dto: BaseItemDto, client: JellyfinClient) -> [MediaPerson] {
        guard let people = dto.People else { return [] }
        return people.compactMap { person in
            guard let id = person.Id, let name = person.Name, !name.isEmpty else { return nil }
            let imageURL = person.PrimaryImageTag != nil
                ? client.imageURL(itemID: id, kind: .primary, maxWidth: 300)
                : nil
            return MediaPerson(
                id: id,
                name: name,
                role: person.Role.flatMap { $0.isEmpty ? nil : $0 },
                kind: person.`Type`,
                imageURL: imageURL
            )
        }
    }

    /// Builds an *item-owned* image URL only when the DTO actually advertises
    /// that image, so a missing server image yields `nil` (letting the artwork
    /// fallback chain run) instead of a URL that 404s into a blank card. The
    /// item's own `Primary`/`Thumb`/`Logo` live in `ImageTags`; backdrops live in
    /// `BackdropImageTags`. Series-level art (seriesPoster/fallback) is resolved
    /// separately against `SeriesId` and intentionally not gated here.
    private static func imageURL(for dto: BaseItemDto, kind: ImageKind, maxWidth: Int, client: JellyfinClient) -> URL? {
        let advertised: Bool
        switch kind {
        case .primary: advertised = dto.ImageTags?["Primary"] != nil
        case .thumb: advertised = dto.ImageTags?["Thumb"] != nil
        case .logo: advertised = dto.ImageTags?["Logo"] != nil
        case .backdrop: advertised = (dto.BackdropImageTags?.isEmpty == false)
        }
        guard advertised else { return nil }
        return client.imageURL(itemID: dto.Id, kind: kind, maxWidth: maxWidth)
    }

    /// Resolves the stylized title/logo art URL for the detail hero.
    ///
    /// For a series or movie we point at the item's own `Logo` image, but only
    /// when it actually advertises one (`ImageTags["Logo"]`), avoiding a
    /// guaranteed 404. For an episode or season the logo belongs to the owning
    /// series, so we use `SeriesId`; we can't see the series' image tags from
    /// here, so the URL is provided unconditionally and a 404 simply falls
    /// through to the TMDb/text fallback in the hero.
    private static func logoURL(for dto: BaseItemDto, client: JellyfinClient) -> URL? {
        switch kind(forItemType: dto.`Type`) {
        case .episode, .season:
            return dto.SeriesId.flatMap {
                client.imageURL(itemID: $0, kind: .logo, maxWidth: 720)
            }
        default:
            guard dto.ImageTags?["Logo"] != nil else { return nil }
            return client.imageURL(itemID: dto.Id, kind: .logo, maxWidth: 720)
        }
    }

    /// Maps Jellyfin's native rating fields onto provider-agnostic ratings.
    ///
    /// `CommunityRating` is a 0–10 audience score sourced from TMDB, so we brand
    /// it as TMDB for every item type (movies, series, episodes, …). `CriticRating`
    /// is a 0–100 Rotten Tomatoes Tomatometer percentage.
    private static func ratings(from dto: BaseItemDto) -> [ExternalRating] {
        var ratings: [ExternalRating] = []
        if let community = dto.CommunityRating {
            ratings.append(ExternalRating(source: .tmdb, value: community, scale: .outOfTen))
        }
        if let critic = dto.CriticRating {
            ratings.append(ExternalRating(source: .rottenTomatoes, value: critic, scale: .percent))
        }
        return ratings
    }

    private func map(stream dto: MediaStreamDto) -> MediaTrack {
        MediaTrack(
            id: dto.Index,
            kind: dto.`Type` == "Subtitle" ? .subtitle : .audio,
            displayTitle: dto.DisplayTitle ?? dto.Language ?? dto.Codec ?? "Track \(dto.Index)",
            language: dto.Language,
            isDefault: dto.IsDefault ?? false,
            isForced: dto.IsForced ?? false
        )
    }

    /// Maps a subtitle stream, attaching a WebVTT delivery URL for text-based
    /// subtitles so the player can inject them into the native picker even on
    /// direct play. Image-based subs (PGS/VOBSUB) get no URL — they need server
    /// burn-in, which the native picker can't drive.
    private func map(subtitleStream dto: MediaStreamDto, itemID: String, sourceID: String) -> MediaTrack {
        let isText = dto.IsTextSubtitleStream ?? isTextSubtitleCodec(dto.Codec)
        let deliveryURL = isText ? subtitleVTTURL(itemID: itemID, sourceID: sourceID, streamIndex: dto.Index) : nil
        return MediaTrack(
            id: dto.Index,
            kind: .subtitle,
            displayTitle: dto.DisplayTitle ?? dto.Language ?? dto.Codec ?? "Track \(dto.Index)",
            language: dto.Language,
            isDefault: dto.IsDefault ?? false,
            isForced: dto.IsForced ?? false,
            deliveryURL: deliveryURL
        )
    }

    /// Fallback text-subtitle detection when the server omits
    /// `IsTextSubtitleStream`, based on the codec token.
    private func isTextSubtitleCodec(_ codec: String?) -> Bool {
        guard let codec = codec?.lowercased() else { return false }
        return ["subrip", "srt", "ass", "ssa", "webvtt", "vtt", "mov_text", "text", "ttml", "subviewer", "sami", "smi"].contains(codec)
    }

    /// `GET /Videos/{itemId}/{mediaSourceId}/Subtitles/{index}/0/Stream.vtt` —
    /// the server converts SRT/ASS/embedded-text subtitles to WebVTT on the fly.
    private func subtitleVTTURL(itemID: String, sourceID: String, streamIndex: Int) -> URL? {
        guard var components = URLComponents(url: session.server.baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = basePath + "/Videos/\(itemID)/\(sourceID)/Subtitles/\(streamIndex)/0/Stream.vtt"
        components.queryItems = [URLQueryItem(name: "api_key", value: session.accessToken)]
        return components.url
    }

    private func map(remoteSubtitle dto: RemoteSubtitleInfoDto) -> RemoteSubtitle {
        RemoteSubtitle(
            id: dto.Id ?? "",
            name: dto.Name ?? dto.ProviderName ?? "Subtitle",
            providerName: dto.ProviderName,
            language: dto.ThreeLetterISOLanguageName,
            format: dto.Format,
            communityRating: dto.CommunityRating,
            downloadCount: dto.DownloadCount,
            isForced: dto.IsForced ?? false,
            isHearingImpaired: false
        )
    }

    private static func kind(forItemType type: String?) -> MediaItemKind {
        switch type {
        case "Movie": return .movie
        case "Series": return .series
        case "Season": return .season
        case "Episode": return .episode
        case "Video": return .video
        case "CollectionFolder", "Folder": return .folder
        case "BoxSet": return .collection
        default: return .unknown
        }
    }

    private static func kind(forCollectionType type: String?) -> MediaItemKind {
        switch type {
        case "movies": return .movie
        case "tvshows": return .series
        case "boxsets": return .collection
        default: return .folder
        }
    }
}

// MARK: - Watched state

extension JellyfinProvider: WatchStateProviding {
    /// Toggles an item's played/watched state on the server. For a season or
    /// series id Jellyfin cascades the change to the contained episodes.
    public func setPlayed(_ played: Bool, itemID: String) async throws {
        try await client.setItemPlayed(played, userID: session.userID, itemID: itemID)
    }
}
