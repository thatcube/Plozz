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

    public init(
        id: Int,
        kind: Kind,
        displayTitle: String,
        language: String? = nil,
        isDefault: Bool = false,
        isForced: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.displayTitle = displayTitle
        self.language = language
        self.isDefault = isDefault
        self.isForced = isForced
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

    public init(
        item: MediaItem,
        streamURL: URL,
        playSessionID: String? = nil,
        audioTracks: [MediaTrack] = [],
        subtitleTracks: [MediaTrack] = [],
        startPosition: TimeInterval = 0,
        isTranscoding: Bool = false
    ) {
        self.item = item
        self.streamURL = streamURL
        self.playSessionID = playSessionID
        self.audioTracks = audioTracks
        self.subtitleTracks = subtitleTracks
        self.startPosition = startPosition
        self.isTranscoding = isTranscoding
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
