import Foundation
import YouTubeKit

/// A resolved trailer stream.
///
/// Either a single self-contained URL (a progressive muxed MP4 or an HLS
/// manifest that `AVPlayer` plays directly) or — for higher resolutions YouTube
/// only offers as *adaptive* tracks — a video-only URL paired with a separate
/// audio URL. AVPlayer can't combine two bare URLs, so an adaptive pair is played
/// by the Plozzigen engine, which muxes them at playback time.
public struct TrailerStream: Equatable, Sendable {
    /// The video (or muxed) stream URL — always present and always the one to
    /// byte-verify, since it carries the picture.
    public let videoURL: URL
    /// A separate adaptive audio URL to mux with `videoURL`, or `nil` when
    /// `videoURL` is already self-contained (progressive/HLS).
    public let audioURL: URL?
    /// Smaller side of the video resolution (e.g. `1080`), when known.
    public let resolution: Int?

    /// Whether this is an adaptive video+audio pair (needs the hybrid engine).
    public var isAdaptive: Bool { audioURL != nil }

    public init(videoURL: URL, audioURL: URL? = nil, resolution: Int? = nil) {
        self.videoURL = videoURL
        self.audioURL = audioURL
        self.resolution = resolution
    }
}

/// The subset of a YouTubeKit `Stream`'s facts the trailer selector needs, lifted
/// into a plain value so the selection *policy* is pure and unit-testable without
/// constructing real `Stream`s (which can only be built from YouTube internals).
struct TrailerStreamCandidate: Equatable {
    /// Coarse video codec family, used to prefer a hardware-decodable picture.
    enum VideoKind: Equatable { case none, avc1, vp9, av1, mp4v, otherVideo }

    var url: URL
    /// Smaller side of the video resolution (e.g. `1080`), or `nil` for audio.
    var resolution: Int?
    /// Muxed (video+audio in one stream) vs. adaptive (one track only).
    var isProgressive: Bool
    var hasVideo: Bool
    var hasAudio: Bool
    /// Whether AVPlayer can decode the stream as-is.
    var isNativelyPlayable: Bool
    var videoKind: VideoKind
    /// Declared bitrate in bits/sec (used to rank adaptive audio).
    var bitrate: Int?
    /// Whether the audio codec is one AVPlayer decodes (mp4a/ac-3/ec-3).
    var audioNativelyPlayable: Bool
}

extension TrailerStreamCandidate {
    /// Lifts a YouTubeKit `Stream` into the pure candidate value.
    init(_ stream: YouTubeKit.Stream) {
        self.url = stream.url
        self.resolution = stream.videoResolution
        self.isProgressive = stream.isProgressive
        self.hasVideo = stream.includesVideoTrack
        self.hasAudio = stream.includesAudioTrack
        self.isNativelyPlayable = stream.isNativelyPlayable
        self.bitrate = stream.bitrate ?? stream.averageBitrate
        self.audioNativelyPlayable = stream.audioCodec?.isNativelyPlayable ?? false

        let codec = stream.videoCodec
        if codec == nil {
            self.videoKind = .none
        } else if codec == .avc1 {
            self.videoKind = .avc1
        } else if codec == .vp9 {
            self.videoKind = .vp9
        } else if codec == .av1 {
            self.videoKind = .av1
        } else if codec == .mp4v {
            self.videoKind = .mp4v
        } else {
            self.videoKind = .otherVideo
        }
    }
}

enum TrailerStreamSelector {
    /// Chooses the best trailer stream, trading resolution against reliability.
    ///
    ///  1. A high-resolution **adaptive** pair (video-only + audio-only) when it
    ///     beats the best progressive muxed stream — played by the hybrid engine.
    ///     Capped at `maxAdaptiveResolution`, and preferring H.264 video the Apple
    ///     TV decodes in hardware so a 1080p trailer never stutters on a software
    ///     VP9/AV1 path. Only considered when `allowAdaptive` is `true` (i.e. a
    ///     hybrid engine is actually wired in to mux the two tracks).
    ///  2. The best progressive **muxed** stream (native AVPlayer) — the reliable
    ///     baseline that serves its bytes directly (unlike PO-token-gated HLS
    ///     segments).
    ///  3. Any single natively-playable stream, as a last resort.
    ///
    /// HLS is intentionally *not* handled here — it needs a separate fetch — so a
    /// `nil` result tells the caller to try the HLS manifest next.
    static func selectTrailerStream(
        from candidates: [TrailerStreamCandidate],
        allowAdaptive: Bool,
        maxAdaptiveResolution: Int = 1080
    ) -> TrailerStream? {
        let bestProgressive = candidates
            .filter { $0.isProgressive && $0.isNativelyPlayable && $0.hasVideo }
            .max(by: { ($0.resolution ?? 0) < ($1.resolution ?? 0) })
        let progressiveResolution = bestProgressive?.resolution ?? 0

        if allowAdaptive,
           let video = bestAdaptiveVideo(in: candidates, maxResolution: maxAdaptiveResolution),
           let audio = bestAdaptiveAudio(in: candidates),
           (video.resolution ?? 0) > progressiveResolution {
            return TrailerStream(videoURL: video.url, audioURL: audio.url, resolution: video.resolution)
        }

        if let progressive = bestProgressive {
            return TrailerStream(videoURL: progressive.url, resolution: progressive.resolution)
        }

        // Last resort: any single natively-playable stream with a picture.
        if let any = candidates
            .filter({ $0.isNativelyPlayable && $0.hasVideo })
            .max(by: { ($0.resolution ?? 0) < ($1.resolution ?? 0) }) {
            return TrailerStream(videoURL: any.url, resolution: any.resolution)
        }

        return nil
    }

    /// Best adaptive video-only track: prefer the highest-resolution **H.264**
    /// (hardware-decoded on every Apple TV) up to the cap; only fall back to a
    /// VP9/AV1 track when no usable H.264 exists.
    static func bestAdaptiveVideo(
        in candidates: [TrailerStreamCandidate],
        maxResolution: Int
    ) -> TrailerStreamCandidate? {
        let videoOnly = candidates.filter {
            $0.hasVideo && !$0.hasAudio
                && ($0.resolution ?? 0) > 0
                && ($0.resolution ?? Int.max) <= maxResolution
        }
        let h264 = videoOnly.filter { $0.videoKind == .avc1 }
        if let best = h264.max(by: { ($0.resolution ?? 0) < ($1.resolution ?? 0) }) {
            return best
        }
        return videoOnly.max(by: { ($0.resolution ?? 0) < ($1.resolution ?? 0) })
    }

    /// Best adaptive audio-only track: prefer an AVPlayer-native codec (AAC) by
    /// bitrate, otherwise the highest-bitrate track (Plozzigen decodes Opus fine).
    static func bestAdaptiveAudio(in candidates: [TrailerStreamCandidate]) -> TrailerStreamCandidate? {
        let audioOnly = candidates.filter { $0.hasAudio && !$0.hasVideo }
        let native = audioOnly.filter { $0.audioNativelyPlayable }
        if let best = native.max(by: { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) }) {
            return best
        }
        return audioOnly.max(by: { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) })
    }
}
