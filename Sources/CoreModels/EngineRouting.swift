import Foundation

// MARK: - PlaybackEngineKind

/// Which playback engine should handle a resolved stream.
///
/// `CoreModels` only names the *decision*; mapping a kind onto a concrete engine
/// (the `AVPlayer`-backed native engine vs. the Plozzigen on-device decode engine)
/// happens up in `FeaturePlayback`, which alone knows the engine types. Keeping the
/// decision here means it stays pure, dependency-free, and unit-testable on Linux/CI.
public enum PlaybackEngineKind: String, Sendable, Equatable, CaseIterable {
    /// `NativeVideoEngine` (AVPlayer). The default, power-efficient path; the only
    /// engine that renders Dolby Vision correctly on tvOS.
    case native
    /// Abstract "needs on-device decode" signal for AVPlayer-incompatible sources
    /// (MKV, DTS / DTS-HD / TrueHD, odd codecs). Resolved to the Plozzigen engine
    /// in `FeaturePlayback` (the former backing engine is retired); kept as a distinct
    /// routing value so the pure router stays engine-agnostic and its tests hold.
    case hybrid
    /// `AetherVideoEngine`. FFmpeg demux → HLS-fMP4 copy-remux → localhost →
    /// AVPlayer. Handles DoVi + Atmos MKV with full seek, bounded memory, and
    /// native video rendering. Replaces the local-remux + native pipeline for
    /// eligible sources.
    case plozzigen
}

// MARK: - EngineRouter

/// The pure brain that picks which engine plays a resolved source.
///
/// ## Policy (CONSERVATIVE)
/// Preserve the rock-solid, power-efficient `AVPlayer` path for everything it
/// handles well; use the on-device decode engine (Plozzigen) **only** for what
/// AVPlayer can't direct-play without a server transcode:
///
///   * **Dolby Vision in an Apple container** → ``PlaybackEngineKind/native``.
///     AVPlayer renders DoVi with full dynamic metadata on tvOS. But AVPlayer
///     cannot demux Matroska and a server transcode of DoVi is unreliable, so
///     **DoVi in an MKV** goes to the on-device engine (which decodes the HEVC
///     base layer), matching Infuse.
///   * **On-device-only containers (Matroska/WebM/transport-stream variants),
///     AV1, DTS/DTS-HD/TrueHD audio, interlaced video, or an
///     AVPlayer-incompatible video codec** → ``PlaybackEngineKind/hybrid``
///     (decode on-device, no transcode). Plain HDR10/HLG in an *Apple* container
///     stays native — AVPlayer renders it on the efficient hardware path.
///   * **Ambiguous/unknown, already transcoding, or no on-device engine available**
///     → ``PlaybackEngineKind/native`` (it carries the server-transcode safety net).
///
/// ## Lockstep with the capability layer
/// The router and the provider capability profiles must advertise the *same* set
/// of formats as direct-play: never advertise something the router can't route to
/// a working engine. The capability expansion (gated by the same on-device-decode
/// flag that sets `hybridAvailable` here) advertises raw MKV for every
/// display-supported range — SDR, HDR10/HLG, **and Dolby Vision** (decoded
/// on-device) — plus DTS/TrueHD and AV1, which is exactly what the rules below send
/// to the on-device decode engine.
public enum EngineRouter {

    /// Picks the engine for a resolved stream.
    ///
    /// - Parameters:
    ///   - source: provider-reported source facts (container/codec/range). `nil`
    ///     is treated as ambiguous → native.
    ///   - capabilities: the device/display/audio policy (DTS passthrough, decodable
    ///     video codecs).
    ///   - isTranscoding: whether the resolved stream is a server transcode (HLS),
    ///     which AVPlayer always handles.
    ///   - hybridAvailable: whether an on-device decode engine (Plozzigen) is
    ///     actually wired in. When `false` the result is always native — the
    ///     non-regression default.
    public static func selectEngine(
        source: MediaSourceMetadata?,
        capabilities: MediaCapabilities,
        isTranscoding: Bool,
        hybridAvailable: Bool
    ) -> PlaybackEngineKind {
        // No on-device decode engine wired in → AVPlayer for everything (it already
        // has the server-transcode auto-fallback). Byte-for-byte today's behaviour.
        guard hybridAvailable else { return .native }

        // A server transcode is always a seekable HLS stream AVPlayer plays well.
        guard !isTranscoding else { return .native }

        // No source facts → ambiguous → native (safety net handles surprises).
        guard let source else { return .native }

        // Dolby Vision: always decode on the on-device engine. AVPlayer's native
        // DoVi path is unreliable across servers/containers on tvOS — e.g. a
        // Plex-served DoVi Profile 8.1 (DOVIWithHDR10) in an MP4 (HEVC Main 10,
        // hvc1/untagged) plays audio over a fully BLACK screen: AVPlayer produces no
        // video frames from that muxing. The on-device engine (FFmpeg demux → HLS-fMP4
        // remux → dvh1 tag → DoVi panel switch) renders every DoVi profile correctly,
        // exactly as the same title plays from a hybrid (MKV) container. Reliability
        // beats AVPlayer's theoretical full-dynamic-metadata advantage, so route all
        // DoVi on-device rather than gambling on the native path. (`hybridAvailable`
        // is guaranteed above; if it weren't, the guard there already forced native.)
        if isDolbyVision(source.video) { return .hybrid }

        // AVPlayer cannot demux hybrid-only containers (Matroska/WebM and
        // transport-stream variants); the hybrid engine can.
        if isHybridContainer(source.container) { return .hybrid }

        // AVPlayer/VideoToolbox only decode HEVC tagged `hvc1`; an HEVC stream
        // tagged `hev1` (in-band parameter sets) in an Apple/MP4-family container
        // plays audio with a **black screen** on AVPlayer. When it hasn't been
        // remuxed to `hvc1` (this branch only runs for non-transcoded sources),
        // decode it on-device instead — the hybrid engine handles `hev1` fine.
        // `hev1` in hybrid-only containers already falls under the container rule above.
        if isHevcHev1(source.video) { return .hybrid }

        // AV1 has no hardware decoder on current Apple TV silicon, so AVPlayer
        // can't render it (a software path doesn't exist on tvOS). Decode it on
        // the on-device engine instead — but stay native on any future device
        // that reports hardware AV1 support.
        if isAV1(source.video), !capabilities.supportsAV1 { return .hybrid }

        // AVPlayer/VideoToolbox can't decode 10-bit **H.264** (High 10 profile) —
        // it plays audio over a black screen, exactly like `hev1`. (10-bit HEVC,
        // i.e. Main 10, IS supported and is the basis of HDR, so this is H.264
        // only.) Decode it on-device instead.
        if isTenBitH264(source.video) { return .hybrid }

        // HEVC Range Extensions (4:2:2 / 4:4:4 chroma, or 12-bit) aren't part of
        // VideoToolbox's Main/Main 10 hardware decode, so they black-screen on
        // AVPlayer even under an `hvc1` tag. The on-device engine decodes them.
        if isHevcRangeExtensions(source.video) { return .hybrid }

        // Interlaced content is better handled on the on-device engine; AVPlayer
        // often deinterlaces poorly or trips into compatibility transcodes.
        if isInterlaced(source.video) { return .hybrid }

        if let audio = source.audio?.codec?.lowercased() {
            // AVPlayer can't decode TrueHD/MLP at all → hybrid.
            if isTrueHD(audio) { return .hybrid }
            // Opus/Vorbis aren't decodable by AVPlayer in an MP4-family container
            // (Matroska/WebM, where they usually live, already routed above) →
            // the file plays video with **no sound**. Decode on-device instead.
            if isAVPlayerIncompatibleAudio(audio) { return .hybrid }
            // DTS family: AVPlayer can only *passthrough* the bitstream to an
            // external decoder. With a passthrough-capable route, keep it native
            // (bitstream is best). Otherwise the hybrid engine decodes it on-device.
            if isDTSFamily(audio) {
                return capabilities.supportsDTSPassthrough ? .native : .hybrid
            }
        }

        // A video codec AVPlayer definitely can't decode → hybrid. Unknown codecs
        // fall through to native (the conservative default + transcode safety net).
        if let videoCodec = source.video?.codec?.lowercased(),
           Self.nativeIncompatibleVideoCodecs.contains(videoCodec) {
            return .hybrid
        }

        return .native
    }

    // MARK: - Classifiers (pure)

    /// Containers AVPlayer cannot reliably direct-play from a raw file URL but the
    /// hybrid engine can decode on-device.
    static func isHybridContainer(_ container: String?) -> Bool {
        guard let container = container?.lowercased() else { return false }
        return container == "mkv"
            || container == "webm"
            || container.contains("matroska")
            || container == "ts"
            || container == "m2ts"
            || container == "mts"
            || container == "m2t"
            || container == "mpegts"
            || container == "bdav" || container == "bdmv"
    }

    /// True when the video stream carries a **Dolby Vision** signal (any profile).
    /// Only DoVi forces the native engine; plain HDR10/HLG follow the container
    /// rules (Apple container → native, hybrid-only container → on-device hybrid).
    static func isDolbyVision(_ video: MediaSourceMetadata.VideoStream?) -> Bool {
        guard let video else { return false }

        // Jellyfin VideoRangeType DoVi tokens: DOVI, DOVIWithHDR10/HLG/SDR.
        if let rangeType = video.videoRangeType?.uppercased(), rangeType.hasPrefix("DOVI") {
            return true
        }

        // Coarse VideoRange token (Jellyfin: "DOVI") / Plex maps DOVIPresent here.
        if let range = video.videoRange?.uppercased(), range == "DOVI" {
            return true
        }

        return false
    }

    /// True when the video stream carries any HDR or Dolby Vision signal.
    static func isDolbyVisionOrHDR(_ video: MediaSourceMetadata.VideoStream?) -> Bool {
        guard let video else { return false }

        // Specific Jellyfin VideoRangeType tokens (DoVi profiles, HDR10(+), HLG).
        if let rangeType = video.videoRangeType?.uppercased(),
           rangeType != "SDR",
           rangeType.hasPrefix("DOVI") || rangeType.hasPrefix("HDR") || rangeType == "HLG" {
            return true
        }

        // Coarse VideoRange token (Jellyfin: "HDR"/"DOVI"/"SDR").
        if let range = video.videoRange?.uppercased(), range == "HDR" || range == "DOVI" {
            return true
        }

        // Color transfer characteristics (PQ / HLG / HDR10+) — what Plex reports.
        switch video.colorTransfer?.lowercased() {
        case "smpte2084", "pq", "arib-std-b67", "hlg",
             "smpte2094-40":   // HDR10+ (ST 2094-40 dynamic metadata; base layer is HDR10)
            return true
        default:
            return false
        }
    }

    /// True for an HEVC stream tagged `hev1` (vs `hvc1`). AVPlayer can't render
    /// `hev1`, so it's routed to the on-device hybrid engine when it reaches the
    /// router without having been remuxed to `hvc1`.
    static func isHevcHev1(_ video: MediaSourceMetadata.VideoStream?) -> Bool {
        guard let video else { return false }
        let codec = (video.codec ?? "").lowercased()
        guard codec == "hevc" || codec == "h265" else { return false }
        return (video.codecTag ?? "").lowercased() == "hev1"
    }

    /// True for an AV1 video stream. No current Apple TV has a hardware AV1
    /// decoder, and tvOS has no software fallback, so AVPlayer can't render it.
    static func isAV1(_ video: MediaSourceMetadata.VideoStream?) -> Bool {
        let codec = (video?.codec ?? "").lowercased()
        return codec == "av1" || codec == "av01"
    }

    /// True for **10-bit (or deeper) H.264**. AVPlayer/VideoToolbox decode 8-bit
    /// H.264 only; High 10 plays audio over a black screen. (HEVC Main 10 is fine
    /// and intentionally excluded — it's the basis of HDR.)
    static func isTenBitH264(_ video: MediaSourceMetadata.VideoStream?) -> Bool {
        guard let video else { return false }
        let codec = (video.codec ?? "").lowercased()
        guard codec == "h264" || codec == "avc" || codec == "avc1" else { return false }
        if let depth = video.bitDepth { return depth >= 10 }
        // Fall back to the profile string when bit depth wasn't reported.
        return (video.profile ?? "").lowercased().contains("high 10")
    }

    /// True for HEVC **Range Extensions**: 4:2:2 / 4:4:4 chroma or 12-bit depth.
    /// VideoToolbox hardware decode covers Main / Main 10 (4:2:0) only, so these
    /// black-screen on AVPlayer even when tagged `hvc1`. Main 10 4:2:0 (HDR) is
    /// intentionally excluded — only chroma/bit-depth beyond Main 10 qualifies.
    static func isHevcRangeExtensions(_ video: MediaSourceMetadata.VideoStream?) -> Bool {
        guard let video else { return false }
        let codec = (video.codec ?? "").lowercased()
        guard codec == "hevc" || codec == "h265" else { return false }
        let profile = (video.profile ?? "").lowercased()
        if profile.contains("4:2:2") || profile.contains("4:4:4")
            || profile.contains("rext") || profile.contains("range extensions") {
            return true
        }
        if let depth = video.bitDepth { return depth >= 12 }
        return false
    }

    /// True when the stream is interlaced.
    static func isInterlaced(_ video: MediaSourceMetadata.VideoStream?) -> Bool {
        guard let video else { return false }
        if let isInterlaced = video.isInterlaced { return isInterlaced }
        return (video.profile ?? "").lowercased().contains("interlac")
    }

    /// Audio codecs AVPlayer can't decode in an MP4-family container (their usual
    /// Matroska/WebM home is already routed to the hybrid engine by container).
    static func isAVPlayerIncompatibleAudio(_ codec: String) -> Bool {
        let codec = codec.lowercased()
        return codec == "opus" || codec == "vorbis"
            || codec.hasPrefix("wma")   // wmav1/wmav2/wmapro/wmalossless
    }

    /// True for DTS / DTS-HD (incl. ffmpeg's `dca` alias and `dts-hd ma`).
    static func isDTSFamily(_ codec: String) -> Bool {
        let codec = codec.lowercased()
        return codec.contains("dts") || codec == "dca" || codec.hasPrefix("dca")
    }

    /// True for Dolby TrueHD / MLP, which AVPlayer cannot decode.
    static func isTrueHD(_ codec: String) -> Bool {
        let codec = codec.lowercased()
        return codec.contains("truehd") || codec == "mlp"
    }

    /// Video codecs AVPlayer can't decode on tvOS but the hybrid engine can.
    /// Deliberately a small, explicit set: anything not listed (including unknown
    /// codecs) stays native, matching the "ambiguous → native" policy. (`mpeg4`
    /// Part 2 and `mjpeg` are deliberately absent — AVFoundation decodes them and
    /// both providers advertise them as direct-play.)
    static let nativeIncompatibleVideoCodecs: Set<String> = [
        "vc1", "vc-1", "wmv1", "wmv2", "wmv3",
        "mpeg1video", "mpeg2video", "mpeg2",
        "msmpeg4v1", "msmpeg4v2", "msmpeg4v3",
        "vp8", "vp9", "theora",
        "rv10", "rv20", "rv30", "rv40", "realvideo"
    ]
}
