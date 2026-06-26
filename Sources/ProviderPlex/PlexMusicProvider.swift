import Foundation
import CoreModels
import CoreNetworking

// MARK: - Plex music support (additive, opt-in capability)
//
// `PlexProvider` already conforms to `MediaProvider` (video). This file adds the
// *optional* `MusicProvider` capability as a pure extension — nothing in the
// video path changes. Feature code detects support via `provider as? MusicProvider`
// and the conditional Music tab only appears when `musicLibraries()` is non-empty,
// so video-only Plex users see no change.
//
// ## Plex music model
// A Plex music library is a section of `type == "artist"`. Within it the
// hierarchy is artist (type 8) → album (type 9) → track (type 10). Albums of an
// artist and tracks of an album are the node's `/children`. Audio playlists are
// account-level (`/playlists?playlistType=audio`).
//
// ## Container convention for `musicItems(in:kind:page:)`
// An **empty** `containerID` performs a global, paged query across *all* of the
// user's music sections (what the landing/grids want). A non-empty `containerID`
// scopes the query: for `.album` it is an **artist** ratingKey (the artist
// detail's "albums by this artist"); for `.track` it is the **album** ratingKey.
extension PlexProvider: MusicProvider {

    /// Plex content-`type` codes for the music hierarchy.
    private enum PlexMusicType {
        static let artist = 8
        static let album = 9
        static let track = 10
    }

    private static let artworkWidth = 500

    // MARK: Libraries

    public func musicLibraries() async throws -> [MediaLibrary] {
        try await musicSectionDirectories().map { dir in
            MediaLibrary(
                id: dir.key ?? "",
                title: dir.title ?? "Music",
                kind: .folder,
                imageURL: client.imageURL(path: dir.thumb ?? dir.composite ?? dir.art, maxWidth: 400)
            )
        }
    }

    // MARK: Paged browse

    public func musicItems(in containerID: String, kind: MusicItemKind, page: PageRequest) async throws -> MusicPage {
        if containerID.isEmpty {
            return try await globalMusicItems(kind: kind, page: page)
        }
        return try await scopedMusicItems(containerID: containerID, kind: kind)
    }

    private func globalMusicItems(kind: MusicItemKind, page: PageRequest) async throws -> MusicPage {
        switch kind {
        case .artist:
            let result = try await pagedMusic(type: PlexMusicType.artist, page: page)
            return MusicPage(
                artists: result.items.map(mapArtist(_:)),
                startIndex: page.startIndex,
                totalCount: result.total
            )
        case .album:
            let result = try await pagedMusic(type: PlexMusicType.album, page: page)
            return MusicPage(
                albums: result.items.map(mapAlbum(_:)),
                startIndex: page.startIndex,
                totalCount: result.total
            )
        case .track:
            let result = try await pagedMusic(type: PlexMusicType.track, page: page)
            return MusicPage(
                tracks: result.items.map(mapTrack(_:)),
                startIndex: page.startIndex,
                totalCount: result.total
            )
        case .playlist:
            // Playlists are account-level and small; return the whole set on the
            // first page and treat it as complete thereafter.
            guard page.startIndex == 0 else { return MusicPage(startIndex: page.startIndex, totalCount: 0) }
            let playlists = try await client.audioPlaylists().map(mapPlaylist(_:))
            return MusicPage(playlists: playlists, startIndex: 0, totalCount: playlists.count)
        case .genre:
            guard page.startIndex == 0 else { return MusicPage(startIndex: page.startIndex, totalCount: 0) }
            var genres: [MusicGenre] = []
            for section in try await musicSectionDirectories() {
                guard let sectionID = section.key else { continue }
                let dirs = (try? await client.musicGenres(sectionID: sectionID)) ?? []
                genres += dirs.compactMap { dir in
                    guard let key = dir.key, let title = dir.title else { return nil }
                    return MusicGenre(id: key, name: title)
                }
            }
            return MusicPage(genres: genres, startIndex: 0, totalCount: genres.count)
        }
    }

    private func scopedMusicItems(containerID: String, kind: MusicItemKind) async throws -> MusicPage {
        switch kind {
        case .album:
            // `containerID` is an artist ratingKey: its children are albums.
            let albums = try await client.children(ratingKey: containerID)
                .filter { $0.type == "album" }
                .map(mapAlbum(_:))
            return MusicPage(albums: albums, startIndex: 0, totalCount: albums.count)
        case .track:
            // `containerID` is an album ratingKey: its children are tracks.
            let tracks = try await client.children(ratingKey: containerID)
                .filter { $0.type == "track" }
                .map(mapTrack(_:))
            return MusicPage(tracks: tracks, startIndex: 0, totalCount: tracks.count)
        default:
            return MusicPage()
        }
    }

    // MARK: Recently played

    public func recentlyPlayed(limit: Int) async throws -> [MusicAlbum] {
        guard limit > 0 else { return [] }
        let sections = try await musicSectionDirectories().compactMap(\.key)
        guard !sections.isEmpty else { return [] }

        // Pull each section's most-recent albums, then merge-sort by real play
        // recency and take the head. Never-played albums (no `lastViewedAt`) are
        // dropped — Plex sorts them last but still returns them.
        var albums: [MusicAlbum] = []
        for sectionID in sections {
            let metas = (try? await client.recentlyViewedAlbums(
                sectionID: sectionID,
                type: PlexMusicType.album,
                limit: limit
            )) ?? []
            albums += metas
                .filter { ($0.viewCount ?? 0) >= 1 && ($0.lastViewedAt ?? 0) > 0 }
                .map(mapAlbum(_:))
        }
        return Array(
            albums
                .sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
                .prefix(limit)
        )
    }

    // MARK: Detail

    public func album(id: String) async throws -> MusicAlbum {
        mapAlbum(try await client.metadata(ratingKey: id))
    }

    public func tracks(in containerID: String) async throws -> [MusicTrack] {
        // Albums: tracks are the album's direct children, already in disc/track
        // order from the server.
        let children = (try? await client.children(ratingKey: containerID)) ?? []
        let albumTracks = children.filter { $0.type == "track" }
        if !albumTracks.isEmpty {
            return albumTracks.map(mapTrack(_:))
        }
        // Playlists: fall back to the playlist-items endpoint, which preserves
        // playlist order.
        let playlistTracks = (try? await client.playlistItems(ratingKey: containerID)) ?? []
        return playlistTracks.filter { $0.type == "track" }.map(mapTrack(_:))
    }

    // MARK: Playback

    public func audioPlaybackInfo(for trackID: String, queueContext: [String]?) async throws -> AudioPlaybackRequest {
        let detail = try await client.metadata(ratingKey: trackID)
        guard let media = detail.Media?.first, let part = media.Part?.first else {
            throw AppError.notFound
        }
        // A stable per-(device,item) session id ties a transcode stream to its
        // owner, deterministic so it's traceable and testable.
        let sessionID = "plozz-audio-\(session.deviceID)-\(trackID)"
        guard let resolved = client.audioPlaybackURL(
            ratingKey: trackID,
            media: media,
            part: part,
            sessionID: sessionID
        ) else {
            throw AppError.notFound
        }
        let track = mapTrack(detail)
        let quality = Self.playbackQuality(media: media, part: part, isTranscoding: resolved.isTranscoding)
        return AudioPlaybackRequest(
            track: track,
            streamURL: resolved.url,
            playSessionID: trackID,
            queue: [track],
            queueIndex: 0,
            startPosition: 0,
            isTranscoding: resolved.isTranscoding,
            quality: quality
        )
    }

    /// Builds a `PlaybackQuality` from Plex media facts. Direct play reflects the
    /// source audio stream; a transcode is always Plex's progressive MP3 320 kbps
    /// music target (see `audioTranscodeURL`).
    private static func playbackQuality(media: PlexMedia, part: PlexPart, isTranscoding: Bool) -> PlaybackQuality {
        if isTranscoding {
            return PlaybackQuality(isDirectPlay: false, bitrate: 320_000, transcodeCodec: "mp3")
        }
        let audio = part.Stream?.first { $0.streamType == 2 }
        let codec = (audio?.codec ?? media.audioCodec)?.lowercased()
        let container = (media.container ?? part.container)?.lowercased()
        // Plex reports per-stream bitrate in kbps.
        let bitrate = audio?.bitrate.map { $0 * 1000 }
        return PlaybackQuality(
            isDirectPlay: true,
            codec: codec,
            container: container,
            bitrate: bitrate,
            sampleRate: audio?.samplingRate,
            bitDepth: nil,
            channels: audio?.channels ?? media.audioChannels
        )
    }

    // MARK: - Multi-section paging

    /// The directory entries for every music (`type == "artist"`) section.
    private func musicSectionDirectories() async throws -> [PlexDirectory] {
        try await client.sections().filter { $0.type == "artist" && $0.key != nil }
    }

    /// Pages a music content `type` across *all* music sections as one virtual
    /// list. The overwhelmingly common single-section case is a single request;
    /// multiple music libraries are paged with a cumulative offset walk so the
    /// grid's pager sees a correct combined `totalCount`.
    private func pagedMusic(type: Int, page: PageRequest) async throws -> (items: [PlexMetadata], total: Int) {
        let sections = try await musicSectionDirectories().compactMap(\.key)
        guard !sections.isEmpty else { return ([], 0) }

        if sections.count == 1 {
            let container = try await client.musicSectionItems(
                sectionID: sections[0],
                type: type,
                start: page.startIndex,
                size: page.limit,
                sort: page.sort
            )
            let items = container.Metadata ?? []
            let total = container.totalSize ?? container.size ?? (page.startIndex + items.count)
            return (items, total)
        }

        // Multiple music libraries: probe each section's total (size=0 returns
        // `totalSize` with no payload), then fetch only the slice that overlaps
        // the requested window.
        var totals: [Int] = []
        for sectionID in sections {
            let probe = try await client.musicSectionItems(sectionID: sectionID, type: type, start: 0, size: 0, sort: page.sort)
            totals.append(probe.totalSize ?? probe.size ?? 0)
        }
        let grandTotal = totals.reduce(0, +)

        var collected: [PlexMetadata] = []
        var remaining = page.limit
        var globalStart = page.startIndex
        var offset = 0
        for (i, sectionID) in sections.enumerated() {
            if remaining <= 0 { break }
            let count = totals[i]
            if globalStart >= offset + count { offset += count; continue }
            let localStart = max(0, globalStart - offset)
            let take = min(remaining, count - localStart)
            if take > 0 {
                let container = try await client.musicSectionItems(sectionID: sectionID, type: type, start: localStart, size: take, sort: page.sort)
                collected += container.Metadata ?? []
                remaining -= take
                globalStart += take
            }
            offset += count
        }
        return (collected, grandTotal)
    }

    // MARK: - Mapping

    private func artwork(_ path: String?) -> URL? {
        client.imageURL(path: path, maxWidth: Self.artworkWidth)
    }

    private func mapArtist(_ dto: PlexMetadata) -> MusicArtist {
        MusicArtist(
            id: dto.ratingKey ?? "",
            name: dto.title ?? "Unknown Artist",
            artworkURL: artwork(dto.thumb),
            albumCount: dto.childCount,
            genres: (dto.Genre ?? []).compactMap(\.tag)
        )
    }

    private func mapAlbum(_ dto: PlexMetadata) -> MusicAlbum {
        MusicAlbum(
            id: dto.ratingKey ?? "",
            title: dto.title ?? "Unknown Album",
            artistName: dto.parentTitle ?? dto.grandparentTitle,
            artistID: dto.parentRatingKey,
            year: dto.year ?? dto.parentYear,
            artworkURL: artwork(dto.thumb ?? dto.parentThumb),
            trackCount: dto.leafCount,
            totalDuration: PlexTime.seconds(fromMilliseconds: dto.duration),
            genres: (dto.Genre ?? []).compactMap(\.tag),
            lastPlayedAt: dto.lastViewedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }

    private func mapTrack(_ dto: PlexMetadata) -> MusicTrack {
        MusicTrack(
            id: dto.ratingKey ?? "",
            title: dto.title ?? "Unknown Track",
            albumTitle: dto.parentTitle,
            albumID: dto.parentRatingKey,
            artistName: dto.grandparentTitle ?? dto.originalTitle,
            trackNumber: dto.index,
            discNumber: dto.parentIndex,
            duration: PlexTime.seconds(fromMilliseconds: dto.duration),
            artworkURL: artwork(dto.thumb ?? dto.parentThumb ?? dto.grandparentThumb)
        )
    }

    private func mapPlaylist(_ dto: PlexMetadata) -> MusicPlaylist {
        MusicPlaylist(
            id: dto.ratingKey ?? "",
            title: dto.title ?? "Playlist",
            artworkURL: artwork(dto.composite ?? dto.thumb),
            trackCount: dto.leafCount,
            totalDuration: PlexTime.seconds(fromMilliseconds: dto.duration)
        )
    }
}

// MARK: - Capability advertisement

extension PlexProvider: CapabilityReporting {
    /// Plex can serve both video and music libraries. The *presence* of a music
    /// library is still detected at runtime via `musicLibraries()`, so the Music
    /// tab stays hidden for accounts without one.
    public var capabilities: ProviderCapability { [.video, .music] }
}
