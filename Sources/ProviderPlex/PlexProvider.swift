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
    let client: PlexClient

    public init(
        session: UserSession,
        http: HTTPClient = URLSessionHTTPClient(),
        interactiveHTTP: HTTPClient? = nil,
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
        // Persist whichever connection last answered, keyed by server, so a warm
        // server resolves on the first probe next launch instead of re-discovering
        // through stale/dead addresses (Docker bridges, old relay IPs).
        let reachableKey = "plex.reachable.\(session.server.id)"
        let reachableSeed = UserDefaults.standard.string(forKey: reachableKey).flatMap(URL.init(string:))
        let resolver = PlexConnectionResolver(
            candidates: candidates,
            deviceProfile: deviceProfile,
            token: session.accessToken,
            probe: probe,
            refresh: connectionRefresh,
            reachableSeed: reachableSeed,
            onReachable: { url in
                UserDefaults.standard.set(url.absoluteString, forKey: reachableKey)
            }
        )
        self.client = PlexClient(
            resolver: resolver,
            deviceProfile: deviceProfile,
            token: session.accessToken,
            http: http,
            interactiveHTTP: interactiveHTTP,
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

    /// Locality of the connection the resolver actually settled on (not the raw
    /// persisted `baseURL`): a Plex server advertises its own LAN address even to
    /// remote clients, so classifying `session.server.baseURL` would wrongly mark
    /// a server reached over the internet / Tailscale as local. `client.baseURL`
    /// is the best-known **reachable** connection the resolver probed, which is
    /// the truthful basis for best-source selection.
    public var connectionLocality: SourceLocality {
        SourceLocalityClassifier.classify(url: client.baseURL)
    }

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

    public func mediaSegments(for itemID: String) async throws -> [MediaSegment] {
        // Best-effort: marker-less servers/items return [] rather than failing.
        let markers = (try? await client.mediaSegments(ratingKey: itemID)) ?? []
        return markers.compactMap(Self.map(marker:))
    }

    /// Maps a Plex marker onto the provider-agnostic `MediaSegment`. Plex marker
    /// offsets are milliseconds; Plex names the closing segment `credits`.
    private static func map(marker dto: PlexMarker) -> MediaSegment? {
        guard let start = dto.startTimeOffset, let end = dto.endTimeOffset, end > start else {
            return nil
        }
        let kind: MediaSegment.Kind
        switch dto.type?.lowercased() {
        case "intro": kind = .intro
        case "credits", "outro": kind = .credits
        case "commercial": kind = .commercial
        default: kind = .unknown
        }
        return MediaSegment(
            id: "\(dto.type ?? "marker")-\(start)",
            kind: kind,
            start: Double(start) / 1000.0,
            end: Double(end) / 1000.0
        )
    }

    public func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        let type = Self.sectionType(forContainerKind: kind)
        PlozzLog.networking.info(
            "Plex library browse: section=\(containerID) kind=\(kind.rawValue) type=\(type.map(String.init) ?? "-") start=\(page.startIndex) size=\(page.limit) sort=\(page.sort.field.rawValue)/\(page.sort.direction.rawValue)"
        )
        do {
            let container = try await client.sectionItems(
                sectionID: containerID,
                type: type,
                start: page.startIndex,
                size: page.limit,
                sort: page.sort
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
        try await playbackInfo(for: itemID, mediaSourceID: nil, forceTranscode: forceTranscode)
    }

    public func playbackInfo(for itemID: String, mediaSourceID: String?, forceTranscode: Bool) async throws -> PlaybackRequest {
        // Single round-trip: Plex's `metadata` response already carries the
        // Media/Part (version) elements and the stream URL is then built locally,
        // so — unlike Jellyfin's separate item + playback-decision calls — there's
        // nothing here to parallelize for time-to-first-frame. This is the Plex
        // mirror of Jellyfin's concurrent playbackInfo: fetch the one decision as
        // early as possible.
        let detail = try await client.metadata(ratingKey: itemID)
        // Pick the chosen Media element (version) by id, else Plex's first.
        let chosenMedia = mediaSourceID.flatMap { id in
            detail.Media?.first { $0.id.map(String.init) == id }
        } ?? detail.Media?.first
        guard let media = chosenMedia,
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
        let localRemuxSource = Self.localRemuxSourceDescriptor(
            itemID: itemID,
            mediaSourceID: media.id.map(String.init),
            client: client,
            part: part,
            referencePlaybackURL: client.transcodeURL(ratingKey: itemID, sessionID: transcodeSessionID) ?? resolved.url,
            durationSeconds: mappedItem.runtime,
            container: media.container ?? part.container,
            streams: streams,
            mediaAudioProfile: media.audioProfile,
            mediaVideoDisplayTitle: media.videoStreamDisplayTitle
        )

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
                streams: streams,
                mediaAudioProfile: media.audioProfile,
                mediaVideoDisplayTitle: media.videoStreamDisplayTitle
            ),
            localRemuxSource: localRemuxSource,
            scrubPreview: scrubPreview(for: part),
            sourceProvider: .plex,
            serverName: session.server.name
        )
    }

    /// Builds a Plex scrubbing-preview source from a part's BIF index, when the
    /// server has generated "video preview thumbnails" (signalled by the part's
    /// `indexes` list). Returns `nil` otherwise so the player simply
    /// shows no preview.
    func scrubPreview(for part: PlexPart) -> ScrubPreviewSource? {
        guard let partID = part.id else {
            PlozzLog.playback.debug("Plex scrub preview unavailable: missing part id")
            return nil
        }
        guard let rawIndexes = part.indexes, !rawIndexes.isEmpty else {
            PlozzLog.playback.debug("Plex scrub preview unavailable: no BIF indexes partID=\(partID)")
            return nil
        }
        let availableQualities = rawIndexes
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !availableQualities.isEmpty else {
            PlozzLog.playback.debug("Plex scrub preview unavailable: malformed BIF indexes partID=\(partID)")
            return nil
        }

        // Prefer higher-resolution previews when the server advertises them.
        let preferredOrder = ["hd", "sd"]
        let quality = preferredOrder.first(where: { availableQualities.contains($0) }) ?? availableQualities.first
        guard let quality, let url = client.bifIndexURL(partID: partID, quality: quality) else {
            PlozzLog.playback.debug("Plex scrub preview unavailable: failed to build BIF URL partID=\(partID)")
            return nil
        }

        PlozzLog.playback.debug("Plex scrub preview selected partID=\(partID) quality=\(quality)")
        return .plexBIF(url: url)
    }

    /// Plex reports bitrates in kbps; the diagnostics model wants bits/sec.
    private static func bps(fromKbps kbps: Int?) -> Int? {
        guard let kbps, kbps > 0 else { return nil }
        return kbps * 1000
    }

    /// Derives the provider-agnostic HDR token from Plex's stream/media hints.
    /// Plex can signal range via explicit DoVi fields, transfer characteristics,
    /// and display-title strings such as `DoVi/HDR10` or `HDR10+`.
    private static func dynamicRangeType(
        colorTransfer: String?,
        doviPresent: Bool?,
        doviProfile: Int?,
        doviLevel: Int?,
        doviBLPresent: Bool?,
        displayTitles: [String?]
    ) -> String? {
        let transfer = (colorTransfer ?? "").lowercased()
        let titleHint = displayTitles
            .compactMap { $0?.uppercased() }
            .joined(separator: " ")

        let hasDovi = (doviPresent ?? false)
            || doviProfile != nil
            || doviLevel != nil
            || doviBLPresent != nil
            || titleHint.contains("DOVI")
            || titleHint.contains("DOLBY VISION")
        let hasHDR10Plus = transfer.contains("2094")
            || titleHint.contains("HDR10+")
            || titleHint.contains("HDR10PLUS")
            || titleHint.contains("HDR10 PLUS")
        let hasHDR10 = transfer.contains("2084")
            || transfer == "pq"
            || transfer.contains("pq")
            || titleHint.contains("HDR10")
        let hasHLG = transfer.contains("b67")
            || transfer.contains("hlg")
            || titleHint.contains("HLG")

        if hasDovi {
            if hasHDR10Plus { return "DOVIWithHDR10PLUS" }
            if hasHDR10 || doviBLPresent == true { return "DOVIWithHDR10" }
            if hasHLG { return "DOVIWithHLG" }
            return "DOVI"
        }
        if hasHDR10Plus { return "HDR10+" }
        if hasHDR10 { return "HDR10" }
        if hasHLG { return "HLG" }
        if titleHint.contains("HDR") { return "HDR" }
        return nil
    }

    private static func videoRangeToken(for rangeType: String?) -> String? {
        guard let rangeType, !rangeType.isEmpty else { return nil }
        let upper = rangeType.uppercased()
        if upper.hasPrefix("DOVI") { return "DOVI" }
        if upper == "SDR" { return "SDR" }
        return "HDR"
    }

    /// Builds provider-agnostic source facts from a Plex part's streams so the
    /// diagnostics overlay matches what a direct-play client (e.g. Infuse) shows.
    ///
    /// `mediaAudioProfile` is the parent `<Media audioProfile=…>` summary
    /// (e.g. `"dolby digital plus + dolby atmos"`). Plex frequently signals
    /// Atmos *only* there — the audio Stream's own `profile`/`displayTitle`
    /// often don't mention it — so threading it in is what lets us surface a
    /// Dolby Atmos badge for those servers.
    static func sourceMetadata(
        container: String?,
        streams: [PlexStream],
        mediaAudioProfile: String? = nil,
        mediaVideoDisplayTitle: String? = nil
    ) -> MediaSourceMetadata? {
        let video = streams.first { $0.streamType == 1 }
        let audio = streams.first { ($0.streamType == 2) && ($0.selected ?? $0.default ?? false) }
            ?? streams.first { $0.streamType == 2 }
        let subtitle = streams.first { ($0.streamType == 3) && ($0.selected ?? false) }
            ?? streams.first { $0.streamType == 3 }

        let videoStream = video.map { v in
            // Stream-level path: when a video Stream is present and shows no
            // HDR/DoVi hints we can confidently assert SDR. The coarse media-
            // level fallback (no Stream array) deliberately does NOT assert
            // SDR — see `mediaLevelMetadata` — because the trimmed children
            // response can strip the HDR hint without meaning the content is
            // SDR.
            //
            // We also fold the parent `<Media>`'s `videoStreamDisplayTitle`
            // (e.g. "4K DoVi/HDR10") into the title-hint list alongside the
            // stream's own titles. Some Plex servers / agents emit a present
            // `<Stream>` with a sparse `displayTitle` (just a profile, no
            // HDR/DoVi tag) while the media-level summary carries the full
            // marketing label — so this is a belt-and-braces hint that lets
            // DoVi/HDR survive even when DOVI*/colorTrc happen to be missing
            // from the stream itself.
            let detectedRange = Self.dynamicRangeType(
                colorTransfer: v.colorTrc,
                doviPresent: v.DOVIPresent,
                doviProfile: v.DOVIProfile,
                doviLevel: v.DOVILevel,
                doviBLPresent: v.DOVIBLPresent,
                displayTitles: [v.displayTitle, v.extendedDisplayTitle, mediaVideoDisplayTitle]
            )
            let rangeType = detectedRange ?? "SDR"
            return MediaSourceMetadata.VideoStream(
                codec: v.codec,
                profile: v.profile,
                isInterlaced: Self.isInterlacedVideo(v),
                width: v.width,
                height: v.height,
                bitrate: bps(fromKbps: v.bitrate),
                frameRate: v.frameRate,
                videoRange: videoRangeToken(for: rangeType),
                videoRangeType: rangeType,
                colorTransfer: v.colorTrc,
                dolbyVisionProfile: v.DOVIProfile
            )
        }
        let audioStream = audio.map { a in
            return MediaSourceMetadata.AudioStream(
                codec: a.codec,
                profile: Self.audioProfile(
                    streamProfile: a.profile,
                    streamDisplayTitles: [a.displayTitle, a.extendedDisplayTitle],
                    mediaAudioProfile: mediaAudioProfile
                ),
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

    static func localRemuxSourceDescriptor(
        itemID: String,
        mediaSourceID: String?,
        client: PlexClient,
        part: PlexPart,
        referencePlaybackURL: URL?,
        durationSeconds: TimeInterval?,
        container: String?,
        streams: [PlexStream],
        mediaAudioProfile: String?,
        mediaVideoDisplayTitle: String?
    ) -> LocalRemuxSourceDescriptor? {
        guard let key = part.key,
              let originalURL = client.downloadURL(forPartKey: key),
              let metadata = sourceMetadata(
                container: container,
                streams: streams,
                mediaAudioProfile: mediaAudioProfile,
                mediaVideoDisplayTitle: mediaVideoDisplayTitle
              ) else {
            return nil
        }
        return LocalRemuxSourceDescriptor(
            itemID: itemID,
            mediaSourceID: mediaSourceID,
            provider: .plex,
            originalURL: originalURL,
            referencePlaybackURL: referencePlaybackURL,
            durationSeconds: durationSeconds,
            byteRangeSupported: true,
            sourceMetadata: metadata
        )
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
            originalTitle: dto.originalTitle,
            kind: kind,
            overview: dto.summary,
            parentTitle: parentTitle,
            // A season's own ordinal lives in `index`; an episode's season number
            // is its parent's index. Populating `seasonNumber` for season items lets
            // SeriesDetailView match a target season by NUMBER across servers (per-
            // server season ids differ) instead of collapsing to the first season.
            seasonNumber: isEpisode ? dto.parentIndex : (kind == .season ? dto.index : nil),
            episodeNumber: isEpisode ? dto.index : nil,
            productionYear: dto.year,
            officialRating: dto.contentRating,
            genres: dto.Genre?.compactMap(\.tag) ?? [],
            people: people(from: dto),
            studios: dto.studio.flatMap { $0.isEmpty ? nil : [$0] } ?? [],
            tags: dto.Tag?.compactMap(\.tag).filter { !$0.isEmpty } ?? [],
            seriesID: isEpisode ? dto.grandparentRatingKey : (kind == .season ? dto.parentRatingKey : nil),
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
            mediaInfo: Self.sourceMetadata(from: dto),
            libraryID: dto.librarySectionID.map(String.init),
            versions: Self.versions(from: dto.Media, edition: dto.editionTitle),
            isFavorite: false,
            lastPlayedAt: dto.lastViewedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }

    /// Maps Plex's `<Role>` (cast) plus `<Director>`/`<Writer>` (crew) elements
    /// into provider-agnostic `MediaPerson`s, so a movie opened from a Plex
    /// library shows the same cast row as its Jellyfin counterpart. Each kind is
    /// tagged so `MediaItem.cast` (actors only) and any future crew section can
    /// split them. Person ids are namespaced by kind because Plex reuses one
    /// global person id across roles (e.g. an actor who also directed), which
    /// would otherwise collide in `Identifiable` lists.
    private func people(from dto: PlexMetadata) -> [MediaPerson] {
        func mapped(_ entries: [PlexRole]?, kind: String) -> [MediaPerson] {
            (entries ?? []).compactMap { entry in
                guard let name = entry.tag, !name.isEmpty else { return nil }
                let identity = entry.id.map(String.init) ?? name
                return MediaPerson(
                    id: "\(kind.lowercased()):\(identity)",
                    name: name,
                    role: entry.role.flatMap { $0.isEmpty ? nil : $0 },
                    kind: kind,
                    imageURL: personImageURL(entry.thumb)
                )
            }
        }
        return mapped(dto.Role, kind: "Actor")
            + mapped(dto.Director, kind: "Director")
            + mapped(dto.Writer, kind: "Writer")
    }

    /// Resolves a person headshot. Plex serves these either as a server-relative
    /// path (`/library/metadata/…/thumb/…`, needing the token + transcoder) or as
    /// an already-absolute `metadata-static.plex.tv` URL — use the latter directly.
    private func personImageURL(_ thumb: String?) -> URL? {
        guard let thumb, !thumb.isEmpty else { return nil }
        if thumb.hasPrefix("http://") || thumb.hasPrefix("https://") {
            return URL(string: thumb)
        }
        return client.imageURL(path: thumb, maxWidth: 300)
    }

    /// Maps Plex's multiple `Media` elements (the same title in several
    /// qualities) into provider-agnostic `MediaVersion`s. Returns `[]` unless
    /// there's a genuine choice (>1), so the picker only appears when useful. The
    /// first element is flagged `isDefault` to mirror Plex's own ordering.
    ///
    /// Plex records the edition (cut) at the **item** level (`editionTitle`), so
    /// it is applied to every version; the per-file release name (the `Part`'s
    /// file basename) is passed through as `name` so the shared `EditionParser`
    /// can still recover the **source quality** (Remux / BluRay / WEB-DL) that
    /// distinguishes two otherwise-identical 4K files.
    static func versions(from media: [PlexMedia]?, edition: String? = nil) -> [MediaVersion] {
        guard let media, media.count > 1 else { return [] }
        return media.enumerated().map { index, m in
            MediaVersion(
                id: m.id.map(String.init) ?? "\(index)",
                name: Self.releaseName(from: m),
                edition: edition,
                width: m.width,
                height: m.height,
                bitrate: nil,
                sizeBytes: nil,
                isDefault: index == 0,
                videoCodec: m.videoCodec,
                videoRange: nil,
                audioCodec: m.audioCodec,
                audioChannels: m.audioChannels,
                audioProfile: nil,
                container: m.container
            )
        }
    }

    /// The release name to parse for source quality: the first part's file
    /// basename without its extension, e.g.
    /// `Movie (2009) Extended Bluray-2160p`. `nil` when no file path is reported.
    static func releaseName(from media: PlexMedia) -> String? {
        guard let file = media.Part?.first?.file, !file.isEmpty else { return nil }
        let base = (file as NSString).lastPathComponent
        let name = (base as NSString).deletingPathExtension
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
        // Stash the canonical Plex global guid (e.g. plex://movie/5d77...) so the
        // account-level Watchlist (Discover) writer can address the item even
        // though it's keyed globally rather than by the per-server ratingKey.
        if let guid = dto.guid?.trimmingCharacters(in: .whitespacesAndNewlines), !guid.isEmpty {
            ids["PlexGuid"] = guid
        }
        return ids
    }

    /// Builds the playable source's technical metadata from an item's first
    /// media part, so movie/episode detail heroes can show resolution/HDR/audio
    /// badges. Returns `nil` for containers (shows/seasons) that have no part.
    static func sourceMetadata(from dto: PlexMetadata) -> MediaSourceMetadata? {
        guard let media = bestMedia(from: dto.Media) else { return nil }
        let part = media.Part?.first
        let streams = part?.Stream ?? []
        if !streams.isEmpty {
            return sourceMetadata(
                container: part?.container ?? media.container,
                streams: streams,
                mediaAudioProfile: media.audioProfile,
                mediaVideoDisplayTitle: media.videoStreamDisplayTitle
            )
        }
        // List/children responses can omit the per-stream array; fall back to the
        // coarser Media-level facts so episode rails still earn resolution / HDR /
        // Atmos badges from the summary fields Plex always emits.
        return mediaLevelMetadata(from: media)
    }

    /// Picks the **highest-quality** Media element to badge the hero with, rather
    /// than Plex's first. A title can carry several Media versions — e.g. a 4K
    /// Dolby Vision original *and* a 1080p SDR companion/optimized copy — and Plex
    /// does not guarantee the best one is first. Badging `.first` could therefore
    /// advertise "1080p · SDR" while playback (which selects the recommended
    /// version) actually plays the 4K Dolby Vision file. Rank by effective
    /// resolution lines, then HDR/DoVi presence, so the headline badge reflects the
    /// best available quality and matches what plays.
    static func bestMedia(from medias: [PlexMedia]?) -> PlexMedia? {
        guard let medias, !medias.isEmpty else { return nil }
        return medias.max(by: { mediaQualityRank($0) < mediaQualityRank($1) })
    }

    private static func mediaQualityRank(_ m: PlexMedia) -> (Int, Int) {
        let lines: Int
        switch (m.videoResolution ?? "").lowercased() {
        case "8k": lines = 4320
        case "4k": lines = 2160
        case "1080": lines = 1080
        case "720": lines = 720
        case "480", "576", "sd": lines = 480
        default:
            // Classify by effective lines (max of true height and the height the
            // width implies at 16:9) so an ultrawide 2.35:1 4K file (e.g.
            // 3840×1600) ranks by its width (4K), not its cropped height.
            let widthLines = Int((Double(m.width ?? 0) * 9.0 / 16.0).rounded())
            lines = max(m.height ?? 0, widthLines)
        }
        let hdr = mediaSignalsHDR(m) ? 1 : 0
        return (lines, hdr)
    }

    /// A light HDR/DoVi hint for ranking same-resolution versions, drawn from the
    /// Media-level display title and any video stream's DoVi flags / transfer.
    private static func mediaSignalsHDR(_ m: PlexMedia) -> Bool {
        let title = (m.videoStreamDisplayTitle ?? "").lowercased()
        if title.contains("dovi") || title.contains("dolby vision")
            || title.contains("hdr") || title.contains("hlg") {
            return true
        }
        let videoStreams = (m.Part?.first?.Stream ?? []).filter { $0.streamType == 1 }
        return videoStreams.contains { v in
            v.DOVIPresent == true
                || (v.colorTrc?.lowercased().contains("smpte2084") ?? false)
                || (v.colorTrc?.lowercased().contains("arib-std-b67") ?? false)
                || (v.colorTrc?.lowercased().contains("smpte2094") ?? false)
        }
    }

    private static func isInterlacedVideo(_ stream: PlexStream) -> Bool? {
        guard let scanType = stream.scanType?.lowercased(), !scanType.isEmpty else { return nil }
        if scanType.contains("interlac") { return true }
        if scanType.contains("progress") { return false }
        return nil
    }

    /// A coarse `MediaSourceMetadata` from Plex's Media-element attributes, used
    /// when the richer per-stream data isn't present in a listing. Pulls HDR /
    /// DoVi out of `videoStreamDisplayTitle` and Atmos / DTS:X out of `audioProfile`
    /// so episode rails still earn the right badges without a per-item fetch.
    static func mediaLevelMetadata(from media: PlexMedia) -> MediaSourceMetadata? {
        let lines: Int?
        switch (media.videoResolution ?? "").lowercased() {
        case "4k": lines = 2160
        case "1080": lines = 1080
        case "720": lines = 720
        case "480", "576", "sd": lines = 480
        default: lines = media.height
        }
        let rangeType = dynamicRangeType(
            colorTransfer: nil,
            doviPresent: nil,
            doviProfile: nil,
            doviLevel: nil,
            doviBLPresent: nil,
            displayTitles: [media.videoStreamDisplayTitle, media.videoProfile]
        )
        let video: MediaSourceMetadata.VideoStream?
        if media.width != nil || lines != nil || media.videoCodec != nil {
            video = MediaSourceMetadata.VideoStream(
                codec: media.videoCodec,
                profile: media.videoProfile,
                width: media.width,
                height: lines,
                videoRange: videoRangeToken(for: rangeType),
                videoRangeType: rangeType
            )
        } else {
            video = nil
        }
        let audio: MediaSourceMetadata.AudioStream?
        if media.audioCodec != nil || media.audioChannels != nil || media.audioProfile != nil {
            audio = MediaSourceMetadata.AudioStream(
                codec: media.audioCodec,
                profile: Self.audioProfile(
                    streamProfile: nil,
                    streamDisplayTitles: [],
                    mediaAudioProfile: media.audioProfile
                ),
                channels: media.audioChannels
            )
        } else {
            audio = nil
        }
        let metadata = MediaSourceMetadata(container: media.container, video: video, audio: audio)
        return metadata.isEmpty ? nil : metadata
    }

    /// Folds Plex's various Atmos / DTS:X hints into a single audio profile string
    /// the shared badge logic can read. Plex spreads object-based-audio markers
    /// across three places — none of them universally populated:
    ///   1. the audio Stream's own `profile` (rarely says "atmos");
    ///   2. the audio Stream's `(extended)displayTitle`
    ///      (e.g. `"Dolby TrueHD Atmos 7.1"`);
    ///   3. the parent Media-level `audioProfile`
    ///      (e.g. `"dolby digital plus + dolby atmos"`) — frequently the **only**
    ///      place Atmos is mentioned for an Atmos-carrying EAC3 episode.
    /// We treat all three as evidence and append a normalized `Atmos` / `DTS:X`
    /// token to the stream profile so `MediaBadges.audioBadges` can surface the
    /// correct headline format regardless of which signal the server emits.
    static func audioProfile(
        streamProfile: String?,
        streamDisplayTitles: [String?],
        mediaAudioProfile: String?
    ) -> String? {
        let hintBlob = (streamDisplayTitles + [mediaAudioProfile])
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        let hasAtmos = hintBlob.contains("atmos")
        let hasDTSX = hintBlob.contains("dts:x")
            || hintBlob.contains("dts-x")
            || hintBlob.contains("dtsx")
            || hintBlob.contains("dts x")

        var parts: [String] = []
        if let streamProfile, !streamProfile.isEmpty { parts.append(streamProfile) }
        if hasAtmos, !parts.contains(where: { $0.lowercased().contains("atmos") }) {
            parts.append("Atmos")
        }
        if hasDTSX, !parts.contains(where: { $0.lowercased().contains("dts:x") }) {
            parts.append("DTS:X")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
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
            codec: dto.codec,
            isDefault: dto.default ?? dto.selected ?? false,
            isForced: dto.forced ?? false,
            channels: isSubtitle ? nil : dto.channels,
            deliveryURL: deliveryURL,
            isImageBasedSubtitle: isSubtitle && !isTextSubtitleCodec(dto.codec)
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

extension PlexProvider: ResumeStateWriting {
    /// Writes a resume position **out-of-band** (convergence/durability path) via
    /// `/:/progress`, which updates the saved `viewOffset` without opening or
    /// terminating a live `/:/timeline` session. The previous implementation
    /// reported `/:/timeline?state=stopped`, which **ends the session** and would
    /// snap a concurrent now-playing dashboard to 0:00 — the bug this avoids. A
    /// position of `0` clears the resume point.
    public func setResumePosition(_ seconds: TimeInterval, itemID: String) async throws {
        try await client.reportProgress(
            ratingKey: itemID,
            timeMs: PlexTime.milliseconds(fromSeconds: max(seconds, 0))
        )
    }
}

// MARK: - Watchlist

extension PlexProvider: WatchlistProviding {
    /// Adds/removes the title from the account Watchlist via the plex.tv Discover
    /// service. Keyed by the item's global `plex://` guid (stashed in
    /// `providerIDs["PlexGuid"]` during mapping), since the Watchlist is an
    /// account-level list addressed globally — not by the per-server ratingKey.
    /// Throws `AppError.notFound` when the item carries no usable guid so the
    /// optimistic UI reverts cleanly rather than silently no-op'ing.
    public func setWatchlisted(_ on: Bool, item: MediaItem) async throws {
        guard let metadataID = PlexClient.watchlistMetadataID(fromGuid: item.providerIDs["PlexGuid"]) else {
            throw AppError.notFound
        }
        try await client.setWatchlisted(on, metadataID: metadataID)
    }

    /// The account's Plex Watchlist, mapped to items flagged `isFavorite` so the
    /// unified Watchlist row renders them as saved. Discover items carry global
    /// ids that won't resolve for playback against a specific server (documented
    /// limitation); they appear in the row but may not direct-play.
    public func watchlist() async throws -> [MediaItem] {
        try await client.watchlist()
            .map(map(metadata:))
            .map { var copy = $0; copy.isFavorite = true; return copy }
    }
}

// MARK: - Metadata refresh

extension PlexProvider: MetadataRefreshing {
    /// Triggers a server-side metadata + artwork refresh for the item via the
    /// PMS `/refresh` endpoint. Fire and forget: the server processes it
    /// asynchronously.
    public func refreshMetadata(itemID: String) async throws {
        try await client.refreshMetadata(ratingKey: itemID)
    }
}
