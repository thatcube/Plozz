import Foundation

/// Builds the **VOD** HLS playlists the localhost origin serves to AVPlayer for a
/// locally-remuxed title: one master playlist with a single fMP4 variant, and a
/// media playlist whose segments are cut on the source's real IDR keyframes
/// (accurate per-segment `EXTINF` durations from the segment table) sharing one
/// `EXT-X-MAP` init segment.
///
/// Pure value type (no `Network`/AVFoundation/FFmpeg) so playlist generation is
/// unit-testable on any platform — the crux scrubbing-correctness logic lives
/// here, isolated from the I/O.
public struct RemuxSegmentPlanner: Equatable, Sendable {

    /// Stream facts used to write accurate `CODECS` / `RESOLUTION` / `VIDEO-RANGE`
    /// attributes so AVPlayer reliably triggers full Dolby Vision rendering.
    public struct StreamInfo: Equatable, Sendable {
        public var width: Int
        public var height: Int
        /// Dolby Vision profile (5/8/…); drives the `dvh1` CODECS brand.
        public var dolbyVisionProfile: Int
        public var dolbyVisionLevel: Int
        /// `true` for E-AC-3 audio (`ec-3`), `false` for AC-3 (`ac-3`).
        public var audioIsEAC3: Bool
        /// Declared peak bitrate (bits/sec) for `BANDWIDTH`, or 0 to estimate.
        public var bandwidth: Int

        public init(
            width: Int,
            height: Int,
            dolbyVisionProfile: Int,
            dolbyVisionLevel: Int,
            audioIsEAC3: Bool,
            bandwidth: Int
        ) {
            self.width = width
            self.height = height
            self.dolbyVisionProfile = dolbyVisionProfile
            self.dolbyVisionLevel = dolbyVisionLevel
            self.audioIsEAC3 = audioIsEAC3
            self.bandwidth = bandwidth
        }
    }

    /// Per-segment durations (seconds), in playback order, from the keyframe table.
    public let segmentDurations: [Double]
    public let stream: StreamInfo

    /// Playlist resource names served by the origin.
    public static let masterName = "master.m3u8"
    public static let mediaName = "media.m3u8"
    public static let initName = "init.mp4"
    public static func segmentName(_ index: Int) -> String { "seg\(index).m4s" }

    public init(segmentDurations: [Double], stream: StreamInfo) {
        self.segmentDurations = segmentDurations
        self.stream = stream
    }

    /// Total programme duration (sum of segment durations).
    public var totalDuration: Double { segmentDurations.reduce(0, +) }

    // MARK: - CODECS

    /// HEVC Dolby Vision sample-entry CODECS token, e.g. `dvh1.08.06`. The two
    /// numeric fields are the DV profile and level, zero-padded to two digits —
    /// exactly the form AVPlayer expects for a `dvh1`/`dvhe` HLS variant.
    public var videoCodecToken: String {
        let profile = String(format: "%02d", max(0, stream.dolbyVisionProfile))
        let level = String(format: "%02d", max(0, stream.dolbyVisionLevel))
        return "dvh1.\(profile).\(level)"
    }

    public var audioCodecToken: String { stream.audioIsEAC3 ? "ec-3" : "ac-3" }

    private var estimatedBandwidth: Int {
        if stream.bandwidth > 0 { return stream.bandwidth }
        // Conservative default for a 4K DoVi remux when the provider didn't say.
        return 30_000_000
    }

    // MARK: - Master playlist

    /// The master playlist: a single fMP4 variant carrying the DoVi `CODECS`
    /// brand and `VIDEO-RANGE=PQ` so AVPlayer negotiates true Dolby Vision.
    public func masterPlaylist() -> String {
        let attrs = [
            "BANDWIDTH=\(estimatedBandwidth)",
            "CODECS=\"\(videoCodecToken),\(audioCodecToken)\"",
            "RESOLUTION=\(stream.width)x\(stream.height)",
            "VIDEO-RANGE=PQ"
        ]
        return [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-STREAM-INF:" + attrs.joined(separator: ","),
            Self.mediaName
        ].joined(separator: "\n") + "\n"
    }

    // MARK: - Media playlist

    /// The media playlist: a true VOD list with a shared `EXT-X-MAP` init segment
    /// and one keyframe-cut fMP4 segment per entry, each with its exact `EXTINF`
    /// duration so scrubbing maps to the right segment.
    public func mediaPlaylist() -> String {
        mediaPlaylist(durations: segmentDurations, complete: true)
    }

    /// The media playlist for an explicit (possibly still-growing) `durations` list.
    ///
    /// `complete == true` emits the proven VOD form (`PLAYLIST-TYPE:VOD` +
    /// `EXT-X-ENDLIST`) — the whole timeline is known. `complete == false` emits an
    /// EVENT playlist (`PLAYLIST-TYPE:EVENT`, no `ENDLIST`) carrying only the
    /// segments discovered so far: the B7 lazy/windowed index serves this immediately
    /// after probing just the first window and re-serves a longer list as background
    /// discovery extends the frontier, so AVPlayer starts in a couple seconds
    /// regardless of file size. Because only *fully-bracketed* segments are ever
    /// published (the C core withholds the still-growing trailing group), every
    /// `EXTINF` here equals the real muxed span and never changes between reloads —
    /// so the EVENT→VOD growth introduces no A/V desync. `TARGETDURATION` is the
    /// ceil of the longest known segment (non-decreasing as the list grows).
    public func mediaPlaylist(durations: [Double], complete: Bool) -> String {
        let target = max(1, Int(durations.map { $0.rounded(.up) }.max() ?? 6))
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(target)",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:\(complete ? "VOD" : "EVENT")",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-MAP:URI=\"\(Self.initName)\""
        ]
        for (index, duration) in durations.enumerated() {
            lines.append("#EXTINF:\(Self.formatDuration(duration)),")
            lines.append(Self.segmentName(index))
        }
        if complete {
            lines.append("#EXT-X-ENDLIST")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func formatDuration(_ seconds: Double) -> String {
        String(format: "%.6f", max(0, seconds))
    }
}
