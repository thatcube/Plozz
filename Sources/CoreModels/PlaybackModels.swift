import Foundation

/// A selectable audio or subtitle track exposed by a stream.
public struct MediaTrack: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case audio
        case subtitle
    }

    /// Provider-native stream index (stable for a given playback session).
    public var id: Int
    public var kind: Kind
    public var displayTitle: String
    /// BCP-47 / ISO language code if known (e.g. `en`, `fra`).
    public var language: String?
    public var isDefault: Bool
    public var isForced: Bool
    /// For subtitle tracks: an absolute URL that yields the subtitle text
    /// (WebVTT, or SRT which the player normalises to WebVTT). When non-`nil`
    /// the player can inject this track into the native picker even on direct
    /// play. `nil` for audio tracks and for subtitles that can't be delivered
    /// as text (e.g. image-based PGS/VOBSUB, which need server burn-in).
    public var deliveryURL: URL?

    public init(
        id: Int,
        kind: Kind,
        displayTitle: String,
        language: String? = nil,
        isDefault: Bool = false,
        isForced: Bool = false,
        deliveryURL: URL? = nil
    ) {
        self.id = id
        self.kind = kind
        self.displayTitle = displayTitle
        self.language = language
        self.isDefault = isDefault
        self.isForced = isForced
        self.deliveryURL = deliveryURL
    }
}

/// Source-of-truth media facts a provider knows about the *original* file,
/// independent of how it ends up being streamed (direct vs transcode).
///
/// This is what powers the rich playback-diagnostics overlay: when the server
/// transcodes, the `AVPlayer` stream exposes almost no track metadata, so we
/// rely on these provider-reported facts (codec, HDR, resolution, bitrate,
/// channels, …) instead — the same source a client like Infuse reads.
public struct MediaSourceMetadata: Hashable, Sendable {
    public struct VideoStream: Hashable, Sendable {
        /// Raw codec token from the provider, e.g. `hevc`, `h264`, `av1`.
        public var codec: String?
        /// Codec profile, e.g. `Main 10`, `High`.
        public var profile: String?
        public var width: Int?
        public var height: Int?
        /// Declared video bitrate in bits/sec.
        public var bitrate: Int?
        public var frameRate: Double?
        /// Coarse range token, e.g. `HDR`, `SDR` (Jellyfin `VideoRange`).
        public var videoRange: String?
        /// Specific range token, e.g. `DOVI`, `HDR10`, `HLG` (Jellyfin
        /// `VideoRangeType`).
        public var videoRangeType: String?
        /// Color transfer characteristics, e.g. `smpte2084`, `arib-std-b67`.
        public var colorTransfer: String?

        public init(
            codec: String? = nil,
            profile: String? = nil,
            width: Int? = nil,
            height: Int? = nil,
            bitrate: Int? = nil,
            frameRate: Double? = nil,
            videoRange: String? = nil,
            videoRangeType: String? = nil,
            colorTransfer: String? = nil
        ) {
            self.codec = codec
            self.profile = profile
            self.width = width
            self.height = height
            self.bitrate = bitrate
            self.frameRate = frameRate
            self.videoRange = videoRange
            self.videoRangeType = videoRangeType
            self.colorTransfer = colorTransfer
        }
    }

    public struct AudioStream: Hashable, Sendable {
        /// Raw codec token, e.g. `eac3`, `aac`, `dts`.
        public var codec: String?
        /// Codec profile, e.g. `Dolby Atmos`, `DTS-HD MA`.
        public var profile: String?
        public var channels: Int?
        /// Channel layout label, e.g. `5.1`, `7.1`, `stereo`.
        public var channelLayout: String?
        /// Sample rate in Hz.
        public var sampleRate: Int?
        /// Declared audio bitrate in bits/sec.
        public var bitrate: Int?
        public var language: String?

        public init(
            codec: String? = nil,
            profile: String? = nil,
            channels: Int? = nil,
            channelLayout: String? = nil,
            sampleRate: Int? = nil,
            bitrate: Int? = nil,
            language: String? = nil
        ) {
            self.codec = codec
            self.profile = profile
            self.channels = channels
            self.channelLayout = channelLayout
            self.sampleRate = sampleRate
            self.bitrate = bitrate
            self.language = language
        }
    }

    public struct SubtitleStream: Hashable, Sendable {
        public var codec: String?
        public var language: String?
        public var title: String?

        public init(codec: String? = nil, language: String? = nil, title: String? = nil) {
            self.codec = codec
            self.language = language
            self.title = title
        }
    }

    /// Original container, e.g. `mkv`, `mp4`.
    public var container: String?
    public var video: VideoStream?
    public var audio: AudioStream?
    public var subtitle: SubtitleStream?

    public init(
        container: String? = nil,
        video: VideoStream? = nil,
        audio: AudioStream? = nil,
        subtitle: SubtitleStream? = nil
    ) {
        self.container = container
        self.video = video
        self.audio = audio
        self.subtitle = subtitle
    }

    /// True when no useful field was populated (lets callers skip wiring it up).
    public var isEmpty: Bool {
        container == nil && video == nil && audio == nil && subtitle == nil
    }
}

/// Everything `FeaturePlayback` needs to start playing an item.
///
/// Built by a provider's `playbackInfo(for:)`. The provider decides whether to
/// direct-play or transcode and hands back a ready-to-play URL.
public struct PlaybackRequest: Hashable, Sendable {
    public var item: MediaItem
    /// The resolved media stream URL (HLS or direct file).
    public var streamURL: URL
    /// Opaque session identifier used when reporting progress back to the server.
    public var playSessionID: String?
    public var audioTracks: [MediaTrack]
    public var subtitleTracks: [MediaTrack]
    /// Where to resume from, in seconds.
    public var startPosition: TimeInterval
    /// Whether the server is transcoding this stream (a `TranscodingUrl` was
    /// used) rather than direct-playing the original file. Surfaced by the
    /// playback diagnostics overlay.
    public var isTranscoding: Bool
    /// How the server is delivering the stream — direct play, **remux** (lossless
    /// container change, no re-encode), or **transcode** (re-encode). Surfaced by
    /// the diagnostics overlay so the user can tell a lossless DoVi remux apart
    /// from a quality-reducing re-encode. Defaults from `isTranscoding` when a
    /// provider doesn't classify it explicitly.
    public var deliveryMode: PlaybackDiagnostics.PlaybackMode
    /// Source-of-truth media facts (codec, HDR, resolution, channels, …) read
    /// from the provider, used to populate the playback-diagnostics overlay even
    /// when the streamed (transcoded) asset exposes no track metadata.
    public var sourceMetadata: MediaSourceMetadata?
    /// Scrubbing-preview thumbnails for this item, when the server has generated
    /// them. `nil` (or an unusable manifest) means the custom player simply shows
    /// no scrub preview — it never blocks playback.
    public var trickplay: TrickplayManifest?

    public init(
        item: MediaItem,
        streamURL: URL,
        playSessionID: String? = nil,
        audioTracks: [MediaTrack] = [],
        subtitleTracks: [MediaTrack] = [],
        startPosition: TimeInterval = 0,
        isTranscoding: Bool = false,
        deliveryMode: PlaybackDiagnostics.PlaybackMode? = nil,
        sourceMetadata: MediaSourceMetadata? = nil,
        trickplay: TrickplayManifest? = nil
    ) {
        self.item = item
        self.streamURL = streamURL
        self.playSessionID = playSessionID
        self.audioTracks = audioTracks
        self.subtitleTracks = subtitleTracks
        self.startPosition = startPosition
        self.isTranscoding = isTranscoding
        self.deliveryMode = deliveryMode ?? (isTranscoding ? .transcode : .directPlay)
        self.sourceMetadata = sourceMetadata
        self.trickplay = trickplay
    }
}

/// A point-in-time playback progress report.
public struct PlaybackProgress: Hashable, Sendable {
    public var itemID: String
    public var playSessionID: String?
    public var positionSeconds: TimeInterval
    public var isPaused: Bool

    public init(
        itemID: String,
        playSessionID: String?,
        positionSeconds: TimeInterval,
        isPaused: Bool
    ) {
        self.itemID = itemID
        self.playSessionID = playSessionID
        self.positionSeconds = positionSeconds
        self.isPaused = isPaused
    }
}
