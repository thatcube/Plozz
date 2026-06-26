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
        /// Server re-encodes the video and/or audio.
        case transcode
        case unknown

        public var displayName: String {
            switch self {
            case .directPlay: return "Direct Play"
            case .remux: return "Remux (server, lossless)"
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

        /// Compact label for inline use in the video line. `nil` for unknown so
        /// it can be omitted.
        public var shortName: String? {
            switch self {
            case .sdr: return "SDR"
            case .hlg: return "HLG"
            case .hdr10: return "HDR10"
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
    /// One-line subtitle description, e.g. `SubRip · English`.
    public var subtitleDescription: String?
    public var container: String?
    public var mode: PlaybackMode
    public var hdr: HDRFormat
    /// Human-readable name of the engine decoding the stream (e.g. `AVPlayer`,
    /// `VLCKit`, `mpv`). `nil` until the player wires it in.
    public var engineName: String?
    /// Seconds of media buffered ahead of the current playback position.
    public var bufferedSecondsAhead: Double?
    /// Cumulative dropped video frames reported by the access log.
    public var droppedVideoFrames: Int?
    /// Nominal frame rate of the video track, in frames/sec.
    public var frameRate: Double?
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
    /// Live `MPVVideoEngine` (libmpv) instances. See `liveViewModels`.
    public var liveMPVEngines: Int?

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
        subtitleDescription: String? = nil,
        container: String? = nil,
        mode: PlaybackMode = .unknown,
        hdr: HDRFormat = .unknown,
        engineName: String? = nil,
        bufferedSecondsAhead: Double? = nil,
        droppedVideoFrames: Int? = nil,
        frameRate: Double? = nil,
        deviceModel: String? = nil,
        deviceMemoryBytes: Int64? = nil,
        freeDiskBytes: Int64? = nil,
        totalDiskBytes: Int64? = nil,
        memoryFootprintBytes: Int64? = nil,
        thermalState: ThermalLevel? = nil,
        liveViewModels: Int? = nil,
        liveNativeEngines: Int? = nil,
        liveMPVEngines: Int? = nil
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
        self.subtitleDescription = subtitleDescription
        self.container = container
        self.mode = mode
        self.hdr = hdr
        self.engineName = engineName
        self.bufferedSecondsAhead = bufferedSecondsAhead
        self.droppedVideoFrames = droppedVideoFrames
        self.frameRate = frameRate
        self.deviceModel = deviceModel
        self.deviceMemoryBytes = deviceMemoryBytes
        self.freeDiskBytes = freeDiskBytes
        self.totalDiskBytes = totalDiskBytes
        self.memoryFootprintBytes = memoryFootprintBytes
        self.thermalState = thermalState
        self.liveViewModels = liveViewModels
        self.liveNativeEngines = liveNativeEngines
        self.liveMPVEngines = liveMPVEngines
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
    static func friendlyAudioName(codec: String?, profile: String?) -> String? {
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
    var indicatedBitrateText: String { Self.formatBitrate(indicatedBitrate) }
    var observedBitrateText: String { Self.formatBitrate(observedBitrate) }
    var bufferText: String { Self.formatBuffer(bufferedSecondsAhead) }
    var frameRateText: String { Self.formatFrameRate(frameRate) }
    var videoCodecText: String { videoCodec ?? Self.placeholder }
    var audioCodecText: String { audioCodec ?? Self.placeholder }
    var droppedFramesText: String { droppedVideoFrames.map(String.init) ?? Self.placeholder }

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

    /// Live-instance line, e.g. `Players 1 · AVPlayer 0 · mpv 1`. Outside the
    /// player all three should read 0; during playback exactly one player session
    /// + one engine (the engine kind matching the file — AVPlayer or mpv). Values
    /// that climb and never fall as you leave/re-enter the player name a leak; a
    /// count that climbs then "corrects down" names over-construction (throwaway
    /// instances built on the render path). `Players` counts live
    /// `PlayerViewModel`s; `AVPlayer` counts `NativeVideoEngine`s; `mpv` counts
    /// `MPVVideoEngine`s.
    var liveInstancesText: String {
        guard liveViewModels != nil || liveNativeEngines != nil || liveMPVEngines != nil else {
            return Self.placeholder
        }
        return "Players \(liveViewModels ?? 0) · AVPlayer \(liveNativeEngines ?? 0) · mpv \(liveMPVEngines ?? 0)"
    }
}

// MARK: - Building from provider source facts (pure, unit-tested)

public extension PlaybackDiagnostics {
    /// Builds the authoritative baseline snapshot from a provider's source
    /// metadata. The platform sampler layers live values (observed bitrate,
    /// buffer, dropped frames) and device/disk info on top of this.
    static func base(from metadata: MediaSourceMetadata?, mode: PlaybackMode) -> PlaybackDiagnostics {
        var d = PlaybackDiagnostics(mode: mode)
        guard let metadata else { return d }

        d.container = metadata.container

        if let v = metadata.video {
            d.videoCodec = friendlyCodecName(v.codec)
            d.videoProfile = v.profile?.trimmingCharacters(in: .whitespaces)
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
        }

        if let s = metadata.subtitle {
            let parts = [friendlyCodecName(s.codec), languageDisplayName(s.language)]
                .compactMap { $0?.isEmpty == false ? $0 : nil }
            d.subtitleDescription = parts.isEmpty ? nil : parts.joined(separator: " · ")
        }

        return d
    }
}
