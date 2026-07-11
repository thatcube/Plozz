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
    /// Raw codec token from the source/demuxer, lowercased where known
    /// (e.g. `subrip`, `ass`, `pgssub`, `ac3`, `eac3`, `dts`). Drives format
    /// hints in the track menu ("PGS", "SRT") and image-vs-text reasoning.
    /// `nil` when the provider/engine didn't report one.
    public var codec: String?
    public var isDefault: Bool
    public var isForced: Bool
    /// Audio channel count where known (`2` stereo, `6` 5.1, `8` 7.1). `nil` for
    /// subtitles and when the source/engine didn't report one. Drives the audio
    /// format hint ("5.1"/"7.1") in the track menu.
    public var channels: Int?
    /// `true` for Dolby Atmos audio (object-based; the channel count is just the
    /// bed). When set, the menu shows "Dolby Atmos" instead of the bed layout.
    public var isAtmos: Bool
    /// `true` for hearing-impaired / SDH tracks (container disposition). A
    /// reliable signal that supersedes the title-text "SDH" heuristic.
    public var isHearingImpaired: Bool
    /// `true` for commentary tracks (director/cast). Surfaces a "Commentary"
    /// qualifier on audio and subtitle labels.
    public var isCommentary: Bool
    /// For subtitle tracks: an absolute URL that yields the subtitle text
    /// (WebVTT, or SRT which the player normalises to WebVTT). When non-`nil`
    /// the player can inject this track into the native picker even on direct
    /// play. `nil` for audio tracks and for subtitles that can't be delivered
    /// as text (e.g. image-based PGS/VOBSUB, which need server burn-in).
    public var deliveryURL: URL?
    /// `true` for image-based subtitles (PGS/VOBSUB/DVDSUB) that no on-device
    /// engine can render — only a server burn-in transcode shows them. A *text*
    /// subtitle embedded in the container (so it has no `deliveryURL`) is **not**
    /// image-based: Plozzigen remuxes it into the playback stream. Routing must
    /// key off this flag, not `deliveryURL == nil`, or embedded SRT gets pushed
    /// to the hybrid engine (and crashes on multichannel) needlessly.
    public var isImageBasedSubtitle: Bool
    /// `true` for a subtitle that isn't embedded in the media file — a subtitle the
    /// user downloaded this session (server-fetched) or a local sidecar file
    /// (SMB `.srt`/`.ass`). Drives a small "external" marker in the track menu so a
    /// freshly-downloaded sub is distinguishable in a list full of same-language
    /// embedded tracks. Defaults to `false` (embedded).
    public var isExternal: Bool

    public init(
        id: Int,
        kind: Kind,
        displayTitle: String,
        language: String? = nil,
        codec: String? = nil,
        isDefault: Bool = false,
        isForced: Bool = false,
        channels: Int? = nil,
        isAtmos: Bool = false,
        isHearingImpaired: Bool = false,
        isCommentary: Bool = false,
        deliveryURL: URL? = nil,
        isImageBasedSubtitle: Bool = false,
        isExternal: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.displayTitle = displayTitle
        self.language = language
        self.codec = codec
        self.isDefault = isDefault
        self.isForced = isForced
        self.channels = channels
        self.isAtmos = isAtmos
        self.isHearingImpaired = isHearingImpaired
        self.isCommentary = isCommentary
        self.deliveryURL = deliveryURL
        self.isImageBasedSubtitle = isImageBasedSubtitle
        self.isExternal = isExternal
    }

    /// Codec tokens that identify a **bitmap** (image-based) subtitle format —
    /// PGS (Blu-ray), DVD (VOBSUB), DVB, XSUB. Matched case-insensitively, with a
    /// `contains("pgs")` catch for the several PGS spellings
    /// (`pgssub`/`hdmv_pgs_subtitle`/`pgs`).
    public static func isImageSubtitleCodec(_ codec: String?) -> Bool {
        guard let codec = codec?.lowercased(), !codec.isEmpty else { return false }
        if codec.contains("pgs") { return true }
        return ["dvdsub", "dvd_subtitle", "dvbsub", "dvb_subtitle", "vobsub", "xsub"].contains(codec)
    }

    /// Authoritative "is this a bitmap subtitle" across engines. `true` when the
    /// provider flagged `isImageBasedSubtitle` **or** the codec token is a known
    /// bitmap format. The Plozzigen engine leaves `isImageBasedSubtitle` at its
    /// default (`false`) and reports only `codec`, so cross-engine callers — e.g.
    /// the dual-subtitle picker, which must positionally stack two *text* lines —
    /// should key off this, not the raw flag. The raw flag stays reserved for
    /// default-subtitle **routing** (a `true` there suppresses auto-selection),
    /// which must remain `false` on Plozzigen so PGS still auto-selects and draws.
    public var isBitmapSubtitle: Bool {
        isImageBasedSubtitle || MediaTrack.isImageSubtitleCodec(codec)
    }
}

/// Source-of-truth media facts a provider knows about the *original* file,
/// independent of how it ends up being streamed (direct vs transcode).
///
/// This is what powers the rich playback-diagnostics overlay: when the server
/// transcodes, the `AVPlayer` stream exposes almost no track metadata, so we
/// rely on these provider-reported facts (codec, HDR, resolution, bitrate,
/// channels, …) instead — the same source a client like Infuse reads.
public struct MediaSourceMetadata: Hashable, Sendable, Codable {
    public struct VideoStream: Hashable, Sendable, Codable {
        /// Raw codec token from the provider, e.g. `hevc`, `h264`, `av1`.
        public var codec: String?
        /// Container codec FourCC tag, e.g. `hvc1`/`hev1` for HEVC. AVPlayer only
        /// decodes HEVC tagged `hvc1`; `hev1` plays audio with a black screen, so
        /// this drives a re-tag remux (Jellyfin) or an on-device engine fallback.
        public var codecTag: String?
        /// Codec profile, e.g. `Main 10`, `High`.
        public var profile: String?
        /// Whether the source stream is interlaced (`true`) rather than
        /// progressive (`false`/`nil`). Interlaced direct-play is routed to the
        /// on-device engine when available.
        public var isInterlaced: Bool?
        public var width: Int?
        public var height: Int?
        /// Bits per luma sample, e.g. `8`, `10`, `12`. AVPlayer cannot decode
        /// 10-bit **H.264** (High 10), so this drives an on-device engine fallback.
        public var bitDepth: Int?
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
        /// Explicit Dolby Vision profile number when the provider reports it. Plex
        /// exposes this directly; Jellyfin-backed callers may derive it from
        /// `videoRangeType` when only the single-layer token is known.
        public var dolbyVisionProfile: Int?

        public init(
            codec: String? = nil,
            codecTag: String? = nil,
            profile: String? = nil,
            isInterlaced: Bool? = nil,
            width: Int? = nil,
            height: Int? = nil,
            bitDepth: Int? = nil,
            bitrate: Int? = nil,
            frameRate: Double? = nil,
            videoRange: String? = nil,
            videoRangeType: String? = nil,
            colorTransfer: String? = nil,
            dolbyVisionProfile: Int? = nil
        ) {
            self.codec = codec
            self.codecTag = codecTag
            self.profile = profile
            self.isInterlaced = isInterlaced
            self.width = width
            self.height = height
            self.bitDepth = bitDepth
            self.bitrate = bitrate
            self.frameRate = frameRate
            self.videoRange = videoRange
            self.videoRangeType = videoRangeType
            self.colorTransfer = colorTransfer
            self.dolbyVisionProfile = dolbyVisionProfile
        }
    }

    public struct AudioStream: Hashable, Sendable, Codable {
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

    public struct SubtitleStream: Hashable, Sendable, Codable {
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
    /// An optional *separate* audio track to be muxed with `streamURL` at playback
    /// time. Used for adaptive sources whose video and audio are delivered as two
    /// distinct streams (e.g. a high-resolution YouTube DASH trailer: `streamURL`
    /// is video-only, this is the companion audio). Only the **Plozzigen**
    /// engine can combine two bare URLs, so a request that sets this must be
    /// routed there; `nil` for ordinary single-file/HLS playback.
    public var externalAudioURL: URL?
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
    /// The original authenticated/range-readable bytes plus enough source facts for
    /// a local-remux strategy to synthesize its own AVPlayer-safe stream.
    public var localRemuxSource: LocalRemuxSourceDescriptor?
    /// Scrubbing-preview thumbnails for this item, when the server has generated
    /// them (Jellyfin trickplay tiles or a Plex BIF index). `nil` (or an unusable
    /// source) means the custom player simply shows no scrub preview — it never
    /// blocks playback.
    public var scrubPreview: ScrubPreviewSource?
    /// Whether the resolved `streamURL` is already a manifest/playlist-style stream
    /// (server HLS or a local-remux HLS facade) and therefore should be fed
    /// straight to AVPlayer rather than wrapped for subtitle injection.
    public var isManifestStream: Bool
    /// Which backend (Plex / Jellyfin) resolved this playback. Surfaced in the
    /// diagnostics overlay's "Source Provider" row so a tester can tell at a glance
    /// whether a given title is being served from Plex or Jellyfin. `nil` for
    /// sources without a first-class provider (e.g. YouTube trailers).
    public var sourceProvider: ProviderKind?
    /// Friendly name of the media server (e.g. "Allie's Jellyfin", "Living Room").
    public var serverName: String?
    /// Basename of the selected source file, when the provider exposes it. Kept
    /// separate from `streamURL`: Plex/Jellyfin often play an API/transcode URL
    /// whose last path component is not the original media filename.
    public var sourceFileName: String?
    /// Ordered ISO-639 audio languages to steer the engine's INITIAL active audio
    /// track at load (AetherEngine `LoadOptions.preferredAudioLanguages` — first
    /// match wins, no reload). Computed by `PlayerViewModel` from per-series
    /// memory / prefer-original-language policy just before `engine.load`. Empty =
    /// express no preference (engine uses the container default). Not part of the
    /// memberwise init so the many provider construction sites stay untouched.
    public var preferredAudioLanguages: [String] = []
    /// Ordered ISO-639 subtitle languages to steer the engine's initial subtitle
    /// selection at load, the subtitle counterpart to `preferredAudioLanguages`.
    public var preferredSubtitleLanguages: [String] = []

    public init(
        item: MediaItem,
        streamURL: URL,
        externalAudioURL: URL? = nil,
        playSessionID: String? = nil,
        audioTracks: [MediaTrack] = [],
        subtitleTracks: [MediaTrack] = [],
        startPosition: TimeInterval = 0,
        isTranscoding: Bool = false,
        deliveryMode: PlaybackDiagnostics.PlaybackMode? = nil,
        sourceMetadata: MediaSourceMetadata? = nil,
        localRemuxSource: LocalRemuxSourceDescriptor? = nil,
        scrubPreview: ScrubPreviewSource? = nil,
        sourceProvider: ProviderKind? = nil,
        serverName: String? = nil,
        sourceFileName: String? = nil
    ) {
        self.item = item
        self.streamURL = streamURL
        self.externalAudioURL = externalAudioURL
        self.playSessionID = playSessionID
        self.audioTracks = audioTracks
        self.subtitleTracks = subtitleTracks
        self.startPosition = startPosition
        self.isTranscoding = isTranscoding
        self.deliveryMode = deliveryMode ?? (isTranscoding ? .transcode : .directPlay)
        self.sourceMetadata = sourceMetadata
        self.localRemuxSource = localRemuxSource
        self.scrubPreview = scrubPreview
        self.isManifestStream = isTranscoding || streamURL.pathExtension.lowercased() == "m3u8"
        self.sourceProvider = sourceProvider
        self.serverName = serverName
        self.sourceFileName = sourceFileName
    }

    /// Basename from either POSIX or Windows server paths. Darwin's
    /// `NSString.lastPathComponent` only recognizes `/`, so using it directly can
    /// expose a full `D:\Media\Movie.mkv` path in diagnostics.
    public static func sourceFileName(from path: String?) -> String? {
        guard let path else { return nil }
        let value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return value
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .last
            .map(String.init)
    }
}

/// A point-in-time playback progress report.
public struct PlaybackProgress: Hashable, Sendable {
    public var itemID: String
    public var playSessionID: String?
    public var positionSeconds: TimeInterval
    public var isPaused: Bool
    /// Total media duration in seconds when the player knows it, else `nil`.
    /// Plex/Jellyfin ignore this (their servers own progress percentages), but a
    /// local media share has no server, so it persists this alongside the resume
    /// position to render a Continue Watching progress bar (`position / duration`)
    /// — a bare position can't be turned into a percentage without it.
    public var durationSeconds: TimeInterval?

    public init(
        itemID: String,
        playSessionID: String?,
        positionSeconds: TimeInterval,
        isPaused: Bool,
        durationSeconds: TimeInterval? = nil
    ) {
        self.itemID = itemID
        self.playSessionID = playSessionID
        self.positionSeconds = positionSeconds
        self.isPaused = isPaused
        self.durationSeconds = durationSeconds
    }
}
