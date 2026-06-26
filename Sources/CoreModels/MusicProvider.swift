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

    /// Library-scoped variant of the global browse: restricts an *empty-container*
    /// (whole-library) query to `libraryIDs` — the user's currently **visible**
    /// music libraries. `nil` (or a non-empty container) means "all libraries",
    /// so existing behavior is unchanged. The default delegates to the unscoped
    /// method; providers override to actually honor the scope.
    func musicItems(in containerID: String, kind: MusicItemKind, page: PageRequest, libraryIDs: [String]?) async throws -> MusicPage

    /// Recently played albums across the user's music libraries, most-recent
    /// first, excluding never-played albums. Each returned album carries a
    /// `lastPlayedAt` timestamp so callers can merge-sort recency *across* many
    /// libraries/servers rather than trusting any single server's local order.
    func recentlyPlayed(limit: Int) async throws -> [MusicAlbum]

    /// Library-scoped variant of `recentlyPlayed`, restricted to the visible
    /// `libraryIDs` (`nil` = all). The default delegates to the unscoped method.
    func recentlyPlayed(limit: Int, libraryIDs: [String]?) async throws -> [MusicAlbum]

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

    // MARK: Lyrics

    /// Lyrics for a track, synced (timestamped) or plain, or `nil` when the
    /// backend has none for this track. Optional capability — providers without
    /// lyrics support inherit the no-op default below.
    func lyrics(for trackID: String) async throws -> Lyrics?

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

    func lyrics(for trackID: String) async throws -> Lyrics? { nil }

    func recentlyPlayed(limit: Int) async throws -> [MusicAlbum] { [] }

    func musicItems(in containerID: String, kind: MusicItemKind, page: PageRequest, libraryIDs: [String]?) async throws -> MusicPage {
        try await musicItems(in: containerID, kind: kind, page: page)
    }

    func recentlyPlayed(limit: Int, libraryIDs: [String]?) async throws -> [MusicAlbum] {
        try await recentlyPlayed(limit: limit)
    }

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

/// A snapshot of the audio fidelity an active stream is delivering, so the UI
/// can tell the user whether they're hearing the original file (best quality)
/// or a transcoded, lossy version.
///
/// The provider fills this in when it resolves a stream URL: it already knows
/// the source codec/container and whether it asked the server to transcode, so
/// the decision is deterministic and doesn't require a server round-trip.
public struct PlaybackQuality: Hashable, Sendable {
    /// `true` when the server streams the original file untouched (highest
    /// quality available); `false` when it's transcoding to a lossy target.
    public var isDirectPlay: Bool
    /// Source audio codec, lowercased (e.g. `"flac"`, `"alac"`, `"aac"`, `"mp3"`).
    public var codec: String?
    /// Source container (e.g. `"flac"`, `"m4a"`).
    public var container: String?
    /// Audio bitrate in bits/sec. For direct play this is the source bitrate;
    /// for a transcode it's the target bitrate.
    public var bitrate: Int?
    /// Sample rate in Hz (e.g. `44100`, `96000`).
    public var sampleRate: Int?
    /// Bits per sample (e.g. `16`, `24`); `nil` when unknown or lossy.
    public var bitDepth: Int?
    /// Channel count (`2` = stereo).
    public var channels: Int?
    /// When transcoding, the lossy target codec (e.g. `"aac"`, `"mp3"`).
    public var transcodeCodec: String?

    public init(
        isDirectPlay: Bool,
        codec: String? = nil,
        container: String? = nil,
        bitrate: Int? = nil,
        sampleRate: Int? = nil,
        bitDepth: Int? = nil,
        channels: Int? = nil,
        transcodeCodec: String? = nil
    ) {
        self.isDirectPlay = isDirectPlay
        self.codec = codec
        self.container = container
        self.bitrate = bitrate
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.channels = channels
        self.transcodeCodec = transcodeCodec
    }

    /// Lossless audio codecs (no quality lost relative to the master).
    private static let losslessCodecs: Set<String> = [
        "flac", "alac", "wav", "pcm", "lpcm", "aiff", "aif", "ape", "wavpack", "tak", "tta"
    ]

    /// Whether the codec actually being delivered preserves full fidelity.
    /// Only meaningful when `isDirectPlay` is true (a transcode is lossy).
    public var isLossless: Bool {
        guard isDirectPlay, let codec else { return false }
        return Self.losslessCodecs.contains(codec.lowercased())
    }

    /// Short headline describing the tier:
    /// `"Lossless"` (direct-play lossless), `"Original"` (direct-play lossy
    /// source, not degraded), or `"Transcoding"` (re-encoded, reduced).
    public var headline: String {
        if !isDirectPlay { return "Transcoding" }
        return isLossless ? "Lossless" : "Original"
    }

    /// One-line technical detail (codec + bit depth/sample rate or bitrate),
    /// e.g. `"FLAC · 24-bit/96kHz"`, `"ALAC · 44.1kHz"`, `"MP3 · 320 kbps"`.
    /// Returns `nil` when no facts are known.
    public var detail: String? {
        let label = (isDirectPlay ? codec : transcodeCodec)?.uppercased()
        var parts: [String] = []

        if let bitDepth, isDirectPlay {
            if let sampleRate {
                parts.append("\(bitDepth)-bit/\(Self.sampleRateString(sampleRate))")
            } else {
                parts.append("\(bitDepth)-bit")
            }
        } else if let sampleRate, isDirectPlay {
            parts.append(Self.sampleRateString(sampleRate))
        }

        if let bitrate, bitrate > 0 {
            // Lossless bitrates aren't a meaningful quality knob, so only show
            // the bitrate when we don't already have bit depth / sample rate,
            // or when this is a lossy stream where bitrate *is* the quality.
            if !isLossless || parts.isEmpty {
                parts.append("\(bitrate / 1000) kbps")
            }
        }

        let suffix = parts.joined(separator: " · ")
        switch (label, suffix.isEmpty) {
        case let (label?, false): return "\(label) · \(suffix)"
        case let (label?, true): return label
        case (nil, false): return suffix
        case (nil, true): return nil
        }
    }

    private static func sampleRateString(_ hz: Int) -> String {
        let khz = Double(hz) / 1000
        if khz == khz.rounded() {
            return "\(Int(khz))kHz"
        }
        return String(format: "%.1fkHz", khz)
    }
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
    /// Fidelity details for the resolved stream, surfaced in the UI so the user
    /// can confirm they're hearing the original file vs a transcode.
    public var quality: PlaybackQuality?

    public init(
        track: MusicTrack,
        streamURL: URL,
        playSessionID: String? = nil,
        queue: [MusicTrack]? = nil,
        queueIndex: Int = 0,
        startPosition: TimeInterval = 0,
        isTranscoding: Bool = false,
        quality: PlaybackQuality? = nil
    ) {
        self.track = track
        self.streamURL = streamURL
        self.playSessionID = playSessionID
        self.queue = queue ?? [track]
        self.queueIndex = queueIndex
        self.startPosition = startPosition
        self.isTranscoding = isTranscoding
        self.quality = quality
    }
}
