import Foundation

// MARK: - PlaybackEngineKind

/// Which playback engine should handle a resolved stream.
///
/// `CoreModels` only names the *decision*; mapping a kind onto a concrete engine
/// (the `AVPlayer`-backed native engine vs. the VLCKit hybrid engine) happens up
/// in `FeaturePlayback`, which alone knows the engine types. Keeping the decision
/// here means it stays pure, dependency-free, and unit-testable on Linux/CI.
public enum PlaybackEngineKind: String, Sendable, Equatable, CaseIterable {
    /// `NativeVideoEngine` (AVPlayer). The default, power-efficient path; the only
    /// engine that renders Dolby Vision correctly on tvOS.
    case native
    /// `VLCKitVideoEngine`. Decodes AVPlayer-incompatible sources on-device (MKV,
    /// DTS / DTS-HD / TrueHD, odd codecs) without a server transcode.
    case hybrid
}

// MARK: - EngineRouter

/// The pure brain that picks which engine plays a resolved source.
///
/// ## Policy (CONSERVATIVE)
/// Preserve the rock-solid, power-efficient `AVPlayer` path for everything it
/// handles well; use the VLCKit hybrid engine **only** for what AVPlayer can't
/// direct-play without a server transcode:
///
///   * **Dolby Vision** → ``PlaybackEngineKind/native``. AVPlayer is the *only*
///     engine that renders Dolby Vision correctly on tvOS, so DoVi always goes
///     native. The capability layer keeps DoVi out of non-Apple (e.g. MKV)
///     direct-play, so a DoVi file only ever reaches the router as either an
///     Apple-container direct-play (native) or a transcoded HLS stream (native).
///   * **Matroska, plain HDR10/HLG in an MKV, AV1, DTS/DTS-HD/TrueHD audio, or an
///     AVPlayer-incompatible video codec** → ``PlaybackEngineKind/hybrid`` (decode
///     on-device, no transcode). Plain HDR10/HLG in an *Apple* container stays
///     native — AVPlayer renders it on the efficient hardware path.
///   * **Ambiguous/unknown, already transcoding, or no hybrid engine available**
///     → ``PlaybackEngineKind/native`` (it carries the server-transcode safety net).
///
/// ## Lockstep with the capability layer
/// The router and the provider capability profiles must advertise the *same* set
/// of formats as direct-play: never advertise something the router can't route to
/// a working engine. The capability expansion (gated by the same hybrid flag that
/// sets `hybridAvailable` here) advertises raw MKV for SDR **and display-supported
/// HDR10/HLG** (never DoVi, which transcodes → native), plus DTS/TrueHD and AV1,
/// which is exactly what the rules below send to the hybrid engine.
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
    ///   - hybridAvailable: whether a hybrid (VLCKit) engine is actually wired in.
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
        guard !isTranscoding else { return .native }

        // No source facts → ambiguous → native (safety net handles surprises).
        guard let source else { return .native }

        // Dolby Vision must ALWAYS render on AVPlayer — it is the only engine that
        // renders DoVi correctly on tvOS. (Plain HDR10/HLG are NOT forced native:
        // AVPlayer plays them in an Apple container, and the on-device engine plays
        // them in an MKV — see the container rule below. The capability layer keeps
        // *DoVi* out of MKV direct-play, so DoVi only ever reaches here as an
        // Apple-container direct-play or a transcoded HLS stream.)
        if isDolbyVision(source.video) { return .native }

        // AVPlayer cannot demux Matroska/WebM; the hybrid engine can.
        if isMatroska(source.container) { return .hybrid }

        if let audio = source.audio?.codec?.lowercased() {
            // AVPlayer can't decode TrueHD/MLP at all → hybrid.
            if isTrueHD(audio) { return .hybrid }
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

    /// Matroska family containers AVPlayer cannot demux from a file URL.
    static func isMatroska(_ container: String?) -> Bool {
        guard let container = container?.lowercased() else { return false }
        return container == "mkv"
            || container == "webm"
            || container.contains("matroska")
    }

    /// True when the video stream carries a **Dolby Vision** signal (any profile).
    /// Only DoVi forces the native engine; plain HDR10/HLG follow the container
    /// rules (Apple container → native, MKV → on-device hybrid).
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

        // Color transfer characteristics (PQ / HLG) — what Plex reports.
        switch video.colorTransfer?.lowercased() {
        case "smpte2084", "pq", "arib-std-b67", "hlg":
            return true
        default:
            return false
        }
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
    /// codecs) stays native, matching the "ambiguous → native" policy.
    static let nativeIncompatibleVideoCodecs: Set<String> = [
        "vc1", "vc-1", "wmv1", "wmv2", "wmv3",
        "mpeg1video", "mpeg2video", "mpeg2",
        "msmpeg4v1", "msmpeg4v2", "msmpeg4v3"
    ]
}
