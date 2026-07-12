import Foundation
import CoreModels
import CoreNetworking

// MARK: - Jellyfin music support (additive, opt-in capability)
//
// `JellyfinProvider` already conforms to `MediaProvider` (video). This file adds
// the *optional* `MusicProvider` capability as a pure extension — nothing in the
// video path changes. Feature code detects support via `provider as? MusicProvider`
// and the conditional Music tab only appears when `musicLibraries()` is non-empty,
// so video-only Jellyfin users see no change.
//
// ## Container convention for `musicItems(in:kind:page:)`
// To page artists/albums/playlists/genres across *all* of the user's music
// libraries (which is what the grids want), callers pass an **empty**
// `containerID` for a global, recursive query. A non-empty `containerID` scopes
// the query: for `.album` it is treated as an **album-artist id** (the artist
// detail screen's "albums by this artist"); for `.track` it is the **album id**.
extension JellyfinProvider: MusicProvider {

    // MARK: Libraries

    public func musicLibraries() async throws -> [MediaLibrary] {
        try await client.userViews(userID: session.userID)
            .filter { $0.CollectionType == "music" }
            .map { dto in
                MediaLibrary(
                    id: dto.Id,
                    title: dto.Name ?? "Music",
                    kind: .folder,
                    imageURL: client.imageURL(itemID: dto.Id, kind: .primary, maxWidth: 400)
                )
            }
    }

    // MARK: Paged browse

    public func musicItems(in containerID: String, kind: MusicItemKind, page: PageRequest) async throws -> MusicPage {
        let sortOrder = JellyfinClient.sortOrder(for: page.sort.direction)
        let parent = containerID.isEmpty ? nil : containerID

        switch kind {
        case .artist:
            let response = try await client.artists(
                userID: session.userID,
                parentID: parent,
                startIndex: page.startIndex,
                limit: page.limit,
                sortOrder: sortOrder
            )
            return MusicPage(
                artists: response.Items.map(mapArtist(_:)),
                startIndex: page.startIndex,
                totalCount: response.TotalRecordCount ?? (page.startIndex + response.Items.count)
            )

        case .album:
            // A non-empty container is an album-artist scope (artist detail);
            // empty means "all albums in the library".
            let response: ItemsResponse
            if let parent {
                response = try await client.musicItems(
                    userID: session.userID,
                    parentID: nil,
                    includeItemTypes: ["MusicAlbum"],
                    recursive: true,
                    startIndex: page.startIndex,
                    limit: page.limit,
                    sortBy: "ProductionYear,SortName",
                    sortOrder: "Descending",
                    albumArtistID: parent
                )
            } else {
                response = try await client.musicItems(
                    userID: session.userID,
                    parentID: nil,
                    includeItemTypes: ["MusicAlbum"],
                    recursive: true,
                    startIndex: page.startIndex,
                    limit: page.limit,
                    sortBy: "SortName",
                    sortOrder: sortOrder
                )
            }
            return MusicPage(
                albums: response.Items.map(mapAlbum(_:)),
                startIndex: page.startIndex,
                totalCount: response.TotalRecordCount ?? (page.startIndex + response.Items.count)
            )

        case .track:
            let response = try await client.musicItems(
                userID: session.userID,
                parentID: parent,
                includeItemTypes: ["Audio"],
                recursive: parent == nil,
                startIndex: page.startIndex,
                limit: page.limit,
                sortBy: "ParentIndexNumber,IndexNumber,SortName",
                sortOrder: sortOrder
            )
            return MusicPage(
                tracks: response.Items.map(mapTrack(_:)),
                startIndex: page.startIndex,
                totalCount: response.TotalRecordCount ?? (page.startIndex + response.Items.count)
            )

        case .playlist:
            let response = try await client.musicItems(
                userID: session.userID,
                parentID: parent,
                includeItemTypes: ["Playlist"],
                recursive: true,
                startIndex: page.startIndex,
                limit: page.limit,
                sortBy: "SortName",
                sortOrder: sortOrder
            )
            return MusicPage(
                playlists: response.Items.map(mapPlaylist(_:)),
                startIndex: page.startIndex,
                totalCount: response.TotalRecordCount ?? (page.startIndex + response.Items.count)
            )

        case .genre:
            let response = try await client.musicGenres(
                userID: session.userID,
                parentID: parent,
                startIndex: page.startIndex,
                limit: page.limit
            )
            return MusicPage(
                genres: response.Items.map { MusicGenre(id: $0.Id, name: $0.Name ?? "Genre") },
                startIndex: page.startIndex,
                totalCount: response.TotalRecordCount ?? (page.startIndex + response.Items.count)
            )
        }
    }

    // MARK: Recently played

    public func recentlyPlayed(limit: Int) async throws -> [MusicAlbum] {
        try await recentlyPlayed(limit: limit, parentIDs: nil)
    }

    public func recentlyPlayed(limit: Int, libraryIDs: [String]?) async throws -> [MusicAlbum] {
        try await recentlyPlayed(limit: limit, parentIDs: libraryIDs)
    }

    private func recentlyPlayed(limit: Int, parentIDs: [String]?) async throws -> [MusicAlbum] {
        guard limit > 0 else { return [] }

        func query(parentID: String?) async -> [MusicAlbum] {
            let response = try? await client.musicItems(
                userID: session.userID,
                parentID: parentID,
                includeItemTypes: ["MusicAlbum"],
                recursive: true,
                startIndex: 0,
                limit: limit,
                sortBy: "DatePlayed",
                sortOrder: "Descending",
                filters: ["IsPlayed"]
            )
            return (response?.Items ?? []).map(mapAlbum(_:))
        }

        // Unscoped: one recursive query across every library. Scoped: query each
        // visible view, then merge-sort by real recency across them.
        guard let parentIDs, !parentIDs.isEmpty else {
            return await query(parentID: nil)
        }
        var albums: [MusicAlbum] = []
        for parentID in parentIDs {
            albums += await query(parentID: parentID)
        }
        return Array(
            albums
                .sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
                .prefix(limit)
        )
    }

    public func recentlyPlayedTracks(limit: Int) async throws -> [MusicTrack] {
        try await recentlyPlayedTracks(limit: limit, parentIDs: nil)
    }

    public func recentlyPlayedTracks(limit: Int, libraryIDs: [String]?) async throws -> [MusicTrack] {
        try await recentlyPlayedTracks(limit: limit, parentIDs: libraryIDs)
    }

    private func recentlyPlayedTracks(limit: Int, parentIDs: [String]?) async throws -> [MusicTrack] {
        guard limit > 0 else { return [] }

        func query(parentID: String?) async -> [MusicTrack] {
            let response = try? await client.musicItems(
                userID: session.userID,
                parentID: parentID,
                includeItemTypes: ["Audio"],
                recursive: true,
                startIndex: 0,
                limit: limit,
                sortBy: "DatePlayed",
                sortOrder: "Descending",
                filters: ["IsPlayed"]
            )
            return (response?.Items ?? []).map(mapTrack(_:))
        }

        guard let parentIDs, !parentIDs.isEmpty else {
            return await query(parentID: nil)
        }
        var tracks: [MusicTrack] = []
        for parentID in parentIDs {
            tracks += await query(parentID: parentID)
        }
        return Array(
            tracks
                .sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
                .prefix(limit)
        )
    }

    public func recentlyPlayedPlaylists(limit: Int) async throws -> [MusicPlaylist] {
        try await recentlyPlayedPlaylists(limit: limit, parentIDs: nil)
    }

    public func recentlyPlayedPlaylists(limit: Int, libraryIDs: [String]?) async throws -> [MusicPlaylist] {
        try await recentlyPlayedPlaylists(limit: limit, parentIDs: libraryIDs)
    }

    private func recentlyPlayedPlaylists(limit: Int, parentIDs: [String]?) async throws -> [MusicPlaylist] {
        guard limit > 0 else { return [] }

        // Playlists are account-global in Jellyfin (not under a music view), so
        // the library scope doesn't apply — one recursive query returns them all.
        // `filters: ["IsPlayed"]` keeps only playlists the backend has stamped
        // with a `DatePlayed`; some Jellyfin versions don't stamp playlists when
        // their member tracks play, in which case this returns empty (handled
        // upstream — the rail simply omits playlists).
        let response = try? await client.musicItems(
            userID: session.userID,
            parentID: nil,
            includeItemTypes: ["Playlist"],
            recursive: true,
            startIndex: 0,
            limit: limit,
            sortBy: "DatePlayed",
            sortOrder: "Descending",
            filters: ["IsPlayed"]
        )
        return Array(
            (response?.Items ?? [])
                .map(mapPlaylist(_:))
                .filter { $0.lastPlayedAt != nil }
                .sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
                .prefix(limit)
        )
    }

    public func musicItems(in containerID: String, kind: MusicItemKind, page: PageRequest, libraryIDs: [String]?) async throws -> MusicPage {
        // Scope only applies to the whole-library (empty container) query; a
        // non-empty container is already an artist/album scope. Playlists are
        // account-global in Jellyfin (not under a music view), so they ignore the
        // library scope too.
        guard containerID.isEmpty, kind != .playlist, let libraryIDs, !libraryIDs.isEmpty else {
            return try await musicItems(in: containerID, kind: kind, page: page)
        }
        if libraryIDs.count == 1 {
            return try await libraryPage(kind: kind, parentID: libraryIDs[0], startIndex: page.startIndex, limit: page.limit, sort: page.sort)
        }
        return try await pagedAcrossLibraries(kind: kind, page: page, parentIDs: libraryIDs)
    }

    /// One page of a single music *view* (library), scoped via `ParentId`.
    private func libraryPage(kind: MusicItemKind, parentID: String, startIndex: Int, limit: Int, sort: CoreModels.SortDescriptor) async throws -> MusicPage {
        let sortOrder = JellyfinClient.sortOrder(for: sort.direction)
        switch kind {
        case .artist:
            let response = try await client.artists(userID: session.userID, parentID: parentID, startIndex: startIndex, limit: limit, sortOrder: sortOrder)
            return MusicPage(artists: response.Items.map(mapArtist(_:)), startIndex: startIndex, totalCount: response.TotalRecordCount ?? (startIndex + response.Items.count))
        case .album:
            let response = try await client.musicItems(userID: session.userID, parentID: parentID, includeItemTypes: ["MusicAlbum"], recursive: true, startIndex: startIndex, limit: limit, sortBy: "SortName", sortOrder: sortOrder)
            return MusicPage(albums: response.Items.map(mapAlbum(_:)), startIndex: startIndex, totalCount: response.TotalRecordCount ?? (startIndex + response.Items.count))
        case .track:
            let response = try await client.musicItems(userID: session.userID, parentID: parentID, includeItemTypes: ["Audio"], recursive: true, startIndex: startIndex, limit: limit, sortBy: "ParentIndexNumber,IndexNumber,SortName", sortOrder: sortOrder)
            return MusicPage(tracks: response.Items.map(mapTrack(_:)), startIndex: startIndex, totalCount: response.TotalRecordCount ?? (startIndex + response.Items.count))
        case .genre:
            let response = try await client.musicGenres(userID: session.userID, parentID: parentID, startIndex: startIndex, limit: limit)
            return MusicPage(genres: response.Items.map { MusicGenre(id: $0.Id, name: $0.Name ?? "Genre") }, startIndex: startIndex, totalCount: response.TotalRecordCount ?? (startIndex + response.Items.count))
        case .playlist:
            return MusicPage(startIndex: startIndex, totalCount: 0)
        }
    }

    /// Pages a music kind across several visible views as one virtual list,
    /// probing each view's total then fetching only the overlapping slice — the
    /// Jellyfin analogue of the Plex multi-section walk. Rare (most Jellyfin
    /// servers have a single music view), so correctness over micro-optimisation.
    private func pagedAcrossLibraries(kind: MusicItemKind, page: PageRequest, parentIDs: [String]) async throws -> MusicPage {
        var totals: [Int] = []
        for parentID in parentIDs {
            let probe = try await libraryPage(kind: kind, parentID: parentID, startIndex: 0, limit: 0, sort: page.sort)
            totals.append(probe.totalCount)
        }
        let grandTotal = totals.reduce(0, +)

        var result = MusicPage(startIndex: page.startIndex, totalCount: grandTotal)
        var remaining = page.limit
        var globalStart = page.startIndex
        var offset = 0
        for (i, parentID) in parentIDs.enumerated() {
            if remaining <= 0 { break }
            let count = totals[i]
            if globalStart >= offset + count { offset += count; continue }
            let localStart = max(0, globalStart - offset)
            let take = min(remaining, count - localStart)
            if take > 0 {
                let slice = try await libraryPage(kind: kind, parentID: parentID, startIndex: localStart, limit: take, sort: page.sort)
                result.artists += slice.artists
                result.albums += slice.albums
                result.tracks += slice.tracks
                result.playlists += slice.playlists
                result.genres += slice.genres
                remaining -= take
                globalStart += take
            }
            offset += count
        }
        return result
    }

    // MARK: Detail

    public func artist(id: String) async throws -> MusicArtist {
        mapArtist(try await client.item(userID: session.userID, id: id))
    }

    public func album(id: String) async throws -> MusicAlbum {
        mapAlbum(try await client.item(userID: session.userID, id: id))
    }

    public func tracks(in containerID: String) async throws -> [MusicTrack] {
        // Albums: tracks are direct children, ordered by disc then track number.
        let albumChildren = try await client.musicItems(
            userID: session.userID,
            parentID: containerID,
            includeItemTypes: ["Audio"],
            recursive: false,
            startIndex: 0,
            limit: 500,
            sortBy: "ParentIndexNumber,IndexNumber,SortName",
            sortOrder: "Ascending"
        )
        if !albumChildren.Items.isEmpty {
            return albumChildren.Items.map(mapTrack(_:))
        }
        // Playlists: fall back to the playlist-items endpoint, which preserves
        // playlist order.
        let playlist = try await client.playlistItems(userID: session.userID, playlistID: containerID)
        return playlist.Items.map(mapTrack(_:))
    }

    // MARK: Playback

    public func audioPlaybackInfo(for trackID: String, queueContext: [String]?) async throws -> AudioPlaybackRequest {
        let playSessionID = UUID().uuidString
        guard let streamURL = client.audioStreamURL(itemID: trackID, playSessionID: playSessionID) else {
            throw AppError.invalidResponse
        }
        // Best-effort metadata for the request's own track (the queue itself is
        // supplied by the caller, which already holds the loaded track list).
        let track: MusicTrack
        var quality: PlaybackQuality?
        if let dto = try? await client.item(userID: session.userID, id: trackID) {
            track = mapTrack(dto)
            quality = Self.playbackQuality(from: dto)
        } else {
            track = MusicTrack(id: trackID, title: "")
        }
        let locator = try AuthenticatedHTTPPlaybackLocator(
            provider: .jellyfin,
            accountID: accountID,
            credentialRevision: credentialRevision,
            itemID: trackID,
            deliveryMode: quality?.isDirectPlay == false
                ? .serverTranscode
                : .directFile,
            formatHint: MediaFormatHint(
                container: quality?.isDirectPlay == false
                    ? "ts"
                    : quality?.container
            ),
            purpose: .audioStream,
            resource: try credentialFreeResource(
                fromServerPath: streamURL.absoluteString
            ),
            playSessionID: playSessionID
        )
        return AudioPlaybackRequest(
            track: track,
            playbackSource: .authenticatedHTTP(locator),
            playSessionID: playSessionID,
            queue: [track],
            queueIndex: 0,
            isTranscoding: quality.map { !$0.isDirectPlay } ?? false,
            quality: quality
        )
    }

    // MARK: Lyrics

    public func lyrics(for trackID: String) async throws -> Lyrics? {
        // The server answers 404 when a track has no lyrics. We must distinguish
        // that authoritative "no lyrics" from a transport failure (offline / DNS /
        // timeout / expired session): the former is a real verdict the caller may
        // cache, the latter must be retried later. So we re-throw transport-level
        // `AppError`s and only return `nil` for a genuine empty/absent result.
        let dto: LyricDto
        do {
            dto = try await client.lyrics(itemID: trackID)
        } catch let error as AppError where error.isTransportFailure {
            throw error
        } catch {
            return nil
        }
        guard let rawLines = dto.Lyrics, !rawLines.isEmpty else {
            return nil
        }
        var lines = rawLines.map { line in
            LyricLine(
                text: line.Text ?? "",
                start: JellyfinTicks.seconds(fromTicks: line.Start)
            )
        }
        // Sort synced lines by timestamp (parity with the LRC and Plex-JSON
        // parsers). The active-line scan in the player relies on ascending order,
        // so guard against a server that returns timed lines out of order. Only
        // sort when there are timestamps — reordering plain (unsynced) lines
        // would scramble their intended reading order.
        if lines.contains(where: { $0.start != nil }) {
            lines.sort { ($0.start ?? 0) < ($1.start ?? 0) }
        }
        let lyrics = Lyrics(lines: lines)
        return lyrics.isEmpty ? nil : lyrics.taggingSource(.jellyfin)
    }

    /// Containers AVPlayer direct-plays on tvOS — must match the `Container`
    /// allow-list `audioStreamURL` sends to Jellyfin's `/universal` endpoint.
    /// When the source container is in this set the server streams the original
    /// file untouched; otherwise it transcodes to an AAC HLS fallback.
    private static let directPlayAudioContainers: Set<String> = ["mp3", "aac", "m4a", "flac", "alac", "wav", "m4b"]

    /// Derives `PlaybackQuality` from a track's `MediaSources`/`MediaStreams`,
    /// reproducing the same direct-play decision `audioStreamURL` relies on so we
    /// don't need a `PlaybackInfo` round-trip.
    private static func playbackQuality(from dto: BaseItemDto) -> PlaybackQuality? {
        let source = dto.MediaSources?.first
        let container = source?.Container?.lowercased()
        let audio = (source?.MediaStreams ?? dto.MediaStreams)?.first { $0.`Type` == "Audio" }
        guard container != nil || audio != nil else { return nil }

        // The container token can be a comma list (e.g. "mp3,flac"); direct-play
        // only when *every* listed container is playable.
        let isDirectPlay: Bool = {
            guard let container else { return false }
            let tokens = container.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return !tokens.isEmpty && tokens.allSatisfy { directPlayAudioContainers.contains($0) }
        }()

        if !isDirectPlay {
            return PlaybackQuality(isDirectPlay: false, transcodeCodec: "aac")
        }
        return PlaybackQuality(
            isDirectPlay: true,
            codec: audio?.Codec?.lowercased(),
            container: container,
            bitrate: audio?.BitRate ?? source?.Bitrate,
            sampleRate: audio?.SampleRate,
            bitDepth: audio?.BitDepth,
            channels: audio?.Channels
        )
    }

    // MARK: Images

    public func musicImageURL(id: String, maxWidth: Int?) -> URL? {
        client.imageURL(itemID: id, kind: .primary, maxWidth: maxWidth)
    }

    // MARK: - Mapping

    private func mapArtist(_ dto: BaseItemDto) -> MusicArtist {
        MusicArtist(
            id: dto.Id,
            name: dto.Name ?? "Unknown Artist",
            artworkURL: client.imageURL(itemID: dto.Id, kind: .primary, maxWidth: 500),
            albumCount: dto.ChildCount,
            genres: dto.Genres ?? []
        )
    }

    private func mapAlbum(_ dto: BaseItemDto) -> MusicAlbum {
        let artistID = dto.AlbumArtists?.first?.Id ?? dto.ArtistItems?.first?.Id
        return MusicAlbum(
            id: dto.Id,
            title: dto.Name ?? "Unknown Album",
            artistName: dto.AlbumArtist ?? dto.Artists?.first ?? dto.AlbumArtists?.first?.Name,
            artistID: artistID,
            year: dto.ProductionYear,
            artworkURL: client.imageURL(itemID: dto.Id, kind: .primary, maxWidth: 500),
            trackCount: dto.ChildCount,
            totalDuration: JellyfinTicks.seconds(fromTicks: dto.RunTimeTicks),
            genres: dto.Genres ?? [],
            lastPlayedAt: JellyfinProvider.parseDate(dto.UserData?.LastPlayedDate)
        )
    }

    private func mapTrack(_ dto: BaseItemDto) -> MusicTrack {
        // Prefer the track's own Primary image; fall back to its album's artwork.
        let artwork = client.imageURL(itemID: dto.Id, kind: .primary, maxWidth: 500)
            ?? dto.AlbumId.flatMap { client.imageURL(itemID: $0, kind: .primary, maxWidth: 500) }
        return MusicTrack(
            id: dto.Id,
            title: dto.Name ?? "Unknown Track",
            albumTitle: dto.Album,
            albumID: dto.AlbumId,
            artistName: dto.Artists?.first ?? dto.AlbumArtist,
            trackNumber: dto.IndexNumber,
            discNumber: dto.ParentIndexNumber,
            duration: JellyfinTicks.seconds(fromTicks: dto.RunTimeTicks),
            artworkURL: artwork,
            lastPlayedAt: JellyfinProvider.parseDate(dto.UserData?.LastPlayedDate)
        )
    }

    private func mapPlaylist(_ dto: BaseItemDto) -> MusicPlaylist {
        MusicPlaylist(
            id: dto.Id,
            title: dto.Name ?? "Playlist",
            artworkURL: client.imageURL(itemID: dto.Id, kind: .primary, maxWidth: 500),
            trackCount: dto.ChildCount,
            totalDuration: JellyfinTicks.seconds(fromTicks: dto.RunTimeTicks),
            lastPlayedAt: JellyfinProvider.parseDate(dto.UserData?.LastPlayedDate)
        )
    }
}

// MARK: - Capability advertisement

extension JellyfinProvider: CapabilityReporting {
    /// Jellyfin can serve both video and music libraries. The *presence* of a
    /// music library is still detected at runtime via `musicLibraries()`, so the
    /// Music tab stays hidden for accounts without one.
    public var capabilities: ProviderCapability { [.video, .music, .remoteSubtitles] }
}
