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

    public init(session: UserSession, http: HTTPClient = URLSessionHTTPClient()) {
        self.session = session
        self.client = PlexClient(
            baseURL: session.server.baseURL,
            deviceProfile: PlexDeviceProfile(clientIdentifier: session.deviceID),
            token: session.accessToken,
            http: http
        )
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

    // MARK: Playback

    public func playbackInfo(for itemID: String) async throws -> PlaybackRequest {
        let detail = try await client.metadata(ratingKey: itemID)
        guard let media = detail.Media?.first,
              let part = media.Part?.first,
              let partKey = part.key,
              let streamURL = client.streamURL(forPartKey: partKey) else {
            throw AppError.notFound
        }
        let mappedItem = map(metadata: detail)
        let streams = part.Stream ?? []
        let audio = streams.filter { $0.streamType == 2 }.map(map(stream:))
        let subs = streams.filter { $0.streamType == 3 }.map(map(stream:))

        return PlaybackRequest(
            item: mappedItem,
            streamURL: streamURL,
            // Plex correlates timeline reports by ratingKey; a per-play session
            // id isn't required, so reuse the item id for traceability.
            playSessionID: itemID,
            audioTracks: audio,
            subtitleTracks: subs,
            startPosition: mappedItem.resumePosition ?? 0
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
            kind: kind,
            overview: dto.summary,
            parentTitle: parentTitle,
            seasonNumber: isEpisode ? dto.parentIndex : nil,
            episodeNumber: isEpisode ? dto.index : nil,
            productionYear: dto.year,
            runtime: runtime,
            resumePosition: resume,
            playedPercentage: percentage,
            isPlayed: viewCount > 0 && (resume ?? 0) == 0,
            posterURL: client.imageURL(path: posterPath, maxWidth: 500),
            backdropURL: client.imageURL(path: dto.art, maxWidth: 1280),
            ratings: [],
            providerIDs: [:]
        )
    }

    private func map(stream dto: PlexStream) -> MediaTrack {
        let language = dto.languageTag ?? dto.language
        return MediaTrack(
            id: dto.index ?? dto.id ?? 0,
            kind: dto.streamType == 3 ? .subtitle : .audio,
            displayTitle: dto.extendedDisplayTitle ?? dto.displayTitle ?? language ?? dto.codec ?? "Track",
            language: language,
            isDefault: dto.default ?? dto.selected ?? false,
            isForced: dto.forced ?? false
        )
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
