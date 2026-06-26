import Foundation

// MARK: - PlaybackEngineKind

/// Which playback engine should handle a resolved stream.
///
/// `CoreModels` only names the *decision*; mapping a kind onto a concrete engine
/// (the `AVPlayer`-backed native engine vs. the mpv hybrid engine) happens up
/// in `FeaturePlayback`, which alone knows the engine types. Keeping the decision
/// here means it stays pure, dependency-free, and unit-testable on Linux/CI.
public enum PlaybackEngineKind: String, Sendable, Equatable, CaseIterable {
    /// `NativeVideoEngine` (AVPlayer). The default, power-efficient path; the only
    /// engine that renders Dolby Vision correctly on tvOS.
    case native
    /// `MPVVideoEngine` (libmpv). Decodes AVPlayer-incompatible sources on-device
    /// (MKV, DTS / DTS-HD / TrueHD, odd codecs) without a server transcode.
    case hybrid
}

// MARK: - EngineRouter

/// The pure brain that picks which engine plays a resolved source.
///
/// ## Policy (PREFER AVPlayer; mpv only when unavoidable)
/// Keep the rock-solid, power-efficient `AVPlayer` path for everything it can
/// handle — including **plain SDR / HDR10 / HLG in a Matroska or transport-stream
/// container**. AVPlayer can't demux those containers from a raw file, but the
/// *server* remuxes them to HLS (and AVPlayer then decodes on the hardware path
/// with automatic frame-rate matching). The mpv hybrid engine is reserved for the
/// formats that genuinely need on-device decode, captured by
/// ``requiresHybridDecode(source:capabilities:)``:
///
///   * **Dolby Vision** → ``PlaybackEngineKind/native`` in an Apple container
///     (AVPlayer renders it with full dynamic metadata). A server transcode of
///     DoVi is unreliable, so **DoVi in a container AVPlayer can't demux**
///     (Matroska) goes to the on-device engine (HEVC base layer), like Infuse.
///   * **hev1-tagged HEVC, 10-bit H.264, HEVC range-extensions, interlaced video,
///     AV1 (no HW), an AVPlayer-incompatible video codec, or DTS/DTS-HD/TrueHD/
///     Opus/Vorbis/WMA audio** → ``PlaybackEngineKind/hybrid`` (decode on-device).
///   * **Everything else** — plain SDR/HDR10/HLG in any container, ambiguous/
///     unknown sources, an already-transcoding stream, or no hybrid engine wired
///     in → ``PlaybackEngineKind/native`` (the server-transcode safety net carries
///     anything AVPlayer can't direct-play).
///
/// ## Direct play is king; the server is a runtime last resort
/// This router only ever picks between the two **on-device** engines — it never
/// routes to the server. Reducing what plain content advertises as direct-play
/// (so the server *remuxes* a Matroska/TS file to an HLS stream AVPlayer decodes
/// on the efficient hardware path) is a stream-copy **remux**, not a re-encode:
/// lossless, light server CPU, and — confirmed on-device — dramatically smoother
/// than pushing the same plain file through mpv's gpu→Vulkan→Metal present chain.
/// A *transcode* (re-encode) is still only ever reached at **runtime**, as a
/// fallback, when an on-device engine measurably fails or can't keep up — see the
/// ``PlaybackHealthPolicy`` render-health watchdog in `FeaturePlayback`. Nothing
/// here is pre-emptively pushed to the server because of the device or format.
///
/// ## Lockstep with the capability layer
/// The router and the provider capability profiles must advertise the *same* set
/// of formats as direct-play: never advertise something the router can't route to
/// a working engine, and never route to the hybrid engine something the providers
/// stopped advertising (it would arrive as a server transcode, caught by
/// `isTranscoding` → native). The providers advertise raw hybrid containers as
/// direct-play **only** for the formats ``requiresHybridDecode(source:capabilities:)``
/// sends to the hybrid engine; plain SDR/HDR10/HLG with mainstream audio is no
/// longer advertised, so the server remuxes it to a native HLS stream.
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
    ///   - hybridAvailable: whether a hybrid (mpv) engine is actually wired in.
    ///     When `false` the result is always native — the non-regression default.
    public static func selectEngine(
        source: MediaSourceMetadata?,
        capabilities: MediaCapabilities,
        isTranscoding: Bool,
        hybridAvailable: Bool
    ) -> PlaybackEngineKind {
        // No hybrid engine wired in → AVPlayer for everything (it already has the
        // server-transcode auto-fallback). Byte-for-byte today's behaviour.
        guard hybridAvailable else { return .native }

        // A server transcode is always a seekable HLS stream AVPlayer plays well.
        // This is also the path plain SDR/HDR10/HLG hybrid-container files take:
        // the provider stops advertising them as direct-play, the server remuxes
        // them to HLS, and they arrive here as a transcode → native.
        guard !isTranscoding else { return .native }

        // No source facts → ambiguous → native (safety net handles surprises).
        guard let source else { return .native }

        // The single, data-driven decision: only the formats that genuinely need
        // on-device decode go to the hybrid engine. Everything else (incl. plain
        // SDR/HDR10/HLG that was direct-played from an Apple container) stays on
        // the power-efficient AVPlayer path.
        return requiresHybridDecode(source: source, capabilities: capabilities) ? .hybrid : .native
    }

    /// Pure predicate: does this **direct-played** source genuinely need the
    /// on-device (mpv) engine, because AVPlayer can neither decode it nor reach it
    /// through a clean server remux?
    ///
    /// Returns `false` for plain SDR/HDR10/HLG H.264/HEVC (with mainstream audio) —
    /// even in a Matroska or transport-stream container — so it stays
    /// ``PlaybackEngineKind/native``. Such a file is never *direct-played* from a
    /// hybrid container (the providers no longer advertise it); the server remuxes
    /// it to HLS and it returns here as a transcode. This predicate must stay in
    /// lockstep with the provider capability profiles: every `true` case is one the
    /// providers advertise as direct-play, and nothing they advertise returns a
    /// kind AVPlayer can't actually play.
    public static func requiresHybridDecode(
        source: MediaSourceMetadata,
        capabilities: MediaCapabilities
    ) -> Bool {
        let video = source.video
        let inHybridContainer = isHybridContainer(source.container)

        // Dolby Vision is best on AVPlayer (the only engine that renders DoVi with
        // full dynamic metadata on tvOS) — but ONLY when it can actually reach
        // AVPlayer. AVPlayer cannot demux Matroska, and a server transcode of DoVi
        // is unreliable (and outright fails on many servers), so DoVi *in a hybrid
        // container* is decoded on-device instead: the engine decodes the HEVC base
        // layer (HDR10/HLG/SDR for Profile 8, tone-mapped for Profile 5), exactly
        // as Infuse does. DoVi in an Apple container is not a hybrid case.
        if isDolbyVision(video), inHybridContainer { return true }

        // AVPlayer/VideoToolbox only decode HEVC tagged `hvc1`; an HEVC stream
        // tagged `hev1` (in-band parameter sets) plays audio with a **black
        // screen** on AVPlayer. When it reaches the router as a direct play (not
        // remuxed to `hvc1`), decode it on-device — the hybrid engine handles it.
        if isHevcHev1(video) { return true }

        // AV1 has no hardware decoder on current Apple TV silicon, so AVPlayer
        // can't render it (no software path on tvOS). Stay native on any future
        // device that reports hardware AV1 support.
        if isAV1(video), !capabilities.supportsAV1 { return true }

        // AVPlayer/VideoToolbox can't decode 10-bit **H.264** (High 10); it plays
        // audio over a black screen. (10-bit HEVC / Main 10 IS supported.)
        if isTenBitH264(video) { return true }

        // HEVC Range Extensions (4:2:2 / 4:4:4 chroma, or 12-bit) aren't part of
        // VideoToolbox's Main/Main 10 hardware decode → black screen on AVPlayer.
        if isHevcRangeExtensions(video) { return true }

        // Interlaced content is better handled on the on-device engine; AVPlayer
        // often deinterlaces poorly or trips into compatibility transcodes.
        if isInterlaced(video) { return true }

        if let audio = source.audio?.codec?.lowercased() {
            // AVPlayer can't decode TrueHD/MLP at all → hybrid.
            if isTrueHD(audio) { return true }
            // Opus/Vorbis/WMA aren't decodable by AVPlayer in an MP4-family
            // container → the file plays video with **no sound**. Decode on-device.
            if isAVPlayerIncompatibleAudio(audio) { return true }
            // DTS family: in a container AVPlayer can't demux, DTS must be decoded
            // on-device even with a passthrough-capable route (AVPlayer can't reach
            // the bitstream). In an Apple container, native passthrough is best when
            // available; otherwise decode on-device.
            if isDTSFamily(audio) {
                if inHybridContainer { return true }
                return !capabilities.supportsDTSPassthrough
            }
        }

        // A video codec AVPlayer definitely can't decode → hybrid. Unknown codecs
        // fall through to native (the conservative default + transcode safety net).
        if let videoCodec = video?.codec?.lowercased(),
           Self.nativeIncompatibleVideoCodecs.contains(videoCodec) {
            return true
        }

        return false
    }

    // MARK: - Classifiers (pure)

    /// Containers AVPlayer cannot reliably direct-play from a raw file URL. Plain
    /// content in these is remuxed to HLS by the server and played natively; only
    /// the formats ``requiresHybridDecode(source:capabilities:)`` flags (DoVi,
    /// hybrid-only codecs/audio) are direct-played to the on-device engine.
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
    /// DoVi in an Apple container plays natively; DoVi in a hybrid container is
    /// decoded on-device (a server DoVi transcode is unreliable). Plain HDR10/HLG
    /// is not special-cased here — it stays native unless something else about the
    /// stream needs on-device decode.
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
