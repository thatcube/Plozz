#if canImport(Libmpv) && canImport(UIKit)
import Foundation
import CoreMedia
import CoreVideo
import QuartzCore
import Metal
import CoreModels

/// The colorimetry mode the engine drives the render surface (and, on tvOS, the
/// display) into for a given stream.
///
/// - `sdr`: plain 8-bit BT.709 — no HDR surface, no display-mode switch.
/// - `pq`: SMPTE-2084 (PQ) BT.2020 — HDR10 / HDR10+.
/// - `hlg`: ARIB STD-B67 (HLG) BT.2020.
/// - `dolbyVision`: Dolby Vision. libplacebo reshapes the P5/P8 RPU base layer
///   to PQ BT.2020 so the *render surface* is identical to `.pq`; the
///   distinction lives in the tvOS display-mode switch, which must request the
///   `'dvh1'` codec so the panel negotiates a true Dolby Vision HDMI signal
///   (and lights the on-screen "Dolby Vision" banner) instead of plain HDR10.
enum MPVHDRMode: String, Sendable {
    case sdr
    case pq
    case hlg
    case dolbyVision

    var isHDR: Bool { self != .sdr }

    /// PQ-class modes share the same render surface (PQ BT.2020 16-bit float);
    /// only the display-criteria codec tag differs between HDR10 and DoVi.
    var isPQClass: Bool { self == .pq || self == .dolbyVision }
}

/// Pure helpers mapping provider HDR metadata + the chosen mode onto concrete
/// Metal / Core Media / mpv configuration. Kept free of side effects so they're
/// trivially testable and usable from both the view and the engine.
enum MPVHDR {
    /// Classifies a stream's dynamic range from the provider's source metadata.
    ///
    /// Any Dolby Vision profile (base layer P5 or P8.x — Plex sets
    /// `videoRangeType="DOVI"`; Jellyfin uses `DOVI`/`DOVIWithHDR10`/
    /// `DOVIWithSDR`/`DOVIWithHLG`) maps to `.dolbyVision` so the display-mode
    /// switch can ask tvOS for a true DoVi HDMI signal via the `'dvh1'` codec
    /// tag. The render surface stays on the PQ path because libplacebo
    /// reshapes the RPU to PQ HDR10 regardless of base layer.
    static func mode(from video: MediaSourceMetadata.VideoStream?) -> MPVHDRMode {
        guard let video else { return .sdr }
        let rangeType = (video.videoRangeType ?? "").uppercased()
        let transfer = (video.colorTransfer ?? "").lowercased()
        let range = (video.videoRange ?? "").uppercased()

        // Dolby Vision (any base layer) — check before HLG so DOVIWithHLG isn't
        // misread as HLG, and before HDR10 so DOVIWithHDR10 lights DoVi.
        if rangeType.contains("DOVI") || rangeType.contains("DV") {
            return .dolbyVision
        }
        // HLG (its tokens don't overlap the PQ set).
        if rangeType.contains("HLG") || transfer.contains("arib-std-b67") || transfer.contains("hlg") {
            return .hlg
        }
        // PQ-based: HDR10 / HDR10+.
        if rangeType.contains("HDR10")
            || transfer.contains("smpte2084") || transfer.contains("pq") {
            return .pq
        }
        // Generic "HDR" with no finer token — assume PQ (the common case).
        if range == "HDR" { return .pq }
        return .sdr
    }

    /// The Metal drawable format for the mode. HDR needs a wide-precision format
    /// (half-float) so libplacebo can emit 10-bit PQ/HLG without banding; SDR
    /// stays on the cheap 8-bit BGRA path. Dolby Vision shares the PQ surface
    /// (RPU is reshaped to PQ HDR10 before reaching the surface).
    static func metalPixelFormat(for mode: MPVHDRMode) -> MTLPixelFormat {
        mode.isHDR ? .rgba16Float : .bgra8Unorm
    }

    /// The CoreGraphics colorspace to tag the `CAMetalLayer` with. On tvOS there
    /// is no per-layer EDR opt-in (`wantsExtendedDynamicRangeContent` is
    /// unavailable); HDR is realized by tagging the surface BT.2020 PQ/HLG and
    /// switching the display into an HDR mode via `AVDisplayManager`. Dolby
    /// Vision uses the PQ colorspace — the DoVi-vs-HDR10 distinction is carried
    /// by the display-criteria codec tag, not the surface colorspace.
    static func colorspace(for mode: MPVHDRMode) -> CGColorSpace? {
        switch mode {
        case .sdr: return CGColorSpace(name: CGColorSpace.sRGB)
        case .pq, .dolbyVision: return CGColorSpace(name: CGColorSpace.itur_2100_PQ)
        case .hlg: return CGColorSpace(name: CGColorSpace.itur_2100_HLG)
        }
    }

    /// mpv's `target-trc` value (transfer characteristics) for the mode, or `nil`
    /// for SDR (let mpv keep its default / the surface hint decide). Dolby
    /// Vision targets PQ since libplacebo reshapes the RPU to PQ HDR10.
    static func mpvTargetTRC(for mode: MPVHDRMode) -> String? {
        switch mode {
        case .sdr: return nil
        case .pq, .dolbyVision: return "pq"
        case .hlg: return "hlg"
        }
    }

    /// 'dvh1' Dolby Vision HEVC codec FourCC. Selecting this codec in the
    /// `CMVideoFormatDescription` we build for `AVDisplayCriteria` is what makes
    /// tvOS negotiate a *true Dolby Vision* HDMI signal with the panel (and
    /// light the on-screen "Dolby Vision" banner) instead of plain HDR10.
    /// Matches `Sources/FeaturePlayback/DolbyVisionDisplayCriteria.swift`.
    static let dolbyVisionCodecType: CMVideoCodecType = 0x64766831 // 'dvh1'

    /// A `CMVideoFormatDescription` carrying the stream's HDR colorimetry, used to
    /// build the `AVDisplayCriteria` that requests an HDR display-mode switch.
    /// Returns `nil` for SDR (no switch needed).
    ///
    /// For `.dolbyVision` the codec FourCC is `'dvh1'` so tvOS drives the panel
    /// into Dolby Vision mode; the colour extensions still advertise BT.2020 PQ
    /// (libplacebo reshapes the RPU to PQ HDR10 on the render surface).
    static func formatDescription(for mode: MPVHDRMode, video: MediaSourceMetadata.VideoStream?) -> CMVideoFormatDescription? {
        guard mode.isHDR else { return nil }

        let transfer: CFString = mode == .hlg
            ? kCVImageBufferTransferFunction_ITU_R_2100_HLG
            : kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        let extensions: [CFString: Any] = [
            kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_2020,
            kCVImageBufferTransferFunctionKey: transfer,
            kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_2020,
        ]

        let width = Int32(video?.width ?? 3840)
        let height = Int32(video?.height ?? 2160)

        var desc: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codecType(for: mode, codec: video?.codec),
            width: width,
            height: height,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &desc)
        return status == noErr ? desc : nil
    }

    /// A BT.709 **SDR** `CMVideoFormatDescription`, used to build the
    /// `AVDisplayCriteria` for a *refresh-rate-only* display match on SDR content.
    ///
    /// AVPlayer frame-rate-matches the panel for SDR automatically; the mpv path
    /// must drive `AVDisplayManager` itself, and the criteria needs a format
    /// description to carry the (SDR) dynamic range alongside the requested
    /// refresh rate. The colour extensions advertise plain BT.709 so tvOS picks
    /// an **SDR** mode at the matched rate — it never pushes the panel into HDR
    /// (that stays gated to the `mode.isHDR` path above). The codec FourCC tracks
    /// the source so tvOS negotiates a sensible mode; it carries no HDR/DoVi
    /// signalling. Returns `nil` if the description can't be created.
    static func sdrFormatDescription(video: MediaSourceMetadata.VideoStream?) -> CMVideoFormatDescription? {
        let extensions: [CFString: Any] = [
            kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2,
            kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ]

        let width = Int32(video?.width ?? 1920)
        let height = Int32(video?.height ?? 1080)

        var desc: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codecType(for: .sdr, codec: video?.codec),
            width: width,
            height: height,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &desc)
        return status == noErr ? desc : nil
    }

    /// HDR10 (`'hvc1'` + PQ) safe-fallback format description, used by the
    /// engine when the `'dvh1'` Dolby Vision criteria can't be constructed or
    /// accepted by tvOS — better to negotiate HDR10 than to drop to SDR.
    static func hdr10FallbackFormatDescription(video: MediaSourceMetadata.VideoStream?) -> CMVideoFormatDescription? {
        formatDescription(for: .pq, video: video)
    }

    private static func codecType(for mode: MPVHDRMode, codec: String?) -> CMVideoCodecType {
        if mode == .dolbyVision { return dolbyVisionCodecType }
        switch (codec ?? "").lowercased() {
        case "av1": return kCMVideoCodecType_AV1
        case "h264", "avc": return kCMVideoCodecType_H264
        default: return kCMVideoCodecType_HEVC
        }
    }
}

/// A snapshot of what the HDR path actually realized, for diagnostics. All fields
/// are plain values so it can be read off the engine (and later surfaced in the
/// diagnostics overlay) without touching mpv or UIKit internals.
public struct MPVHDRStatus: Sendable, Equatable {
    /// The dynamic range the engine targeted for the current stream.
    public var requestedMode: String
    /// The Metal pixel format the layer ended up with (e.g. `rgba16Float`).
    public var layerPixelFormat: String
    /// The CoreGraphics colorspace name tagged on the layer, if any.
    public var layerColorspace: String?
    /// Whether the engine asked the display to switch into an HDR mode.
    public var displaySwitchRequested: Bool
    /// Whether the applied display-mode switch carries the `'dvh1'` Dolby
    /// Vision codec tag (i.e. we asked tvOS for a true DoVi HDMI signal). False
    /// for HDR10 / HLG / SDR, and also false on the HDR10 fallback path.
    public var dolbyVisionRequested: Bool
    /// Whether the user's tvOS settings currently allow display-mode matching
    /// (`false` means our `preferredDisplayCriteria` will be ignored by the OS).
    public var displayMatchingEnabled: Bool

    public init(
        requestedMode: String = "sdr",
        layerPixelFormat: String = "",
        layerColorspace: String? = nil,
        displaySwitchRequested: Bool = false,
        dolbyVisionRequested: Bool = false,
        displayMatchingEnabled: Bool = false
    ) {
        self.requestedMode = requestedMode
        self.layerPixelFormat = layerPixelFormat
        self.layerColorspace = layerColorspace
        self.displaySwitchRequested = displaySwitchRequested
        self.dolbyVisionRequested = dolbyVisionRequested
        self.displayMatchingEnabled = displayMatchingEnabled
    }
}

extension MTLPixelFormat {
    /// A short human-readable token for the formats this engine uses.
    var debugName: String {
        switch self {
        case .rgba16Float: return "rgba16Float"
        case .bgra8Unorm: return "bgra8Unorm"
        case .bgra8Unorm_srgb: return "bgra8Unorm_srgb"
        case .bgr10a2Unorm: return "bgr10a2Unorm"
        case .rgb10a2Unorm: return "rgb10a2Unorm"
        default: return "raw(\(rawValue))"
        }
    }
}
#endif
