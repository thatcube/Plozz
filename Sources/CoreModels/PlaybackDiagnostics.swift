import Foundation

/// A point-in-time snapshot of everything the diagnostics overlay shows about
/// the currently-playing video.
///
/// This is a **pure value type** with no AVFoundation dependency so the
/// classification and formatting logic can be unit-tested in isolation. The
/// platform sampler (`FeaturePlayback`) reads the raw values off
/// `AVPlayerItem`/`AVPlayer` and hands plain strings/numbers to the pure
/// helpers below.
public struct PlaybackDiagnostics: Equatable, Sendable {
    /// Whether the server is streaming the original file or transcoding it.
    public enum PlaybackMode: String, Sendable {
        case directPlay
        case transcode
        case unknown

        public var displayName: String {
            switch self {
            case .directPlay: return "Direct Play"
            case .transcode: return "Transcode"
            case .unknown: return "Unknown"
            }
        }
    }

    /// High-dynamic-range classification derived from codec + transfer function.
    public enum HDRFormat: String, Sendable {
        case sdr
        case hlg
        case hdr10
        case dolbyVision
        case unknown

        public var displayName: String {
            switch self {
            case .sdr: return "SDR"
            case .hlg: return "HDR (HLG)"
            case .hdr10: return "HDR10 (PQ)"
            case .dolbyVision: return "Dolby Vision"
            case .unknown: return "Unknown"
            }
        }
    }

    /// Decoded pixel dimensions of the video.
    public struct VideoResolution: Equatable, Sendable {
        public var width: Int
        public var height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }

        /// e.g. `1920×1080`.
        public var displayString: String { "\(width)×\(height)" }

        /// Friendly quality label based on the vertical resolution.
        public var qualityLabel: String? {
            switch height {
            case 4320...: return "8K"
            case 2160..<4320: return "4K"
            case 1440..<2160: return "1440p"
            case 1080..<1440: return "1080p"
            case 720..<1080: return "720p"
            case 480..<720: return "480p"
            case 1..<480: return "SD"
            default: return nil
            }
        }
    }

    public var resolution: VideoResolution?
    /// Bitrate the playlist *declares* for the current variant, in bits/sec.
    public var indicatedBitrate: Double?
    /// Bitrate actually *observed* over the network, in bits/sec.
    public var observedBitrate: Double?
    public var videoCodec: String?
    public var audioCodec: String?
    public var container: String?
    public var mode: PlaybackMode
    public var hdr: HDRFormat
    /// Seconds of media buffered ahead of the current playback position.
    public var bufferedSecondsAhead: Double?
    /// Cumulative dropped video frames reported by the access log.
    public var droppedVideoFrames: Int?
    /// Nominal frame rate of the video track, in frames/sec.
    public var frameRate: Double?

    public init(
        resolution: VideoResolution? = nil,
        indicatedBitrate: Double? = nil,
        observedBitrate: Double? = nil,
        videoCodec: String? = nil,
        audioCodec: String? = nil,
        container: String? = nil,
        mode: PlaybackMode = .unknown,
        hdr: HDRFormat = .unknown,
        bufferedSecondsAhead: Double? = nil,
        droppedVideoFrames: Int? = nil,
        frameRate: Double? = nil
    ) {
        self.resolution = resolution
        self.indicatedBitrate = indicatedBitrate
        self.observedBitrate = observedBitrate
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.container = container
        self.mode = mode
        self.hdr = hdr
        self.bufferedSecondsAhead = bufferedSecondsAhead
        self.droppedVideoFrames = droppedVideoFrames
        self.frameRate = frameRate
    }
}

// MARK: - Classification (pure, unit-tested)

public extension PlaybackDiagnostics {
    /// Classifies the HDR format from the raw video codec FourCC string and the
    /// CoreMedia transfer-function extension string.
    ///
    /// Detection rules (case-insensitive, substring-based so it is robust to
    /// the various spellings AVFoundation returns):
    ///  * Dolby Vision profiles use a `dvh1` / `dvhe` / `dav1` codec tag.
    ///  * PQ (HDR10) is signalled by the SMPTE ST 2084 transfer function.
    ///  * HLG is signalled by the ITU-R BT.2100 HLG transfer function.
    ///  * Anything else (incl. BT.709) is treated as SDR.
    static func classifyHDR(videoCodec: String?, transferFunction: String?) -> HDRFormat {
        let codec = (videoCodec ?? "").lowercased()
        if codec.contains("dvh1") || codec.contains("dvhe") || codec.contains("dav1") || codec.contains("dvav") {
            return .dolbyVision
        }

        guard let raw = transferFunction?.uppercased(), !raw.isEmpty else {
            return .sdr
        }
        if raw.contains("2084") || raw.contains("PQ") {
            return .hdr10
        }
        if raw.contains("HLG") || raw.contains("2100_HLG") {
            return .hlg
        }
        return .sdr
    }

    /// Human-readable codec name for common FourCC tags, falling back to the
    /// uppercased raw tag for anything unrecognised.
    static func friendlyCodecName(_ fourCC: String?) -> String? {
        guard let raw = fourCC?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "avc1", "h264": return "H.264"
        case "hvc1", "hev1", "h265": return "HEVC"
        case "dvh1", "dvhe", "dvav", "dvav1": return "Dolby Vision"
        case "av01", "dav1": return "AV1"
        case "vp09", "vp9": return "VP9"
        case "mp4v": return "MPEG-4"
        case "mp4a", "aac", "aac ": return "AAC"
        case "ac-3", "ac3": return "Dolby Digital"
        case "ec-3", "eac3": return "Dolby Digital+"
        case "dtsc", "dts", "dtsh": return "DTS"
        case "alac": return "ALAC"
        case "opus": return "Opus"
        case "flac": return "FLAC"
        case "mp3", ".mp3": return "MP3"
        default: return raw.uppercased()
        }
    }
}

// MARK: - Formatting (pure, unit-tested)

public extension PlaybackDiagnostics {
    static let placeholder = "—"

    /// Formats a bits/sec value as `Mbps`/`Kbps`. Returns a placeholder for
    /// missing or non-positive values.
    static func formatBitrate(_ bitsPerSecond: Double?) -> String {
        guard let bps = bitsPerSecond, bps > 0 else { return placeholder }
        if bps >= 1_000_000 {
            return String(format: "%.1f Mbps", bps / 1_000_000)
        }
        if bps >= 1_000 {
            return String(format: "%.0f Kbps", bps / 1_000)
        }
        return String(format: "%.0f bps", bps)
    }

    /// Formats a buffered-ahead duration in seconds, e.g. `12.0s`.
    static func formatBuffer(_ seconds: Double?) -> String {
        guard let seconds, seconds >= 0, seconds.isFinite else { return placeholder }
        return String(format: "%.1fs", seconds)
    }

    /// Formats a frame rate, e.g. `23.976 fps` → `23.98 fps`.
    static func formatFrameRate(_ fps: Double?) -> String {
        guard let fps, fps > 0, fps.isFinite else { return placeholder }
        return String(format: "%.2f fps", fps)
    }

    /// Formats a resolution with an optional quality label, e.g.
    /// `3840×2160 (4K)`.
    static func formatResolution(_ resolution: VideoResolution?) -> String {
        guard let resolution, resolution.width > 0, resolution.height > 0 else { return placeholder }
        if let label = resolution.qualityLabel {
            return "\(resolution.displayString) (\(label))"
        }
        return resolution.displayString
    }

    // MARK: Instance convenience (used by the overlay)

    var resolutionText: String { Self.formatResolution(resolution) }
    var indicatedBitrateText: String { Self.formatBitrate(indicatedBitrate) }
    var observedBitrateText: String { Self.formatBitrate(observedBitrate) }
    var bufferText: String { Self.formatBuffer(bufferedSecondsAhead) }
    var frameRateText: String { Self.formatFrameRate(frameRate) }
    var videoCodecText: String { videoCodec ?? Self.placeholder }
    var audioCodecText: String { audioCodec ?? Self.placeholder }
    var droppedFramesText: String { droppedVideoFrames.map(String.init) ?? Self.placeholder }
}
