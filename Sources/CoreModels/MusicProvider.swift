import Foundation

// MARK: - Optional music capability (additive, non-breaking)
//
// `MusicProvider` is a *separate, optional* capability protocol. It does NOT
// extend or modify `MediaProvider`, so the existing providers (`ProviderJellyfin`,
// `ProviderPlex`) keep conforming to `MediaProvider` unchanged and keep compiling.
//
// A provider gains music support later by opting in *in its own module*:
//
//     extension JellyfinProvider: MusicProvider { /* map music endpoints */ }
//
// Feature code detects support without any provider edits:
//
//     if let music = provider as? MusicProvider { /* show Music tab */ }
//
// This mirrors the existing pattern where remote-subtitle search/download are
// optional with no-op defaults on `MediaProvider`. See
// `docs/music-library-proposal.md`.

/// A provider that can browse and play a music library.
///
/// Conformance is opt-in and detected at runtime via `as? MusicProvider`, so the
/// whole music experience (the Music tab, mini-player, etc.) is conditionally
/// absent for providers/accounts without a music library — keeping Plozz
/// byte-for-byte unchanged for video-only users.
public protocol MusicProvider: Sendable {
    // MARK: Music library browsing

    /// Top-level music libraries/views available to the user.
    func musicLibraries() async throws -> [MediaLibrary]

    /// A page of artists, albums, tracks, playlists or genres for a music
    /// container (a library root, an artist, an album, …). Paged so large
    /// libraries don't over-fetch, mirroring `MediaProvider.items(in:kind:page:)`.
    func musicItems(in containerID: String, kind: MusicItemKind, page: PageRequest) async throws -> MusicPage

    /// Full detail for a single artist.
    func artist(id: String) async throws -> MusicArtist

    /// Full detail for a single album.
    func album(id: String) async throws -> MusicAlbum

    /// The tracks of an album or playlist, in play order.
    func tracks(in containerID: String) async throws -> [MusicTrack]

    // MARK: Music playback

    /// Resolve a playable audio stream (+ queue + resume point) for a track.
    ///
    /// `queueContext` is the ordered list of track ids the track belongs to
    /// (its album or playlist), so the audio engine can build a next/previous
    /// queue. Pass `nil` to play the single track on its own.
    func audioPlaybackInfo(for trackID: String, queueContext: [String]?) async throws -> AudioPlaybackRequest

    // MARK: Images

    /// Absolute URL for a music node's artwork, or `nil` if unavailable.
    func musicImageURL(id: String, maxWidth: Int?) -> URL?
}

// MARK: - Optional capability defaults
//
// Sensible no-op/empty defaults so conformers can implement incrementally
// (e.g. browse before playback) without breaking the build, exactly like the
// optional subtitle defaults on `MediaProvider`.
public extension MusicProvider {
    func artist(id: String) async throws -> MusicArtist {
        MusicArtist(id: id, name: "")
    }

    func album(id: String) async throws -> MusicAlbum {
        MusicAlbum(id: id, title: "")
    }

    func tracks(in containerID: String) async throws -> [MusicTrack] { [] }

    func musicImageURL(id: String, maxWidth: Int?) -> URL? { nil }
}

/// One page of music items plus the total available, the audio analogue of
/// `MediaPage`, so callers can lazily page through large artist/album/track
/// lists.
public struct MusicPage: Equatable, Sendable {
    public var artists: [MusicArtist]
    public var albums: [MusicAlbum]
    public var tracks: [MusicTrack]
    public var playlists: [MusicPlaylist]
    public var genres: [MusicGenre]
    /// Zero-based index of the first item within the full container.
    public var startIndex: Int
    /// Total number of items in the container across all pages.
    public var totalCount: Int

    public init(
        artists: [MusicArtist] = [],
        albums: [MusicAlbum] = [],
        tracks: [MusicTrack] = [],
        playlists: [MusicPlaylist] = [],
        genres: [MusicGenre] = [],
        startIndex: Int = 0,
        totalCount: Int = 0
    ) {
        self.artists = artists
        self.albums = albums
        self.tracks = tracks
        self.playlists = playlists
        self.genres = genres
        self.startIndex = startIndex
        self.totalCount = totalCount
    }

    /// Total number of items carried in this page across all kinds.
    public var count: Int {
        artists.count + albums.count + tracks.count + playlists.count + genres.count
    }

    /// Index one past the last item in this page.
    public var endIndex: Int { startIndex + count }

    /// Whether more items remain beyond this page.
    public var hasMore: Bool { endIndex < totalCount }
}

/// Everything an audio playback engine needs to start a track and build its
/// queue. The audio analogue of `PlaybackRequest`; the provider resolves the
/// stream URL (direct-play or transcode) just as it does for video.
public struct AudioPlaybackRequest: Hashable, Sendable {
    /// The track being played.
    public var track: MusicTrack
    /// The resolved audio stream URL (HLS or direct file).
    public var streamURL: URL
    /// Opaque session id used when reporting progress back to the server.
    public var playSessionID: String?
    /// The ordered queue this track plays within (album/playlist context),
    /// including the track itself. A single-track request has one element.
    public var queue: [MusicTrack]
    /// Index of `track` within `queue`.
    public var queueIndex: Int
    /// Where to resume from, in seconds.
    public var startPosition: TimeInterval
    /// Whether the server is transcoding this stream rather than direct-playing.
    public var isTranscoding: Bool

    public init(
        track: MusicTrack,
        streamURL: URL,
        playSessionID: String? = nil,
        queue: [MusicTrack]? = nil,
        queueIndex: Int = 0,
        startPosition: TimeInterval = 0,
        isTranscoding: Bool = false
    ) {
        self.track = track
        self.streamURL = streamURL
        self.playSessionID = playSessionID
        self.queue = queue ?? [track]
        self.queueIndex = queueIndex
        self.startPosition = startPosition
        self.isTranscoding = isTranscoding
    }
}
