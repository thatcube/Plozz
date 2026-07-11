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
    /// How the **server** is delivering the stream. The distinction matters for
    /// quality and Dolby Vision: a `remux` repackages the original bitstream into
    /// a new container with **no re-encode** (lossless, preserves the DoVi RPU),
    /// while a `transcode` re-encodes the video (quality loss, heavy server CPU).
    public enum PlaybackMode: String, Sendable {
        /// Server sends the original file untouched (no container change).
        case directPlay
        /// Server repackages the original video/audio bitstream into a new
        /// container (e.g. MKV → fMP4 HLS) with no re-encode. Lossless.
        case remux
        /// Plozzigen engine — on-device FFmpeg demux → HLS-fMP4 → AVPlayer.
        /// Lossless local remux with DoVi, Atmos, and full-timeline seek.
        case plozzigen
        /// Server re-encodes the video and/or audio.
        case transcode
        case unknown

        public var displayName: String {
            switch self {
            case .directPlay: return "Direct Play"
            case .remux: return "Remux (server, lossless)"
            case .plozzigen: return "Direct Play (Plozzigen)"
            case .transcode: return "Transcode (server)"
            case .unknown: return "Unknown"
            }
        }
    }

    /// High-dynamic-range classification derived from codec + transfer function.
    public enum HDRFormat: String, Sendable {
        case sdr
        case hlg
        case hdr10
        case hdr10Plus
        case dolbyVision
        case unknown

        public var displayName: String {
            switch self {
            case .sdr: return "SDR"
            case .hlg: return "HDR (HLG)"
            case .hdr10: return "HDR10 (PQ)"
            case .hdr10Plus: return "HDR10+"
            case .dolbyVision: return "Dolby Vision"
            case .unknown: return "Unknown"
            }
        }

        /// Compact label for inline use in the video line. `nil` for unknown so
        /// it can be omitted.
        public var shortName: String? {
            switch self {
            case .sdr: return "SDR"
            case .hlg: return "HLG"
            case .hdr10: return "HDR10"
            case .hdr10Plus: return "HDR10+"
            case .dolbyVision: return "Dolby Vision"
            case .unknown: return nil
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

        /// Friendly quality label based on the resolution tier.
        ///
        /// Uses `effectiveResolutionLines` (the larger of the true height and the
        /// height a 16:9 frame of this width implies) so cinematic letterboxed
        /// content such as `1920×804` classifies by its real capture width
        /// (→ `1080p`) rather than its cropped height (which would read `720p`).
        public var qualityLabel: String? {
            guard let lines = PlaybackDiagnostics.effectiveResolutionLines(width: width, height: height) else {
                return nil
            }
            switch lines {
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

    /// Coarse mirror of `ProcessInfo.ThermalState`, kept Foundation-only and
    /// `Sendable` so the pure model and its tests don't depend on a live process.
    public enum ThermalLevel: Int, Equatable, Sendable, CaseIterable {
        case nominal
        case fair
        case serious
        case critical

        public var displayName: String {
            switch self {
            case .nominal: return "Nominal"
            case .fair: return "Fair"
            case .serious: return "Serious (throttling)"
            case .critical: return "Critical (throttling)"
            }
        }
    }

    public var resolution: VideoResolution?
    /// Bitrate the playlist *declares* for the current variant, in bits/sec.
    public var indicatedBitrate: Double?
    /// Bitrate actually *observed* over the network, in bits/sec.
    public var observedBitrate: Double?
    public var videoCodec: String?
    /// Video codec profile, e.g. `Main 10`.
    public var videoProfile: String?
    /// Source-declared video bitrate, in bits/sec.
    public var videoBitrate: Double?
    public var audioCodec: String?
    /// Audio codec profile / spatial format, e.g. `Dolby Atmos`.
    public var audioProfile: String?
    public var audioChannels: Int?
    /// Channel layout label, e.g. `5.1`.
    public var audioChannelLayout: String?
    /// Audio sample rate, in Hz.
    public var audioSampleRate: Int?
    /// Source-declared audio bitrate, in bits/sec.
    public var audioBitrate: Double?
    /// Expected output handling for the current audio route, e.g. Atmos passthrough
    /// vs. a route that may collapse to channel-bed audio.
    public var audioOutputDescription: String?
    /// One-line subtitle description, e.g. `SubRip · English`.
    public var subtitleDescription: String?
    public var container: String?
    public var mode: PlaybackMode
    public var hdr: HDRFormat
    /// Human-readable name of the engine decoding the stream (e.g. `AVPlayer`,
    /// `Plozzigen`). `nil` until the player wires it in.
    public var engineName: String?
    /// Seconds of media buffered ahead of the current playback position.
    public var bufferedSecondsAhead: Double?
    /// Cumulative dropped video frames reported by the access log.
    public var droppedVideoFrames: Int?
    /// Nominal frame rate of the video track, in frames/sec.
    public var frameRate: Double?
    /// Live frame rate the engine is actually presenting, in frames/sec. From a
    /// non-AVFoundation engine's telemetry; a value far below `frameRate` while
    /// dropped frames climb is the on-device decode/compositor-stutter signal.
    public var observedFps: Double?
    /// Friendly device model, e.g. `Apple TV 4K (3rd gen)`.
    public var deviceModel: String?
    /// Physical memory, in bytes.
    public var deviceMemoryBytes: Int64?
    /// Free space on the volume, in bytes.
    public var freeDiskBytes: Int64?
    /// Total space on the volume, in bytes.
    public var totalDiskBytes: Int64?
    /// Resident memory of the app process (`phys_footprint`), in bytes. Climbs
    /// across playbacks when a leak accumulates; flat under thermal throttling.
    public var memoryFootprintBytes: Int64?
    /// Coarse system thermal pressure. Rises toward `.critical` when the SoC is
    /// throttling — the alternative explanation to a leak for "worse over time".
    public var thermalState: ThermalLevel?
    /// Live `PlayerViewModel` instances. Should be 0 outside the player and 1
    /// during playback; a value that climbs and never falls is a leak.
    public var liveViewModels: Int?
    /// Live `NativeVideoEngine` (AVPlayer) instances. See `liveViewModels`.
    public var liveNativeEngines: Int?
    /// Which backend resolved this playback (Plex / Jellyfin), shown in the
    /// "Source Provider" row.
    public var sourceProvider: ProviderKind?
    /// Friendly server name shown in the overlay header (e.g. "Allie's Jellyfin").
    public var serverName: String?
    /// Basename of the actual selected source file. This is provider-supplied
    /// rather than derived from the playback URL, which may be a transcode API.
    public var sourceFileName: String?
    /// Container codec FourCC tag, e.g. `hvc1` / `hev1` / `dvh1`. The hvc1-vs-hev1
    /// distinction is make-or-break for AVPlayer (hev1 plays audio with a black
    /// screen), so it's surfaced explicitly.
    public var videoCodecTag: String?
    /// Bits per luma sample, e.g. `10`.
    public var videoBitDepth: Int?
    /// Explicit Dolby Vision profile (5 / 7 / 8), when known or inferable.
    public var dolbyVisionProfile: Int?
    /// Raw color transfer characteristics token, e.g. `smpte2084`, `arib-std-b67`.
    public var colorTransfer: String?
    /// Specific HDR range token, e.g. `DOVI`, `HDR10`, `DOVIWithHDR10`.
    public var videoRangeType: String?
    /// Compact, token-stripped summary of the URL AVPlayer is actually playing,
    /// e.g. `App-local 127.0.0.1:52344 · HLS` for an app-owned local remux vs.
    /// `media.server · HLS` for a server stream. The query string (auth tokens) is
    /// never included.
    public var streamTransport: String?
    /// Total media duration in seconds, when the player knows it.
    public var durationSeconds: Double?
    /// Current playhead position in seconds.
    public var positionSeconds: Double?
    /// Start of the player's currently-seekable window in seconds. For server HLS
    /// this is often a small throttled window; for a true app-owned remux it should
    /// be ~0 (the whole timeline is seekable).
    public var seekableStartSeconds: Double?
    /// End of the player's currently-seekable window in seconds. When this trails
    /// far behind `durationSeconds`, seek-ahead will fail — the core bug this work
    /// exists to diagnose.
    public var seekableEndSeconds: Double?
    /// Live player state, e.g. `Ready · Playing`, `Loading`, or `Failed: …`.
    public var playbackState: String?

    public init(
        resolution: VideoResolution? = nil,
        indicatedBitrate: Double? = nil,
        observedBitrate: Double? = nil,
        videoCodec: String? = nil,
        videoProfile: String? = nil,
        videoBitrate: Double? = nil,
        audioCodec: String? = nil,
        audioProfile: String? = nil,
        audioChannels: Int? = nil,
        audioChannelLayout: String? = nil,
        audioSampleRate: Int? = nil,
        audioBitrate: Double? = nil,
        audioOutputDescription: String? = nil,
        subtitleDescription: String? = nil,
        container: String? = nil,
        mode: PlaybackMode = .unknown,
        hdr: HDRFormat = .unknown,
        engineName: String? = nil,
        bufferedSecondsAhead: Double? = nil,
        droppedVideoFrames: Int? = nil,
        frameRate: Double? = nil,
        observedFps: Double? = nil,
        deviceModel: String? = nil,
        deviceMemoryBytes: Int64? = nil,
        freeDiskBytes: Int64? = nil,
        totalDiskBytes: Int64? = nil,
        memoryFootprintBytes: Int64? = nil,
        thermalState: ThermalLevel? = nil,
        liveViewModels: Int? = nil,
        liveNativeEngines: Int? = nil,
        sourceProvider: ProviderKind? = nil,
        sourceFileName: String? = nil,
        videoCodecTag: String? = nil,
        videoBitDepth: Int? = nil,
        dolbyVisionProfile: Int? = nil,
        colorTransfer: String? = nil,
        videoRangeType: String? = nil,
        streamTransport: String? = nil,
        durationSeconds: Double? = nil,
        positionSeconds: Double? = nil,
        seekableStartSeconds: Double? = nil,
        seekableEndSeconds: Double? = nil,
        playbackState: String? = nil
    ) {
        self.resolution = resolution
        self.indicatedBitrate = indicatedBitrate
        self.observedBitrate = observedBitrate
        self.videoCodec = videoCodec
        self.videoProfile = videoProfile
        self.videoBitrate = videoBitrate
        self.audioCodec = audioCodec
        self.audioProfile = audioProfile
        self.audioChannels = audioChannels
        self.audioChannelLayout = audioChannelLayout
        self.audioSampleRate = audioSampleRate
        self.audioBitrate = audioBitrate
        self.audioOutputDescription = audioOutputDescription
        self.subtitleDescription = subtitleDescription
        self.container = container
        self.mode = mode
        self.hdr = hdr
        self.engineName = engineName
        self.bufferedSecondsAhead = bufferedSecondsAhead
        self.droppedVideoFrames = droppedVideoFrames
        self.frameRate = frameRate
        self.observedFps = observedFps
        self.deviceModel = deviceModel
        self.deviceMemoryBytes = deviceMemoryBytes
        self.freeDiskBytes = freeDiskBytes
        self.totalDiskBytes = totalDiskBytes
        self.memoryFootprintBytes = memoryFootprintBytes
        self.thermalState = thermalState
        self.liveViewModels = liveViewModels
        self.liveNativeEngines = liveNativeEngines
        self.sourceProvider = sourceProvider
        self.sourceFileName = sourceFileName
        self.videoCodecTag = videoCodecTag
        self.videoBitDepth = videoBitDepth
        self.dolbyVisionProfile = dolbyVisionProfile
        self.colorTransfer = colorTransfer
        self.videoRangeType = videoRangeType
        self.streamTransport = streamTransport
        self.durationSeconds = durationSeconds
        self.positionSeconds = positionSeconds
        self.seekableStartSeconds = seekableStartSeconds
        self.seekableEndSeconds = seekableEndSeconds
        self.playbackState = playbackState
    }
}

// MARK: - Classification (pure, unit-tested)

public extension PlaybackDiagnostics {
    /// The effective vertical resolution (in scan lines) used to classify a video
    /// into a quality tier: the larger of the true pixel height and the height a
    /// 16:9 frame of this width would have.
    ///
    /// Cinematic content is letterboxed — a 2.40:1 movie mastered at full HD width
    /// is `1920×804`, so keying off the raw height (804) misclassifies it as
    /// `720p`. Deriving lines from the (stable) width instead yields `1080p`,
    /// matching how Plex/Jellyfin label the same file. Returns `nil` when neither
    /// dimension is known.
    static func effectiveResolutionLines(width: Int?, height: Int?) -> Int? {
        let heightLines = (height ?? 0) > 0 ? (height ?? 0) : 0
        let widthLines = (width ?? 0) > 0 ? ((width ?? 0) * 9) / 16 : 0
        let lines = max(heightLines, widthLines)
        return lines > 0 ? lines : nil
    }

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

    /// Classifies HDR from the provider's own range tokens (Jellyfin
    /// `VideoRange`/`VideoRangeType`, Plex `colorTrc`/Dolby-Vision flags). This
    /// is preferred over the AVFoundation path when the stream is transcoded,
    /// because the source facts survive even though the played asset is SDR.
    ///
    /// - Parameters:
    ///   - videoRange: coarse token, e.g. `HDR`, `SDR`.
    ///   - videoRangeType: specific token, e.g. `DOVI`, `HDR10`, `HLG`,
    ///     `HDR10Plus`.
    ///   - colorTransfer: transfer characteristics, e.g. `smpte2084`,
    ///     `arib-std-b67`.
    ///   - isDolbyVision: explicit Dolby-Vision flag if the provider gives one.
    static func classifyHDR(
        videoRange: String?,
        videoRangeType: String?,
        colorTransfer: String? = nil,
        isDolbyVision: Bool = false
    ) -> HDRFormat {
        let type = (videoRangeType ?? "").uppercased()
        let range = (videoRange ?? "").uppercased()
        let transfer = (colorTransfer ?? "").uppercased()

        if isDolbyVision || type.contains("DOVI") || type.contains("DOLBY") || range.contains("DOVI") {
            return .dolbyVision
        }
        if type.contains("HDR10PLUS") || type.contains("HDR10+")
            || range.contains("HDR10PLUS") || range.contains("HDR10+") {
            return .hdr10Plus
        }
        if type.contains("HLG") || transfer.contains("ARIB") || transfer.contains("B67") || transfer.contains("HLG") {
            return .hlg
        }
        if type.contains("HDR") || transfer.contains("2084") || transfer.contains("PQ") {
            return .hdr10
        }
        if range.contains("HDR") {
            return .hdr10
        }
        if range.isEmpty && type.isEmpty && transfer.isEmpty {
            return .unknown
        }
        return .sdr
    }

    /// Friendly container name for the diagnostics overlay, e.g. `mkv` →
    /// `Matroska`, `mp4` → `MP4`.
    static func friendlyContainerName(_ container: String?) -> String? {
        guard let raw = container?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "mkv": return "Matroska"
        case "webm": return "WebM"
        case "mp4", "m4v": return "MP4"
        case "mov", "qt": return "QuickTime"
        case "ts", "mpegts", "m2ts", "mts": return "MPEG-TS"
        case "m3u8", "hls": return "HLS"
        case "avi": return "AVI"
        case "wmv", "asf": return "Windows Media"
        case "flv": return "Flash Video"
        case "ogv", "ogg": return "Ogg"
        case "3gp": return "3GP"
        default: return raw.uppercased()
        }
    }

    /// Container label for the overlay, pairing the friendly name with the raw
    /// extension when they differ, e.g. `Matroska (MKV)`. When the friendly name
    /// already is the bare token (e.g. `MP4`), no parenthetical is added.
    static func containerLabel(_ container: String?) -> String? {
        guard let raw = container?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let friendly = friendlyContainerName(raw) ?? raw.uppercased()
        let token = raw.uppercased()
        if friendly.uppercased() == token { return friendly }
        return "\(friendly) (\(token))"
    }

    /// Best display name for an audio track, preferring a descriptive spatial
    /// profile (Dolby Atmos, DTS:X) over the bare codec name.
    static public func friendlyAudioName(codec: String?, profile: String?) -> String? {
        if let profile = profile?.trimmingCharacters(in: .whitespaces), !profile.isEmpty {
            let lower = profile.lowercased()
            if lower.contains("atmos") { return "Dolby Atmos" }
            if lower.contains("dts:x") || lower.contains("dts-x") || lower.contains("dts x") { return "DTS:X" }
            if lower.contains("truehd") { return "Dolby TrueHD" }
            if lower.contains("dts-hd ma") || lower.contains("dts-hd master") { return "DTS-HD MA" }
            if lower.contains("dts-hd") { return "DTS-HD" }
        }
        return friendlyCodecName(codec)
    }

    /// Human-readable expectation for what leaves the Apple TV on the active
    /// route. This is intentionally explicit for Atmos so diagnostics can show the
    /// difference between "Atmos bitstream is present" and "the current route is
    /// likely only receiving the 5.1 channel bed".
    static func audioOutputDescription(
        codec: String?,
        profile: String?,
        channels: Int?,
        capabilities: MediaCapabilities,
        mode: PlaybackMode = .unknown
    ) -> String? {
        let token = (codec ?? "").lowercased().replacingOccurrences(of: "_", with: "-")
        let profileText = (profile ?? "").lowercased()
        let isAtmos = profileText.contains("atmos")
        // Plozzigen (AetherEngine) bridges codecs AVPlayer can't decode to a
        // lossless FLAC (>6ch) or EAC3 5.1 stream on-device, so DTS/TrueHD play
        // without passthrough. Reflect that instead of the AVPlayer caveat.
        if mode == .plozzigen {
            switch token {
            case "dts", "dca", "dts-hd", "dtshd", "dca-ma", "truehd", "mlp":
                let bridged = (channels ?? 0) > 6 ? "lossless FLAC" : "EAC3 5.1"
                return "Bridged on-device (\(bridged))"
            default:
                break
            }
        }
        switch token {
        case "eac3", "ec3", "ec-3", "e-ac-3":
            if isAtmos {
                return capabilities.supportsAtmos
                    ? "E-AC-3 JOC Atmos passthrough expected"
                    : "Atmos present; route may fall back to \(channelDescription(layout: nil, channels: channels) ?? "channel-bed audio")"
            }
            return "E-AC-3 passthrough"
        case "ac3", "ac-3":
            return "AC-3 passthrough"
        case "truehd", "mlp":
            return isAtmos ? "TrueHD Atmos is not AVPlayer-compatible" : "TrueHD is not AVPlayer-compatible"
        case "dts", "dca":
            return capabilities.supportsDTSPassthrough ? "DTS passthrough" : "DTS requires Plozzigen decode or a passthrough route"
        case "dts-hd", "dtshd", "dca-ma":
            return capabilities.supportsDTSPassthrough ? "DTS-HD passthrough" : "DTS-HD requires Plozzigen decode or a passthrough route"
        case "aac", "mp4a", "alac", "mp3", "flac", "pcm", "lpcm":
            return "Decoded by Apple TV"
        default:
            return token.isEmpty ? nil : nil
        }
    }

    /// Friendly channel layout from an explicit layout label and/or a raw
    /// channel count, e.g. `5.1`, `7.1`, `Stereo`.
    static func channelDescription(layout: String?, channels: Int?) -> String? {
        if let layout = layout?.trimmingCharacters(in: .whitespaces), !layout.isEmpty {
            // Strip Plex's "(side)"/"(back)" qualifiers; keep the "5.1" core.
            let core = layout.split(separator: "(").first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? layout
            switch core.lowercased() {
            case "mono": return "Mono"
            case "stereo": return "Stereo"
            default: return core
            }
        }
        guard let channels, channels > 0 else { return nil }
        switch channels {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 7: return "6.1"
        case 8: return "7.1"
        default: return "\(channels)ch"
        }
    }

    /// Human-readable codec name for common FourCC tags, falling back to the
    /// uppercased raw tag for anything unrecognised.
    static func friendlyCodecName(_ fourCC: String?) -> String? {
        guard let raw = fourCC?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "avc1", "h264", "x264": return "H.264"
        case "hvc1", "hev1", "h265", "hevc", "x265": return "HEVC"
        case "dvh1", "dvhe", "dvav", "dvav1": return "Dolby Vision"
        case "av01", "dav1", "av1": return "AV1"
        case "vp09", "vp9": return "VP9"
        case "vp08", "vp8": return "VP8"
        case "vc1", "vc-1", "wvc1": return "VC-1"
        case "mpeg2video", "mp2v", "mpeg2": return "MPEG-2"
        case "mp4v", "mpeg4", "msmpeg4", "msmpeg4v3", "divx", "xvid": return "MPEG-4"
        case "mp4a", "aac", "aac ", "aac_latm": return "AAC"
        case "ac-3", "ac3": return "Dolby Digital"
        case "ec-3", "eac3", "ec3": return "Dolby Digital+"
        case "truehd", "mlp": return "Dolby TrueHD"
        case "dtsc", "dts", "dtsh", "dca": return "DTS"
        case "alac": return "ALAC"
        case "opus": return "Opus"
        case "flac": return "FLAC"
        case "vorbis": return "Vorbis"
        case "mp3", ".mp3", "mp3float": return "MP3"
        case "mp2", "mp2float": return "MP2"
        case "pcm", "lpcm", "pcm_s16le", "pcm_s24le", "pcm_bluray": return "PCM"
        case "subrip", "srt": return "SubRip"
        case "ass", "ssa": return "ASS/SSA"
        case "pgssub", "pgs", "hdmv_pgs_subtitle": return "PGS"
        case "dvdsub", "dvd_subtitle": return "DVD Subtitle"
        case "dvbsub", "dvb_subtitle": return "DVB Subtitle"
        case "vtt", "webvtt": return "WebVTT"
        case "mov_text", "tx3g": return "Timed Text"
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

    /// Formats a seconds value as a wall-clock timecode, e.g. `1:58:24` or `12:34`.
    static func formatTimecode(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return placeholder }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// Formats the player's seekable window against the full duration — the single
    /// most diagnostic line for the seek bug. A true app-owned remux should report
    /// the **whole** timeline as seekable (`… · full timeline`); a throttled server
    /// HLS stream reports only a small trailing window (`… · server window 21s`),
    /// which is exactly why seek-ahead 404s.
    static func formatSeekWindow(start: Double?, end: Double?, duration: Double?) -> String {
        guard let start, let end, start.isFinite, end.isFinite, end >= start else {
            return placeholder
        }
        let window = "\(formatTimecode(start))–\(formatTimecode(end))"
        guard let duration, duration.isFinite, duration > 0 else { return window }
        let coversWholeTimeline = end >= duration - 5 && start <= 5
        let tag = coversWholeTimeline
            ? "full timeline"
            : String(format: "server window %.0fs", max(0, end - start))
        return "\(window) of \(formatTimecode(duration)) · \(tag)"
    }

    /// Human-readable Dolby Vision profile, calling out the make-or-break facts:
    /// Profile 5 has **no** HDR10 fallback (a wrong sample entry = no picture),
    /// Profile 8 is HDR10-compatible, Profile 7 is dual-layer (stays on Plozzigen).
    static func dolbyVisionDescription(profile: Int?) -> String? {
        guard let profile else { return nil }
        switch profile {
        case 5: return "Profile 5 (single-layer · no HDR10 fallback)"
        case 7: return "Profile 7 (dual-layer · hybrid engine)"
        case 8: return "Profile 8 (single-layer · HDR10-compatible)"
        default: return "Profile \(profile)"
        }
    }

    /// Friendly transfer-function label from a raw token, e.g. `smpte2084` → `PQ`.
    static func transferFunctionLabel(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let value = raw.lowercased()
        if value.contains("2084") || value == "pq" || value.contains("st2084") {
            return "PQ (ST 2084)"
        }
        if value.contains("b67") || value.contains("hlg") || value.contains("arib") {
            return "HLG"
        }
        if value.contains("2020") { return "BT.2020" }
        if value.contains("709") { return "BT.709" }
        if value.contains("601") { return "BT.601" }
        return raw
    }

    /// Composite color line, e.g. `10-bit · PQ (ST 2084) · DOVI`.
    static func colorDescription(bitDepth: Int?, transfer: String?, rangeType: String?) -> String? {
        let depth = bitDepth.flatMap { $0 > 0 ? "\($0)-bit" : nil }
        let trc = transferFunctionLabel(transfer)
        let range: String? = {
            guard let raw = rangeType?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
            return raw.uppercased()
        }()
        let parts = [depth, trc, range].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A compact, **token-stripped** summary of the URL AVPlayer is playing. Local
    /// (app-owned) hosts are flagged as `App-local …`; the query string (which
    /// carries auth tokens) is always dropped so the overlay never leaks secrets.
    /// The transport/container is appended when recognisable from the URL path
    /// (`.m3u8` ⇒ `HLS`, progressive `.mp4`/`.m4v`/`.mov` ⇒ `fMP4/MP4`), which is
    /// far more useful on the overlay than the bare scheme; when the container
    /// can't be inferred a remote host falls back to its scheme.
    static func streamTransportSummary(url: URL?) -> String? {
        guard let url else { return nil }
        let host = (url.host ?? "").lowercased()
        let scheme = (url.scheme ?? "").uppercased()
        let container = streamContainerLabel(for: url)
        let isLocal = host == "127.0.0.1" || host == "localhost" || host == "::1"
        if isLocal {
            let port = url.port.map { ":\($0)" } ?? ""
            let base = "App-local \(host)\(port)"
            return container.map { "\(base) · \($0)" } ?? base
        }
        if host.isEmpty {
            return container ?? (scheme.isEmpty ? nil : scheme)
        }
        return "\(host) · \(container ?? scheme)"
    }

    /// Best-effort delivery/container label from a stream URL's path extension.
    /// `nil` when the extension isn't a container we recognise.
    static func streamContainerLabel(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "m3u8": return "HLS"
        case "mpd": return "DASH"
        case "mp4", "m4v", "mov": return "fMP4/MP4"
        case "mkv": return "MKV"
        case "ts": return "MPEG-TS"
        default: return nil
        }
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

    /// Formats an audio sample rate in Hz as kHz, e.g. `48000` → `48 kHz`,
    /// `44100` → `44.1 kHz`.
    static func formatSampleRate(_ hz: Int?) -> String? {
        guard let hz, hz > 0 else { return nil }
        let khz = Double(hz) / 1000
        if khz == khz.rounded() {
            return String(format: "%.0f kHz", khz)
        }
        return String(format: "%.1f kHz", khz)
    }

    /// Formats a byte count in binary GB/MB for the device/disk rows, e.g.
    /// `4_165_632_000` → `3.88 GB`.
    static func formatBytes(_ bytes: Int64?) -> String? {
        guard let bytes, bytes > 0 else { return nil }
        let gib = Double(bytes) / 1_073_741_824
        if gib >= 1 {
            return String(format: "%.2f GB", gib)
        }
        let mib = Double(bytes) / 1_048_576
        return String(format: "%.0f MB", mib)
    }

    /// A coarse health label for the playback buffer, mirroring Infuse's "Buffer
    /// status" row.
    static func bufferStatus(seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return placeholder }
        switch seconds {
        case ..<2: return "Buffering"
        case 2..<8: return "Low"
        default: return "Healthy"
        }
    }

    /// Friendly language name from an ISO code, e.g. `en` → `English`,
    /// `fra` → `French`. Returns the original token when it can't be resolved.
    static func languageDisplayName(_ code: String?) -> String? {
        guard let raw = code?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let identifier = String(raw.prefix(while: { $0 != "-" && $0 != "_" }))
        if let name = Locale(identifier: "en_US").localizedString(forLanguageCode: identifier),
           !name.isEmpty, name.lowercased() != identifier.lowercased() {
            return name
        }
        return raw
    }

    /// Joins non-empty parts with a middot separator, returning a placeholder
    /// when nothing is present.
    static func joinParts(_ parts: [String?]) -> String {
        let kept = parts.compactMap { part -> String? in
            guard let part = part?.trimmingCharacters(in: .whitespaces), !part.isEmpty else { return nil }
            return part
        }
        return kept.isEmpty ? placeholder : kept.joined(separator: " · ")
    }

    // MARK: Instance convenience (used by the overlay)

    var resolutionText: String { Self.formatResolution(resolution) }
    /// e.g. `3840×2160 (4K)` or `1920×1080 (1080p)`.
    var resolutionWithQualityText: String {
        guard let resolution, resolution.width > 0, resolution.height > 0 else { return Self.placeholder }
        if let label = resolution.qualityLabel {
            return "\(resolution.displayString) (\(label))"
        }
        return resolution.displayString
    }
    var indicatedBitrateText: String { Self.formatBitrate(indicatedBitrate) }
    var observedBitrateText: String { Self.formatBitrate(observedBitrate) }
    var bufferText: String { Self.formatBuffer(bufferedSecondsAhead) }
    var frameRateText: String { Self.formatFrameRate(frameRate) }
    var hdrText: String { hdr == .unknown ? Self.placeholder : hdr.displayName }
    var videoCodecText: String { videoCodec ?? Self.placeholder }
    var audioCodecText: String { audioCodec ?? Self.placeholder }
    var droppedFramesText: String { droppedVideoFrames.map(String.init) ?? Self.placeholder }
    var observedFpsText: String { observedFps.map { String(format: "%.0f fps", $0) } ?? Self.placeholder }

    /// Friendly container name, e.g. `Matroska (MKV)`.
    var containerText: String { Self.containerLabel(container) ?? Self.placeholder }

    /// Composite video line, e.g. `HEVC · Dolby Vision · 1920×1080 · 4.8 Mbps · 24.00 fps`.
    var videoLineText: String {
        let resText: String? = {
            guard let resolution, resolution.width > 0, resolution.height > 0 else { return nil }
            return resolution.displayString
        }()
        return Self.joinParts([
            videoCodec,
            hdr.shortName,
            resText,
            videoBitrate.flatMap { $0 > 0 ? Self.formatBitrate($0) : nil },
            frameRate.flatMap { $0 > 0 ? Self.formatFrameRate($0) : nil }
        ])
    }

    /// Composite audio line, e.g. `Dolby Atmos · 48 kHz · 5.1 · 768 Kbps`.
    var audioLineText: String {
        Self.joinParts([
            audioCodec,
            Self.formatSampleRate(audioSampleRate),
            Self.channelDescription(layout: audioChannelLayout, channels: audioChannels),
            audioBitrate.flatMap { $0 > 0 ? Self.formatBitrate($0) : nil }
        ])
    }

    var audioOutputText: String {
        audioOutputDescription ?? Self.placeholder
    }

    var audioChannelsText: String {
        Self.channelDescription(layout: audioChannelLayout, channels: audioChannels) ?? Self.placeholder
    }

    var audioSampleRateText: String {
        Self.formatSampleRate(audioSampleRate) ?? Self.placeholder
    }

    var audioBitrateText: String {
        guard let br = audioBitrate, br > 0 else { return Self.placeholder }
        return Self.formatBitrate(br)
    }

    /// Backend that resolved the stream, e.g. `Plex` / `Jellyfin`.
    var sourceProviderText: String { sourceProvider?.displayName ?? Self.placeholder }

    /// Container codec tag, annotating the AVPlayer-hostile `hev1` case.
    var videoCodecTagText: String {
        guard let tag = videoCodecTag?.trimmingCharacters(in: .whitespaces), !tag.isEmpty else {
            return Self.placeholder
        }
        if tag.lowercased() == "hev1" {
            return "\(tag) (AVPlayer needs hvc1 — black-screen risk)"
        }
        return tag
    }

    /// Composite color line, e.g. `10-bit · PQ (ST 2084) · DOVI`.
    var colorText: String {
        Self.colorDescription(bitDepth: videoBitDepth, transfer: colorTransfer, rangeType: videoRangeType)
            ?? Self.placeholder
    }

    /// Explicit Dolby Vision profile line.
    var dolbyVisionText: String {
        Self.dolbyVisionDescription(profile: dolbyVisionProfile) ?? Self.placeholder
    }

    /// Token-stripped transport summary of what AVPlayer is actually playing.
    var streamTransportText: String { streamTransport ?? Self.placeholder }

    /// Selected source filename, or a placeholder when the provider cannot expose
    /// one. Whitespace-only values are suppressed.
    var sourceFileNameText: String {
        guard let value = sourceFileName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return Self.placeholder }
        return value
    }

    /// Current position over duration, e.g. `12:34 / 1:58:24`.
    var positionText: String {
        guard positionSeconds != nil || durationSeconds != nil else { return Self.placeholder }
        return "\(Self.formatTimecode(positionSeconds)) / \(Self.formatTimecode(durationSeconds))"
    }

    /// Seekable window vs. duration — the key seek diagnostic.
    var seekWindowText: String {
        Self.formatSeekWindow(start: seekableStartSeconds, end: seekableEndSeconds, duration: durationSeconds)
    }

    /// Live player state, e.g. `Ready · Playing`.
    var playbackStateText: String { playbackState ?? Self.placeholder }

    /// Subtitle line, e.g. `SubRip · English`, or a placeholder when none.
    var subtitleText: String { subtitleDescription ?? Self.placeholder }

    /// Buffer health + seconds ahead, e.g. `Healthy · 72.6s ahead`.
    var bufferStatusText: String {
        let status = Self.bufferStatus(seconds: bufferedSecondsAhead)
        guard let seconds = bufferedSecondsAhead, seconds.isFinite, seconds >= 0 else { return status }
        return "\(status) · \(Self.formatBuffer(seconds)) ahead"
    }

    /// Device line, e.g. `Apple TV 4K · 3.88 GB`.
    var deviceText: String {
        Self.joinParts([deviceModel, Self.formatBytes(deviceMemoryBytes)])
    }

    /// Disk line, e.g. `90.26 GB free / 118.88 GB`.
    var diskText: String {
        guard let free = Self.formatBytes(freeDiskBytes) else { return Self.placeholder }
        if let total = Self.formatBytes(totalDiskBytes) {
            return "\(free) free / \(total)"
        }
        return "\(free) free"
    }

    /// Process memory line, e.g. `412.5 MB`. Watch it across playbacks: a steady
    /// climb that never falls back is the signature of a leak.
    var memoryText: String {
        Self.formatBytes(memoryFootprintBytes) ?? Self.placeholder
    }

    /// System thermal pressure, e.g. `Serious (throttling)`.
    var thermalText: String {
        thermalState?.displayName ?? Self.placeholder
    }

    /// Live-instance line, e.g. `Players 1 · AVPlayer 1`. Outside the player both
    /// should read 0; during playback exactly one player session + one AVPlayer
    /// engine. Values that climb and never fall as you leave/re-enter the player
    /// name a leak; a count that climbs then "corrects down" names
    /// over-construction (throwaway instances built on the render path).
    /// `Players` counts live `PlayerViewModel`s; `AVPlayer` counts
    /// `NativeVideoEngine`s.
    var liveInstancesText: String {
        guard liveViewModels != nil || liveNativeEngines != nil else {
            return Self.placeholder
        }
        return "Players \(liveViewModels ?? 0) · AVPlayer \(liveNativeEngines ?? 0)"
    }
}

// MARK: - Building from provider source facts (pure, unit-tested)

public extension PlaybackDiagnostics {
    /// Builds the authoritative baseline snapshot from a provider's source
    /// metadata. The platform sampler layers live values (observed bitrate,
    /// buffer, dropped frames) and device/disk info on top of this.
    static func base(
        from metadata: MediaSourceMetadata?,
        mode: PlaybackMode,
        capabilities: MediaCapabilities = .default,
        sourceProvider: ProviderKind? = nil,
        serverName: String? = nil
    ) -> PlaybackDiagnostics {
        var d = PlaybackDiagnostics(mode: mode)
        d.sourceProvider = sourceProvider
        d.serverName = serverName
        guard let metadata else { return d }

        d.container = metadata.container

        if let v = metadata.video {
            d.videoCodec = friendlyCodecName(v.codec)
            d.videoProfile = v.profile?.trimmingCharacters(in: .whitespaces)
            d.videoCodecTag = v.codecTag?.trimmingCharacters(in: .whitespaces)
            d.videoBitDepth = v.bitDepth
            d.colorTransfer = v.colorTransfer
            d.videoRangeType = v.videoRangeType
            // Explicit profile wins; otherwise infer single-layer profile from the
            // provider's range token (mirrors LocalRemuxSourceDescriptor).
            if let explicit = v.dolbyVisionProfile {
                d.dolbyVisionProfile = explicit
            } else {
                switch (v.videoRangeType ?? "").uppercased() {
                case "DOVIWITHHDR10", "DOVIWITHHLG", "DOVIWITHSDR": d.dolbyVisionProfile = 8
                case "DOVI": d.dolbyVisionProfile = 5
                default: break
                }
            }
            if let w = v.width, let h = v.height, w > 0, h > 0 {
                d.resolution = VideoResolution(width: w, height: h)
            }
            if let bitrate = v.bitrate, bitrate > 0 { d.videoBitrate = Double(bitrate) }
            if let fps = v.frameRate, fps > 0 { d.frameRate = fps }
            d.hdr = classifyHDR(
                videoRange: v.videoRange,
                videoRangeType: v.videoRangeType,
                colorTransfer: v.colorTransfer
            )
        }

        if let a = metadata.audio {
            d.audioCodec = friendlyAudioName(codec: a.codec, profile: a.profile)
            d.audioProfile = a.profile?.trimmingCharacters(in: .whitespaces)
            d.audioChannels = a.channels
            d.audioChannelLayout = a.channelLayout
            if let rate = a.sampleRate, rate > 0 { d.audioSampleRate = rate }
            if let bitrate = a.bitrate, bitrate > 0 { d.audioBitrate = Double(bitrate) }
            d.audioOutputDescription = audioOutputDescription(
                codec: a.codec,
                profile: a.profile,
                channels: a.channels,
                capabilities: capabilities,
                mode: mode
            )
        }

        if let s = metadata.subtitle {
            let parts = [friendlyCodecName(s.codec), languageDisplayName(s.language)]
                .compactMap { $0?.isEmpty == false ? $0 : nil }
            d.subtitleDescription = parts.isEmpty ? nil : parts.joined(separator: " · ")
        }

        return d
    }
}
